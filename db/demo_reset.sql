-- CareLoop demo reset. Run in the Supabase SQL editor after the other function files. Safe to re-run.
--
-- Clears every result, case, referral, message and audit entry so the next demo starts from nothing.
-- Keeps patients, plans, clinics, doctors, services and settings. Puts each patient's consent back to
-- what their record said when it was loaded, and clears the "agreed in the app" date.
--
-- To use it:  select demo_reset('RESET CARELOOP DEMO');
-- Then run benchmark/send_benchmark.py to load a fresh set of results dated today.
--
-- It is not granted to service_role, so nothing outside the SQL editor (n8n, the app, the dashboard) can call it.

create or replace function demo_reset(p_confirm text) returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_before jsonb;
begin
  if p_confirm is distinct from 'RESET CARELOOP DEMO' then
    raise exception 'Nothing was cleared. To reset, run: select demo_reset(''RESET CARELOOP DEMO'');';
  end if;

  v_before := jsonb_build_object(
    'results',  (select count(*) from inbound_results),
    'cases',    (select count(*) from cases),
    'messages', (select count(*) from messages),
    'audit_entries', (select count(*) from audit_log));

  -- truncate skips the row trigger that keeps audit_log append-only, which is the point of a reset
  truncate messages, referrals, case_findings, cases, inbound_results, audit_log restart identity cascade;

  update patients p
     set consent_status = coalesce(
           (select e->'resource'->>'status'
              from jsonb_array_elements(p.fhir->'entry') e
             where e->'resource'->>'resourceType' = 'Consent'
             limit 1), 'active'),
         app_consent_at = null;

  insert into audit_log (actor, action, detail)
  values ('admin:sql-editor', 'demo.reset', jsonb_build_object('cleared', v_before));

  return jsonb_build_object('ok', true, 'cleared', v_before);
end $$;

revoke all on function demo_reset(text) from public, anon, authenticated, service_role;
