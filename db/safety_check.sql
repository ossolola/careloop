-- CareLoop safety and data check. Read-only: it changes nothing.
-- Run the whole file in the Supabase SQL editor. Every row should say PASS.
-- Anything that says CHECK needs a look; the detail column says what and where.

with
our_functions as (
  select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as args
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('receive_result', 'record_decision', 'prepare_referrals', 'save_message_draft', 'run_followups',
                      'record_alert', 'approve_message', 'book_appointment', 'record_attendance', 'record_outcome',
                      'escalate_case', 'patient_app', 'app_slots', 'care_team', 'team_case_row', 'team_case_detail',
                      'team_can_see', 'demo_reset', 'setting', 'followup_day', 'fmt_date')
),
checks(n, area, check_name, ok, detail) as (

  -- ---------- Access ----------
  select 1, 'Access', 'Row level security is on for every table',
         not exists (select 1 from pg_tables where schemaname = 'public' and not rowsecurity),
         coalesce((select string_agg(tablename, ', ') from pg_tables where schemaname = 'public' and not rowsecurity), 'all tables')
  union all
  select 2, 'Access', 'No table policies that would let the public API read data',
         not exists (select 1 from pg_policies where schemaname = 'public'),
         coalesce((select string_agg(tablename || ': ' || policyname, ', ') from pg_policies where schemaname = 'public'), 'no policies')
  union all
  select 3, 'Access', 'The public (anon) key cannot run any CareLoop function',
         not exists (select 1 from our_functions where has_function_privilege('anon', oid, 'execute')),
         coalesce((select string_agg(proname, ', ') from our_functions where has_function_privilege('anon', oid, 'execute')), 'none can')
  union all
  select 4, 'Access', 'Signed-in API users (authenticated) cannot run any CareLoop function',
         not exists (select 1 from our_functions where has_function_privilege('authenticated', oid, 'execute')),
         coalesce((select string_agg(proname, ', ') from our_functions where has_function_privilege('authenticated', oid, 'execute')), 'none can')
  union all
  select 5, 'Access', 'Demo reset can only be run from the SQL editor',
         not exists (select 1 from our_functions where proname = 'demo_reset' and has_function_privilege('service_role', oid, 'execute')),
         'n8n, the app and the dashboard cannot call it'
  union all
  select 6, 'Access', 'Audit log is append-only (edits and deletes blocked)',
         exists (select 1 from pg_trigger where tgname = 'audit_log_no_update' and not tgisinternal),
         'trigger audit_log_no_update'
  union all
  select 7, 'Access', 'Staff PIN has been set',
         exists (select 1 from settings where key = 'staff_pin' and coalesce(value, '') <> ''),
         'demo PIN; a pilot would use the clinic''s staff sign-on'

  -- ---------- Patient safety ----------
  union all
  select 10, 'Patient safety', 'No result message reached a patient without a doctor''s approval',
         not exists (select 1 from messages where kind = 'result' and status = 'sent' and approved_by is null),
         coalesce((select string_agg('message ' || id, ', ') from messages where kind = 'result' and status = 'sent' and approved_by is null), 'every sent result message has an approver')
  union all
  select 11, 'Patient safety', 'Every urgent (P1) message carries the call-998 safety line',
         not exists (select 1 from messages m join cases c on c.id = m.case_id
                      where c.priority = 'P1' and m.kind = 'result' and m.body not ilike '%998%'),
         coalesce((select string_agg('message ' || m.id, ', ') from messages m join cases c on c.id = m.case_id
                    where c.priority = 'P1' and m.kind = 'result' and m.body not ilike '%998%'), 'all have it')
  union all
  select 12, 'Patient safety', 'No urgent case is past its deadline without a booking or the coordinator',
         not exists (select 1 from cases where priority = 'P1' and due_at < now() and status not in ('escalated', 'booked', 'closed', 'lost')),
         coalesce((select string_agg('case ' || id || ' (' || status || ')', ', ') from cases
                    where priority = 'P1' and due_at < now() and status not in ('escalated', 'booked', 'closed', 'lost')), 'none')
  union all
  select 13, 'Patient safety', 'Results the rules refused to guess about did not open a case',
         not exists (select 1 from inbound_results i join cases c on c.inbound_id = i.id where i.status = 'stopped'),
         'stopped results go to the data check list only'
  union all
  select 14, 'Patient safety', 'Patients with no phone or who declined messages are flagged for the coordinator',
         not exists (select 1 from cases c join patients p on p.id = c.patient_id
                      where (p.phone is null or p.consent_status = 'rejected') and not c.contact_flag
                        and c.status not in ('escalated', 'closed', 'lost')
                        and not exists (select 1 from audit_log a where a.case_id = c.id and a.action = 'consent.given')),
         coalesce((select string_agg('case ' || c.id, ', ') from cases c join patients p on p.id = c.patient_id
                    where (p.phone is null or p.consent_status = 'rejected') and not c.contact_flag
                      and c.status not in ('escalated', 'closed', 'lost')
                      and not exists (select 1 from audit_log a where a.case_id = c.id and a.action = 'consent.given')), 'none missed')
  union all
  select 15, 'Patient safety', 'Only a doctor closed cases that needed clinical follow-up (advice-only cases close on their own once the advice is sent)',
         not exists (select 1 from audit_log a left join practitioners p on p.id = a.actor
                      where a.action = 'case.closed' and coalesce(p.role, '') <> 'family-doctor'
                        and coalesce(a.detail->>'reason', '') <> 'advice-only case'),
         coalesce((select string_agg('case ' || a.case_id || ' by ' || a.actor, ', ') from audit_log a left join practitioners p on p.id = a.actor
                    where a.action = 'case.closed' and coalesce(p.role, '') <> 'family-doctor'
                        and coalesce(a.detail->>'reason', '') <> 'advice-only case'), 'all closed by doctors')

  -- ---------- Data ----------
  union all
  select 20, 'Data', 'Every processed result either opened a case or was logged as needing no follow-up',
         not exists (select 1 from inbound_results i where i.status = 'processed'
                      and not exists (select 1 from cases c where c.inbound_id = i.id)
                      and not exists (select 1 from audit_log a where a.inbound_id = i.id and a.action = 'result.no_flag')),
         coalesce((select string_agg('result ' || id, ', ') from inbound_results i where i.status = 'processed'
                    and not exists (select 1 from cases c where c.inbound_id = i.id)
                    and not exists (select 1 from audit_log a where a.inbound_id = i.id and a.action = 'result.no_flag')), 'all accounted for')
  union all
  select 21, 'Data', 'Every case has at least one finding and a deadline',
         not exists (select 1 from cases c where c.due_at is null or not exists (select 1 from case_findings f where f.case_id = c.id)),
         coalesce((select string_agg('case ' || id, ', ') from cases c
                    where c.due_at is null or not exists (select 1 from case_findings f where f.case_id = c.id)), 'all complete')
  union all
  select 22, 'Data', 'No result is stuck half-processed for more than 10 minutes',
         not exists (select 1 from inbound_results where status = 'received' and received_at < now() - interval '10 minutes'),
         coalesce((select string_agg('result ' || id, ', ') from inbound_results
                    where status = 'received' and received_at < now() - interval '10 minutes'), 'none stuck')
  union all
  select 23, 'Data', 'No case is waiting more than 10 minutes for a referral',
         not exists (select 1 from cases where status = 'new' and opened_at < now() - interval '10 minutes'),
         coalesce((select string_agg('case ' || id, ', ') from cases where status = 'new' and opened_at < now() - interval '10 minutes'),
                  'none waiting') || ' (workflow 2 makes referrals; if this fails, is it switched on?)'
  union all
  select 24, 'Data', 'Every case has a "case opened" entry in the audit log',
         not exists (select 1 from cases c where not exists (select 1 from audit_log a where a.case_id = c.id and a.action = 'case.opened')),
         coalesce((select string_agg('case ' || id, ', ') from cases c
                    where not exists (select 1 from audit_log a where a.case_id = c.id and a.action = 'case.opened')), 'all logged')
  union all
  select 25, 'Data', 'Every referral points at a real doctor or service',
         not exists (select 1 from referrals where practitioner_id is null and service_id is null),
         coalesce((select string_agg('referral ' || id, ', ') from referrals where practitioner_id is null and service_id is null), 'all valid')
  union all
  select 26, 'Data', 'Demo clock setting',
         true,
         'demo_mode is ' || coalesce((select value from settings where key = 'demo_mode'), 'not set')
         || case when (select value from settings where key = 'demo_mode') = 'true' then ' (1 day = 1 minute)' else ' (real days)' end
)
select area, check_name, case when ok then 'PASS' else 'CHECK' end as result, detail
from checks
order by n;
