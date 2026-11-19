-- CareLoop demo video prep. Run in the Supabase SQL editor, the whole file at once.
--
-- When: after  select demo_reset('RESET CARELOOP DEMO');  and the benchmark, once workflow 2
-- has drafted the messages (about 15 minutes). If the drafts aren't ready it stops and says so.
--
-- What it does, so the video doesn't have to wait for real days:
--   1. Turns the demo clock on: one day becomes one minute.
--   2. Signs Rashid (CL-0032) in to the app once and agrees to messages, so the consent screen
--      doesn't interrupt the take. His message stays waiting for Dr Aisha to approve on camera.
--   3. Roderick (CL-0054): his doctor approved and the message went out 11 "days" ago, with no booking.
--      On its next run (within a minute) workflow 3 hands him to Layla and emails the alert.
--   4. Two patients were told 4 and 8 "days" ago, so reminders 1 and 2 go out on the next run.
--   5. Three patients have gone all the way round: approved, told, booked, attended, outcome recorded.
--      The dashboard then shows closed loops instead of a zero.
--
-- Rashid, and the rehearsal patients Lulu (CL-0039) and Verline (CL-0064), are left alone.
-- Afterwards, for the judges: turn the demo clock off (last line of this file, commented out),
-- then run the demo reset and the benchmark again.

do $$
declare
  d        interval;
  reserved text[] := array['CL-0032', 'CL-0054', 'CL-0039', 'CL-0064'];
  c        record;
  v_msg    bigint;
  v_told   timestamptz;
  v_rashid cases%rowtype;
  n        int := 0;
  outcomes text[] := array[
    'Seen by the family doctor. Result confirmed on a repeat test and a care plan agreed. Review in 4 weeks.',
    'Seen by the family doctor. Result discussed, follow-up tests arranged, review in 3 months.',
    'Seen by the family doctor. Treatment started and a review appointment booked with the clinic.'];
begin
  update settings set value = 'true' where key = 'demo_mode';
  d := followup_day();

  -- Stop if workflow 2 hasn't drafted Rashid's message yet
  select cs.* into v_rashid from cases cs join patients p on p.id = cs.patient_id
   where p.mrn = 'CL-0032' and cs.status not in ('closed', 'lost') order by cs.opened_at desc limit 1;
  if v_rashid.id is null then
    raise exception 'Rashid has no open case. Run the demo reset and the benchmark first.';
  end if;
  if not exists (select 1 from messages where case_id = v_rashid.id and kind = 'result' and status = 'draft') then
    raise exception 'Rashid''s message has not been drafted yet. Wait a few minutes for workflow 2, then run this again.';
  end if;

  -- 2. Rashid agrees to app messages, exactly as tapping "agree" in the app would
  perform patient_app('CL-0032', '1981-08-29', 'consent', '{"accept": true}'::jsonb);

  -- 3. Roderick: told 11 days ago, never booked
  for c in
    select cs.id, cs.opened_at, p.gp_id, m.id as msg_id from cases cs
      join patients p on p.id = cs.patient_id
      join messages m on m.case_id = cs.id and m.kind = 'result' and m.status = 'draft'
     where p.mrn = 'CL-0054' and cs.status = 'referred'
  loop
    v_told := now() - 11 * d;
    update messages set status = 'sent', approved_by = c.gp_id, approved_at = v_told, sent_at = v_told where id = c.msg_id;
    update cases set status = 'notified' where id = c.id;
    insert into audit_log (actor, action, case_id, detail, at) values
      (c.gp_id, 'message.approved', c.id, jsonb_build_object('message_id', c.msg_id, 'edited', false), v_told),
      ('workflow:followup', 'message.sent', c.id, jsonb_build_object('message_id', c.msg_id, 'channel', 'app'), v_told + interval '1 second');
  end loop;

  -- 4 and 5. Pick the other patients the same way every time: routine cases with a draft, a phone and
  -- consent, not Dr Aisha's (her queue stays focused on Rashid), not the reserved ones.
  for c in
    select cs.id, cs.opened_at, p.gp_id, p.mrn, m.id as msg_id from cases cs
      join patients p on p.id = cs.patient_id
      join messages m on m.case_id = cs.id and m.kind = 'result' and m.status = 'draft'
     where cs.status = 'referred' and cs.priority in ('P2', 'P3')
       and p.phone is not null and p.consent_status = 'active' and not cs.contact_flag
       and p.gp_id <> 'dr-07' and p.mrn <> all (reserved)
       and exists (select 1 from referrals r where r.case_id = cs.id and r.practitioner_id = p.gp_id)
     order by p.mrn
     limit 5
  loop
    n := n + 1;
    if n <= 3 then
      -- Full loop: approved, told, booked, attended, closed by the family doctor
      v_told := now() - 6 * d;
      update messages set status = 'sent', approved_by = c.gp_id, approved_at = v_told, sent_at = v_told where id = c.msg_id;
      update referrals set status = 'attended', appointment_at = now() - 2 * d where case_id = c.id and status = 'pending';
      update cases set status = 'closed', outcome = outcomes[n], outcome_by = c.gp_id, closed_at = now() - d / 2 where id = c.id;
      insert into audit_log (actor, action, case_id, detail, at) values
        (c.gp_id, 'message.approved', c.id, jsonb_build_object('message_id', c.msg_id, 'edited', false), v_told),
        ('workflow:followup', 'message.sent', c.id, jsonb_build_object('message_id', c.msg_id, 'channel', 'app'), v_told + interval '1 second'),
        ('patient:' || c.mrn, 'appointment.booked', c.id, jsonb_build_object('appointment_at', now() - 2 * d), now() - 5 * d),
        (c.gp_id, 'appointment.attended', c.id, '{}'::jsonb, now() - d),
        (c.gp_id, 'case.closed', c.id, jsonb_build_object('outcome', outcomes[n]), now() - d / 2);
    else
      -- Told 4 or 8 days ago, not booked yet: workflow 3 sends reminder 1 or 2 on its next run
      v_told := now() - (case when n = 4 then 4 else 8 end) * d;
      update messages set status = 'sent', approved_by = c.gp_id, approved_at = v_told, sent_at = v_told where id = c.msg_id;
      update cases set status = 'notified' where id = c.id;
      insert into audit_log (actor, action, case_id, detail, at) values
        (c.gp_id, 'message.approved', c.id, jsonb_build_object('message_id', c.msg_id, 'edited', false), v_told),
        ('workflow:followup', 'message.sent', c.id, jsonb_build_object('message_id', c.msg_id, 'channel', 'app'), v_told + interval '1 second');
      if n = 5 then  -- the second reminder only goes out after the first
        insert into messages (case_id, kind, channel, body, drafted_by, status, sent_at)
        values (c.id, 'reminder', 'app', 'Reminder: your screening results need a follow-up. Please book your appointment in the app.',
                'template', 'sent', now() - 5 * d);
        insert into audit_log (actor, action, case_id, detail, at)
        values ('workflow:followup', 'reminder.sent', c.id, '{"number": 1}'::jsonb, now() - 5 * d);
      end if;
    end if;
  end loop;

  raise notice 'Done. Demo clock on. Rashid is waiting for Dr Aisha. Roderick goes to Layla on the next run of workflow 3.';
end $$;

-- Check what you've got
select p.mrn, p.given_name || ' ' || p.family_name as patient, c.priority, c.status,
       (select count(*) from messages m where m.case_id = c.id and m.kind = 'reminder') as reminders
  from cases c join patients p on p.id = c.patient_id
 where c.status in ('notified', 'closed') or p.mrn in ('CL-0032', 'CL-0054')
 order by c.status, p.mrn;

-- After recording, for the judges, run this line on its own, then the demo reset and the benchmark:
-- update settings set value = 'false' where key = 'demo_mode';
