-- CareLoop care-team dashboard backend, called by workflow 5 (the dashboard never talks to Supabase directly).
-- Run in the Supabase SQL editor after the other function files. Safe to re-run.
--
-- care_team(staff_id, pin, action, payload)
--   staff (no login), overview, case, approve, book, attendance, outcome, note
--   Only family doctors may approve patient messages or close a case with an outcome.
--   The coordinator sees every case. A doctor only sees cases where they are the patient's family doctor
--   or the doctor the patient was referred to. This is checked here, not just hidden in the page.

insert into practitioners (id, name, role, clinic_id)
values ('coord-01', 'Layla Demo', 'coordinator', null)
on conflict (id) do nothing;

insert into settings (key, value) values ('staff_pin', '2026') on conflict (key) do nothing;

create or replace function team_case_row(p_case_id bigint) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object(
    'case_id', c.id, 'priority', c.priority, 'status', c.status, 'route', c.route,
    'patient', p.given_name || ' ' || p.family_name, 'mrn', p.mrn,
    'age', date_part('year', age(p.birth_date))::int, 'sex', p.gender,
    'clinic', cl.name, 'family_doctor', pr.name, 'gp_id', p.gp_id,
    'findings', (select string_agg(f.value_text, ', ' order by f.priority) from case_findings f where f.case_id = c.id),
    'due_at', c.due_at, 'deadline', fmt_date(c.due_at), 'overdue', c.due_at < now() and c.status not in ('closed', 'lost'),
    'opened_at', c.opened_at, 'contact_flag', c.contact_flag, 'test_case_id', c.test_case_id,
    'escalation_reason', (select a.detail->>'reason' from audit_log a where a.case_id = c.id and a.action = 'case.escalated' order by a.id desc limit 1)
  )
  from cases c join patients p on p.id = c.patient_id
  left join clinics cl on cl.id = p.clinic_id
  left join practitioners pr on pr.id = p.gp_id
  where c.id = p_case_id
$$;

create or replace function team_case_detail(p_case_id bigint) returns jsonb
language sql stable set search_path = public as $$
  select team_case_row(c.id) || jsonb_build_object(
    'outcome', c.outcome, 'closed_at', c.closed_at,
    'contact', jsonb_build_object('phone', p.phone, 'email', p.email, 'consent', p.consent_status, 'district', p.district),
    'plan', pl.name,
    'findings_list', (select jsonb_agg(jsonb_build_object('rule_code', f.rule_code, 'priority', f.priority, 'value', f.value_text, 'target_days', f.target_days) order by f.priority)
                        from case_findings f where f.case_id = c.id),
    'referrals', (select jsonb_agg(jsonb_build_object('id', r.id, 'to', coalesce(pr.name, s.name), 'mode', r.mode, 'status', r.status,
                                   'in_network', r.in_network, 'reason', r.reason, 'appointment_at', r.appointment_at) order by r.id)
                    from referrals r left join practitioners pr on pr.id = r.practitioner_id left join services s on s.id = r.service_id
                   where r.case_id = c.id),
    'messages', (select jsonb_agg(jsonb_build_object('id', m.id, 'kind', m.kind, 'channel', m.channel, 'body', m.body, 'drafted_by', m.drafted_by,
                                  'status', m.status, 'approved_by', ap.name, 'sent_at', m.sent_at, 'created_by_ai', m.drafted_by = 'gemini') order by m.id)
                   from messages m left join practitioners ap on ap.id = m.approved_by where m.case_id = c.id),
    'timeline', (select jsonb_agg(jsonb_build_object('at', a.at, 'actor', coalesce(st.name, a.actor), 'action', a.action, 'detail', a.detail) order by a.at, a.id)
                   from audit_log a left join practitioners st on st.id = a.actor
                  where a.case_id = c.id or a.inbound_id = c.inbound_id)
  )
  from cases c join patients p on p.id = c.patient_id left join plans pl on pl.id = p.plan_id
  where c.id = p_case_id
$$;


create or replace function team_can_see(p_staff_id text, p_case_id bigint) returns boolean
language sql stable set search_path = public as $$
  select exists (select 1 from practitioners where id = p_staff_id and role = 'coordinator')
      or exists (select 1 from cases c join patients p on p.id = c.patient_id where c.id = p_case_id and p.gp_id = p_staff_id)
      or exists (select 1 from referrals r where r.case_id = p_case_id and r.practitioner_id = p_staff_id)
$$;


create or replace function care_team(p_staff_id text, p_pin text, p_action text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_me     practitioners%rowtype;
  v_case   bigint := nullif(p_payload->>'case_id', '')::bigint;
  v_doctor boolean;
  v_ids    bigint[];
  v_msg    bigint;
begin
  if p_action = 'staff' then
    return jsonb_build_object('ok', true, 'staff',
      (select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'role', role) order by role desc, name) from practitioners where role in ('coordinator', 'family-doctor')));
  end if;

  select * into v_me from practitioners where id = p_staff_id;
  if not found or p_pin is distinct from setting('staff_pin') then
    return jsonb_build_object('ok', false, 'error', 'Name or PIN not recognised.');
  end if;
  v_doctor := v_me.role = 'family-doctor';

  if p_action = 'approve' then
    v_msg  := nullif(p_payload->>'message_id', '')::bigint;
    v_case := (select case_id from messages where id = v_msg);
    if v_case is null then
      return jsonb_build_object('ok', false, 'error', 'Message not found.');
    end if;
  end if;

  if v_case is not null and (not exists (select 1 from cases where id = v_case) or not team_can_see(v_me.id, v_case)) then
    return jsonb_build_object('ok', false, 'error', 'Case not found.');
  end if;

  -- The cases this person is allowed to see
  v_ids := array(select id from cases where team_can_see(v_me.id, id));

  if p_action = 'overview' then
    return jsonb_build_object('ok', true,
      'me', jsonb_build_object('id', v_me.id, 'name', v_me.name, 'role', v_me.role),
      'demo_mode', setting('demo_mode') = 'true',
      'kpis', jsonb_build_object(
        'open', (select count(*) from cases where id = any(v_ids) and status not in ('closed', 'lost')),
        'urgent', (select count(*) from cases where id = any(v_ids) and priority = 'P1' and status not in ('closed', 'lost')),
        'awaiting_approval', (select count(*) from messages where case_id = any(v_ids) and status = 'draft' and kind = 'result'),
        'escalated', (select count(*) from cases where id = any(v_ids) and status = 'escalated'),
        'overdue', (select count(*) from cases where id = any(v_ids) and due_at < now() and status not in ('closed', 'lost')),
        'closed', (select count(*) from cases where id = any(v_ids) and status = 'closed'),
        'lost', (select count(*) from cases where id = any(v_ids) and status = 'lost'),
        'closed_on_time_pct', (select round(100.0 * count(*) filter (where closed_at <= due_at) / nullif(count(*), 0)) from cases where id = any(v_ids) and status = 'closed'),
        'median_days_to_close', (select round(extract(epoch from percentile_cont(0.5) within group (order by closed_at - opened_at)) / 86400.0, 1) from cases where id = any(v_ids) and status = 'closed')
      ),
      'approvals', coalesce((select jsonb_agg(team_case_row(m.case_id) || jsonb_build_object(
            'message_id', m.id, 'body', m.body, 'drafted_by', m.drafted_by,
            'check_notes', (select a.detail->>'check_notes' from audit_log a where a.case_id = m.case_id and a.action = 'message.drafted' and (a.detail->>'message_id')::bigint = m.id limit 1),
            'mine', (select p.gp_id from cases c join patients p on p.id = c.patient_id where c.id = m.case_id) = v_me.id)
          order by (select priority from cases where id = m.case_id), m.id)
          from messages m where m.case_id = any(v_ids) and m.status = 'draft' and m.kind = 'result'), '[]'::jsonb),
      'cases', coalesce((select jsonb_agg(team_case_row(c.id) order by c.priority, c.due_at)
          from cases c where c.id = any(v_ids) and c.status not in ('closed', 'lost')), '[]'::jsonb),
      'closed', coalesce((select jsonb_agg(team_case_row(c.id) || jsonb_build_object('outcome', c.outcome, 'closed_at', c.closed_at) order by c.closed_at desc)
          from (select * from cases where id = any(v_ids) and status in ('closed', 'lost') order by closed_at desc limit 30) c), '[]'::jsonb),
      'data_check', coalesce((select jsonb_agg(jsonb_build_object('inbound_id', i.id, 'received_at', i.received_at, 'reason', i.stop_reason,
            'test_case_id', i.test_case_id, 'patient_ref', i.patient_ref,
            'detail', (select a.detail->>'detail' from audit_log a where a.inbound_id = i.id and a.action = 'result.stopped' limit 1)) order by i.received_at desc)
          from inbound_results i where i.status = 'stopped' and not v_doctor), '[]'::jsonb)
    );

  elsif p_action = 'case' then
    return jsonb_build_object('ok', true, 'case', team_case_detail(v_case));

  elsif p_action = 'approve' then
    if not v_doctor then
      return jsonb_build_object('ok', false, 'error', 'Only a doctor can approve a patient message.');
    end if;
    perform approve_message(v_msg, v_me.id, nullif(trim(coalesce(p_payload->>'body', '')), ''));

  elsif p_action = 'book' then
    perform book_appointment(v_case, (p_payload->>'appointment_at')::timestamptz, v_me.id);

  elsif p_action = 'attendance' then
    perform record_attendance(v_case, (p_payload->>'attended')::boolean, v_me.id);

  elsif p_action = 'outcome' then
    if coalesce((p_payload->>'lost')::boolean, false) then
      perform record_outcome(v_case, p_payload->>'outcome', v_me.id, true);
    elsif not v_doctor then
      return jsonb_build_object('ok', false, 'error', 'Only a doctor can record the clinical outcome and close the case.');
    else
      perform record_outcome(v_case, p_payload->>'outcome', v_me.id, false);
    end if;

  elsif p_action = 'note' then
    if coalesce(trim(p_payload->>'note'), '') = '' then
      return jsonb_build_object('ok', false, 'error', 'Write a note first.');
    end if;
    insert into audit_log (actor, action, case_id, detail)
    values (v_me.id, 'team.note', v_case, jsonb_build_object('note', left(p_payload->>'note', 1000)));

  else
    return jsonb_build_object('ok', false, 'error', 'Unknown action');
  end if;

  return jsonb_build_object('ok', true, 'case', team_case_detail(v_case));
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end $$;

revoke all on function care_team(text, text, text, jsonb) from public, anon, authenticated;
revoke all on function team_case_row(bigint) from public, anon, authenticated;
revoke all on function team_case_detail(bigint) from public, anon, authenticated;
revoke all on function team_can_see(text, bigint) from public, anon, authenticated;
grant execute on function care_team(text, text, text, jsonb) to service_role;
