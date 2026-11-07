-- CareLoop follow-up functions, called by workflow 3 and later by the dashboard and patient app.
-- Run in the Supabase SQL editor. Safe to re-run; keeps your data and your settings.
--
-- run_followups      every few minutes: sends approved messages, reminders, escalations, queues alerts
-- approve_message    doctor approves a draft (dashboard)
-- book_appointment   patient or coordinator books (app / dashboard)
-- record_attendance  clinic confirms the patient came, or didn't (dashboard)
-- record_outcome     doctor records what was done, which closes the loop (dashboard)
-- record_alert       workflow 3 logs that an alert email went out

create table if not exists settings (
  key   text primary key,
  value text not null
);
alter table settings enable row level security;

insert into settings (key, value) values
  ('demo_mode', 'false'),            -- true: one day passes in one minute, for demos
  ('reminder_1_day', '3'),
  ('reminder_2_day', '7'),
  ('escalate_day', '10'),
  ('missed_after_days', '1'),        -- appointment counts as missed this long after its time
  ('coordinator_email', '')
on conflict (key) do nothing;

create or replace function setting(p_key text) returns text
language sql stable set search_path = public as $$
  select value from settings where key = p_key
$$;

-- Length of one follow-up "day": a real day, or one minute in demo mode
create or replace function followup_day() returns interval
language sql stable set search_path = public as $$
  select case when setting('demo_mode') = 'true' then interval '1 minute' else interval '1 day' end
$$;

create or replace function fmt_date(t timestamptz) returns text
language sql immutable as $$
  select to_char(t at time zone 'Asia/Dubai', 'FMDD FMMonth YYYY')
$$;

create or replace function escalate_case(p_case_id bigint, p_reason text) returns void
language plpgsql set search_path = public as $$
begin
  update cases set status = 'escalated' where id = p_case_id and status not in ('escalated', 'closed', 'lost');
  if found then
    insert into audit_log (actor, action, case_id, detail)
    values ('workflow:followup', 'case.escalated', p_case_id, jsonb_build_object('reason', p_reason));
  end if;
end $$;


create or replace function run_followups()
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  d        interval := followup_day();
  r1       int := setting('reminder_1_day')::int;
  r2       int := setting('reminder_2_day')::int;
  esc      int := setting('escalate_day')::int;
  missed   int := setting('missed_after_days')::int;
  m        record;
  c        record;
  v_sent   int := 0;
  v_rem    int := 0;
  v_esc    int := 0;
  v_closed int := 0;
  v_alerts jsonb := '[]'::jsonb;
  v_to     text;
begin
  -- 1. Coordinator notes (patient declined app messages): straight to the coordinator
  for m in select * from messages where kind = 'coordinator-note' and status = 'draft' loop
    update messages set status = 'sent', sent_at = now() where id = m.id;
    perform escalate_case(m.case_id, 'Patient declined app messages: coordinator to contact');
  end loop;

  -- 2. Send messages the doctor has approved
  for m in select * from messages
            where status = 'approved' and sent_at is null and (scheduled_for is null or scheduled_for <= now()) loop
    update messages set status = 'sent', sent_at = now() where id = m.id;
    insert into audit_log (actor, action, case_id, detail)
    values ('workflow:followup', 'message.sent', m.case_id, jsonb_build_object('message_id', m.id, 'channel', m.channel));
    v_sent := v_sent + 1;
    if m.kind = 'result' then
      update cases set status = 'notified' where id = m.case_id and status = 'referred';
    end if;
  end loop;

  -- 3. Advice-only P4 cases close once the advice has gone out
  for c in
    select cs.id from cases cs
     where cs.status = 'notified' and cs.priority = 'P4'
       and not exists (select 1 from referrals r where r.case_id = cs.id)
       and not exists (select 1 from case_findings f where f.case_id = cs.id and f.rule_code in ('CERVIX_UNSAT', 'MAMMO_SHORT_INTERVAL'))
  loop
    update cases set status = 'closed', outcome = 'Advice sent; recall at next screening', closed_at = now() where id = c.id;
    insert into audit_log (actor, action, case_id, detail)
    values ('workflow:followup', 'case.closed', c.id, jsonb_build_object('reason', 'advice-only case'));
    v_closed := v_closed + 1;
  end loop;

  -- 4. Reminders and escalation for patients who were told but haven't booked
  for c in
    select cs.*,
           (select min(sent_at) from messages where case_id = cs.id and kind = 'result' and status = 'sent') as told_at,
           (select count(*) from messages where case_id = cs.id and kind = 'reminder') as reminders,
           (select coalesce(pr.name, s.name) from referrals r
              left join practitioners pr on pr.id = r.practitioner_id
              left join services s on s.id = r.service_id
             where r.case_id = cs.id order by r.id limit 1) as ref_to,
           (select cl.name from patients p join clinics cl on cl.id = p.clinic_id where p.id = cs.patient_id) as clinic
      from cases cs
     where cs.status = 'notified' and cs.priority <> 'P1'
  loop
    continue when c.told_at is null;
    v_to := coalesce(c.ref_to, c.clinic);
    if now() >= c.told_at + esc * d then
      perform escalate_case(c.id, format('No booking %s days after the patient was told', esc));
      v_esc := v_esc + 1;
    elsif now() >= c.told_at + r2 * d and c.reminders < 2 then
      insert into messages (case_id, kind, channel, body, drafted_by, status, sent_at)
      values (c.id, 'reminder', 'app',
              format('Second reminder: we have not seen a booking yet for your follow-up with %s. Please book by %s, or tap "I need help" in the app and someone will call you.',
                     v_to, fmt_date(c.due_at)),
              'template', 'sent', now());
      insert into audit_log (actor, action, case_id, detail) values ('workflow:followup', 'reminder.sent', c.id, '{"number": 2}');
      v_rem := v_rem + 1;
    elsif now() >= c.told_at + r1 * d and c.reminders < 1 then
      insert into messages (case_id, kind, channel, body, drafted_by, status, sent_at)
      values (c.id, 'reminder', 'app',
              format('Reminder: your screening results need a follow-up. Please book your appointment with %s by %s. You can book in the app.',
                     v_to, fmt_date(c.due_at)),
              'template', 'sent', now());
      insert into audit_log (actor, action, case_id, detail) values ('workflow:followup', 'reminder.sent', c.id, '{"number": 1}');
      v_rem := v_rem + 1;
    end if;
  end loop;

  -- 5. Appointment reminder, one day before
  for c in
    select r.*, coalesce(pr.name, s.name) as ref_to from referrals r
      left join practitioners pr on pr.id = r.practitioner_id
      left join services s on s.id = r.service_id
      join cases cs on cs.id = r.case_id
     where r.status = 'booked' and r.appointment_at > now() and r.appointment_at <= now() + d
       and cs.status in ('booked', 'escalated')
       and not exists (select 1 from messages mm where mm.case_id = r.case_id and mm.kind = 'appointment')
  loop
    insert into messages (case_id, kind, channel, body, drafted_by, status, sent_at)
    values (c.case_id, 'appointment', 'app',
            format('Reminder: your appointment with %s is on %s at %s.', c.ref_to, fmt_date(c.appointment_at),
                   to_char(c.appointment_at at time zone 'Asia/Dubai', 'HH24:MI')),
            'template', 'sent', now());
    insert into audit_log (actor, action, case_id, detail) values ('workflow:followup', 'reminder.sent', c.case_id, '{"type": "appointment"}');
    v_rem := v_rem + 1;
  end loop;

  -- 6. Missed appointments
  for c in
    select r.* from referrals r join cases cs on cs.id = r.case_id
     where r.status = 'booked' and r.appointment_at + missed * d < now() and cs.status = 'booked'
  loop
    update referrals set status = 'no-show' where id = c.id;
    perform escalate_case(c.case_id, 'Missed appointment');
    v_esc := v_esc + 1;
  end loop;

  -- 7. Urgent cases not dealt with by the end of the day, and any deadline that has passed
  for c in
    select id, priority from cases
     where status in ('referred', 'notified', 'booked') and due_at < now()
  loop
    perform escalate_case(c.id, case when c.priority = 'P1' then 'Urgent case not actioned by end of day' else 'Deadline passed' end);
    v_esc := v_esc + 1;
  end loop;

  -- 8. Alerts for the coordinator: every new urgent case and every escalation, once each
  for c in
    select cs.id, cs.priority, cs.status, cs.due_at, p.mrn, cl.name as clinic,
           case when cs.status = 'escalated' then 'escalated' else 'urgent' end as alert_type,
           (select detail->>'reason' from audit_log a where a.case_id = cs.id and a.action = 'case.escalated' order by a.id desc limit 1) as reason,
           (select string_agg(f.value_text, ', ' order by f.priority) from case_findings f where f.case_id = cs.id) as readings
      from cases cs join patients p on p.id = cs.patient_id left join clinics cl on cl.id = p.clinic_id
     where (cs.status = 'escalated'
            and not exists (select 1 from audit_log a where a.case_id = cs.id and a.action = 'alert.queued' and a.detail->>'type' = 'escalated'))
        or (cs.priority = 'P1' and cs.status not in ('closed', 'lost', 'escalated')
            and not exists (select 1 from audit_log a where a.case_id = cs.id and a.action = 'alert.queued' and a.detail->>'type' = 'urgent'))
  loop
    insert into audit_log (actor, action, case_id, detail)
    values ('workflow:followup', 'alert.queued', c.id, jsonb_build_object('type', c.alert_type));
    v_alerts := v_alerts || jsonb_build_object(
      'case_id', c.id, 'type', c.alert_type, 'priority', c.priority, 'mrn', c.mrn, 'clinic', c.clinic,
      'reason', coalesce(c.reason, 'Urgent result: same-day action needed'),
      'readings', c.readings, 'deadline', fmt_date(c.due_at),
      'to', setting('coordinator_email'));
  end loop;

  return jsonb_build_object('messages_sent', v_sent, 'reminders_sent', v_rem, 'escalated', v_esc,
                            'closed', v_closed, 'demo_mode', setting('demo_mode') = 'true', 'alerts', v_alerts);
end $$;


create or replace function record_alert(p_case_id bigint, p_type text, p_status text, p_detail text default null)
returns void language plpgsql set search_path = public as $$
begin
  insert into audit_log (actor, action, case_id, detail)
  values ('workflow:followup', 'alert.' || p_status, p_case_id, jsonb_build_object('type', p_type, 'detail', p_detail));
end $$;


create or replace function approve_message(p_message_id bigint, p_practitioner_id text, p_body text default null)
returns jsonb language plpgsql set search_path = public as $$
declare v_case bigint;
begin
  update messages
     set status = 'approved', approved_by = p_practitioner_id, approved_at = now(), body = coalesce(p_body, body)
   where id = p_message_id and status = 'draft'
  returning case_id into v_case;
  if v_case is null then raise exception 'Message % is not a draft', p_message_id; end if;
  insert into audit_log (actor, action, case_id, detail)
  values (p_practitioner_id, 'message.approved', v_case,
          jsonb_build_object('message_id', p_message_id, 'edited', p_body is not null));
  return jsonb_build_object('message_id', p_message_id, 'case_id', v_case, 'status', 'approved');
end $$;


create or replace function book_appointment(p_case_id bigint, p_appointment_at timestamptz, p_by text default 'patient')
returns jsonb language plpgsql set search_path = public as $$
declare v_ref bigint; v_gp text;
begin
  select id into v_ref from referrals where case_id = p_case_id and status in ('pending', 'no-show') order by id limit 1;
  if v_ref is null then
    -- repeat-test cases have no referral yet: book with the patient's own clinic doctor
    select p.gp_id into v_gp from cases c join patients p on p.id = c.patient_id where c.id = p_case_id;
    insert into referrals (case_id, practitioner_id, mode, in_network, reason)
    values (p_case_id, v_gp, 'in-person', true, 'Repeat test with own family doctor') returning id into v_ref;
  end if;
  update referrals set status = 'booked', appointment_at = p_appointment_at where id = v_ref;
  update cases set status = 'booked' where id = p_case_id and status not in ('closed', 'lost', 'attended');
  insert into audit_log (actor, action, case_id, detail)
  values (p_by, 'appointment.booked', p_case_id, jsonb_build_object('referral_id', v_ref, 'appointment_at', p_appointment_at));
  return jsonb_build_object('case_id', p_case_id, 'referral_id', v_ref, 'status', 'booked');
end $$;


create or replace function record_attendance(p_case_id bigint, p_attended boolean, p_by text)
returns jsonb language plpgsql set search_path = public as $$
begin
  update referrals set status = case when p_attended then 'attended' else 'no-show' end
   where case_id = p_case_id and status = 'booked';
  if p_attended then
    update cases set status = 'attended' where id = p_case_id;
  else
    perform escalate_case(p_case_id, 'Missed appointment (recorded by clinic)');
  end if;
  insert into audit_log (actor, action, case_id, detail)
  values (p_by, case when p_attended then 'appointment.attended' else 'appointment.missed' end, p_case_id, '{}');
  return jsonb_build_object('case_id', p_case_id, 'attended', p_attended);
end $$;


create or replace function record_outcome(p_case_id bigint, p_outcome text, p_practitioner_id text, p_lost boolean default false)
returns jsonb language plpgsql set search_path = public as $$
begin
  if coalesce(trim(p_outcome), '') = '' then raise exception 'An outcome is required to close a case'; end if;
  update cases
     set status = case when p_lost then 'lost'::case_status else 'closed'::case_status end,
         outcome = p_outcome, outcome_by = p_practitioner_id, closed_at = now()
   where id = p_case_id;
  insert into audit_log (actor, action, case_id, detail)
  values (p_practitioner_id, case when p_lost then 'case.lost' else 'case.closed' end, p_case_id,
          jsonb_build_object('outcome', p_outcome));
  return jsonb_build_object('case_id', p_case_id, 'status', case when p_lost then 'lost' else 'closed' end);
end $$;


revoke all on function run_followups() from public, anon, authenticated;
revoke all on function record_alert(bigint, text, text, text) from public, anon, authenticated;
revoke all on function approve_message(bigint, text, text) from public, anon, authenticated;
revoke all on function book_appointment(bigint, timestamptz, text) from public, anon, authenticated;
revoke all on function record_attendance(bigint, boolean, text) from public, anon, authenticated;
revoke all on function record_outcome(bigint, text, text, boolean) from public, anon, authenticated;
grant execute on function run_followups() to service_role;
grant execute on function record_alert(bigint, text, text, text) to service_role;
grant execute on function approve_message(bigint, text, text) to service_role;
grant execute on function book_appointment(bigint, timestamptz, text) to service_role;
grant execute on function record_attendance(bigint, boolean, text) to service_role;
grant execute on function record_outcome(bigint, text, text, boolean) to service_role;
