-- CareLoop patient app backend, called by workflow 4 (the app never talks to Supabase directly).
-- Run in the Supabase SQL editor after the other function files. Safe to re-run.
--
-- patient_app(mrn, dob, action, payload)
--   actions: home, consent, book, help, attended
--   every call checks MRN + date of birth first (demo login; a real rollout would use UAE PASS / Sahatna)

alter table patients add column if not exists app_consent_at timestamptz;

-- Mock appointment slots: next 5 working days (Mon to Fri, UAE weekend is Sat/Sun) at 09:00, 11:00 and 14:30 Abu Dhabi time.
-- In demo mode there is also a slot 2 minutes from now, so the appointment reminder and missed-appointment steps can be shown live.
create or replace function app_slots() returns jsonb
language plpgsql stable set search_path = public as $$
declare
  v_out  jsonb := '[]'::jsonb;
  v_day  date := (now() at time zone 'Asia/Dubai')::date;
  v_n    int := 0;
  v_t    time;
begin
  if setting('demo_mode') = 'true' then
    v_out := v_out || to_jsonb(date_trunc('minute', now()) + interval '2 minutes');
  end if;
  while v_n < 5 loop
    v_day := v_day + 1;
    continue when extract(isodow from v_day) in (6, 7);
    foreach v_t in array array['09:00'::time, '11:00'::time, '14:30'::time] loop
      v_out := v_out || to_jsonb(((v_day + v_t) at time zone 'Asia/Dubai'));
    end loop;
    v_n := v_n + 1;
  end loop;
  return v_out;
end $$;


create or replace function patient_app(p_mrn text, p_dob date, p_action text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_p     patients%rowtype;
  v_case  cases%rowtype;
  v_ref   record;
  v_slot  timestamptz;
  v_case_id bigint;
  v_msgs  jsonb;
  v_consent text;
begin
  select * into v_p from patients where upper(mrn) = upper(trim(p_mrn)) and birth_date = p_dob;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'We could not find you with those details. Check your record number and date of birth.');
  end if;

  -- Most recent case that is still open, or the latest closed one
  select * into v_case from cases where patient_id = v_p.id
   order by (status in ('closed', 'lost')), opened_at desc limit 1;

  v_case_id := nullif(p_payload->>'case_id', '')::bigint;
  if p_action in ('book', 'help', 'attended') and (v_case.id is null or v_case_id is distinct from v_case.id) then
    return jsonb_build_object('ok', false, 'error', 'That follow-up does not belong to this record.');
  end if;

  if p_action = 'consent' then
    if coalesce((p_payload->>'accept')::boolean, false) then
      update patients set consent_status = 'active', app_consent_at = now() where id = v_p.id;
      insert into audit_log (actor, action, case_id, detail) values ('patient:' || v_p.mrn, 'consent.given', v_case.id, '{}');
    else
      update patients set consent_status = 'rejected', app_consent_at = now() where id = v_p.id;
      insert into audit_log (actor, action, case_id, detail) values ('patient:' || v_p.mrn, 'consent.declined', v_case.id, '{}');
      if v_case.id is not null then
        perform escalate_case(v_case.id, 'Patient declined app messages: coordinator to contact');
      end if;
    end if;

  elsif p_action = 'book' then
    v_slot := (p_payload->>'slot')::timestamptz;
    if v_case.status not in ('notified', 'escalated') then
      return jsonb_build_object('ok', false, 'error', 'This follow-up cannot be booked right now.');
    end if;
    if not exists (select 1 from jsonb_array_elements_text(app_slots()) s where s::timestamptz = v_slot) then
      return jsonb_build_object('ok', false, 'error', 'That time is no longer available. Please pick another.');
    end if;
    perform book_appointment(v_case.id, v_slot, 'patient:' || v_p.mrn);

  elsif p_action = 'help' then
    insert into audit_log (actor, action, case_id, detail)
    values ('patient:' || v_p.mrn, 'patient.asked_for_help', v_case.id,
            jsonb_build_object('note', left(coalesce(p_payload->>'note', ''), 300)));
    perform escalate_case(v_case.id, 'Patient asked for help in the app');

  elsif p_action = 'attended' then
    insert into audit_log (actor, action, case_id, detail)
    values ('patient:' || v_p.mrn, 'patient.reported_attended', v_case.id, '{}');

  elsif p_action <> 'home' then
    return jsonb_build_object('ok', false, 'error', 'Unknown action');
  end if;

  -- Everything below builds the home screen, returned after every action
  select * into v_p from patients where id = v_p.id;
  select * into v_case from cases where id = v_case.id;

  v_consent := case when v_p.app_consent_at is null then 'needed' else v_p.consent_status end;

  select jsonb_agg(jsonb_build_object('kind', m.kind, 'body', m.body, 'sent_at', m.sent_at) order by m.sent_at desc)
    into v_msgs
    from messages m
   where m.case_id = v_case.id and m.status = 'sent' and m.channel = 'app';

  select r.status, r.mode, r.appointment_at, r.in_network,
         coalesce(pr.name, s.name) as to_name, coalesce(cl.name, s.name) as place
    into v_ref
    from referrals r
    left join practitioners pr on pr.id = r.practitioner_id
    left join clinics cl on cl.id = pr.clinic_id
    left join services s on s.id = r.service_id
   where r.case_id = v_case.id
   order by (r.status = 'booked') desc, r.id
   limit 1;

  return jsonb_build_object(
    'ok', true,
    'patient', jsonb_build_object('first_name', v_p.given_name, 'mrn', v_p.mrn, 'consent', v_consent),
    'case', case when v_case.id is null then null else jsonb_build_object(
      'case_id', v_case.id,
      'priority', v_case.priority,
      'status', v_case.status,
      'deadline', fmt_date(v_case.due_at),
      'reviewed', v_msgs is not null,
      'messages', coalesce(v_msgs, '[]'::jsonb),
      'referral', case when v_ref is null then null else jsonb_build_object(
          'to', v_ref.to_name, 'place', v_ref.place, 'mode', v_ref.mode, 'status', v_ref.status,
          'appointment_at', v_ref.appointment_at,
          'appointment_text', case when v_ref.appointment_at is null then null
             else fmt_date(v_ref.appointment_at) || ' at ' || to_char(v_ref.appointment_at at time zone 'Asia/Dubai', 'HH24:MI') end) end,
      'can_book', v_case.status in ('notified', 'escalated') and v_msgs is not null and v_consent = 'active'
                  and coalesce(v_ref.status, 'pending') in ('pending', 'no-show'),
      'outcome', case when v_case.status = 'closed' then v_case.outcome end
    ) end,
    'slots', case when v_case.status in ('notified', 'escalated') then app_slots() else '[]'::jsonb end
  );
end $$;

revoke all on function patient_app(text, date, text, jsonb) from public, anon, authenticated;
revoke all on function app_slots() from public, anon, authenticated;
grant execute on function patient_app(text, date, text, jsonb) to service_role;
grant execute on function app_slots() to service_role;
