-- CareLoop database functions, called by the n8n intake workflow.
-- Run in the Supabase SQL editor after schema.sql. Safe to re-run; does not touch data.
--
-- receive_result   stores an incoming screening result, catches duplicates, returns the patient
-- record_decision  saves what the flagging rules decided, all in one transaction

create or replace function receive_result(p_bundle jsonb)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_message_id text := p_bundle->>'id';
  v_ref        text;
  v_patient    patients%rowtype;
  v_inbound    bigint;
  v_tag        text;
begin
  if v_message_id is null then
    raise exception 'Result bundle has no id';
  end if;

  -- The patient the lab says this result belongs to
  select split_part(e->'resource'->'subject'->>'reference', '/', 2)
    into v_ref
    from jsonb_array_elements(coalesce(p_bundle->'entry', '[]')) e
   where e->'resource'->>'resourceType' = 'Observation'
   limit 1;

  select * into v_patient from patients where id::text = v_ref;

  select t->>'code' into v_tag
    from jsonb_array_elements(coalesce(p_bundle->'meta'->'tag', '[]')) t
   where t->>'system' = 'http://careloop.example/codes'
   limit 1;

  insert into inbound_results (message_id, patient_ref, patient_id, test_case_id, bundle)
  values (v_message_id, v_ref, v_patient.id, v_tag, p_bundle)
  on conflict (message_id) do nothing
  returning id into v_inbound;

  if v_inbound is null then
    select id into v_inbound from inbound_results where message_id = v_message_id;
    insert into audit_log (actor, action, inbound_id, detail)
    values ('workflow:intake', 'result.duplicate_ignored', v_inbound, jsonb_build_object('message_id', v_message_id));
    return jsonb_build_object('duplicate', true, 'inbound_id', v_inbound, 'message_id', v_message_id);
  end if;

  insert into audit_log (actor, action, inbound_id, detail)
  values ('workflow:intake', 'result.received', v_inbound,
          jsonb_build_object('message_id', v_message_id, 'patient_ref', v_ref, 'matched', v_patient.id is not null));

  return jsonb_build_object(
    'duplicate', false,
    'inbound_id', v_inbound,
    'message_id', v_message_id,
    'patient_ref', v_ref,
    'test_case_id', v_tag,
    'patient', case when v_patient.id is null then null else jsonb_build_object(
      'id', v_patient.id, 'gender', v_patient.gender, 'birth_date', v_patient.birth_date,
      'phone', v_patient.phone, 'consent_status', v_patient.consent_status) end
  );
end $$;


create or replace function record_decision(p_inbound_id bigint, p_decision jsonb)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_in     inbound_results%rowtype;
  v_status text := p_decision->>'status';
  v_case   bigint;
begin
  select * into v_in from inbound_results where id = p_inbound_id for update;
  if not found then
    raise exception 'Inbound result % not found', p_inbound_id;
  end if;
  if v_in.status <> 'received' then
    raise exception 'Inbound result % was already processed (%)', p_inbound_id, v_in.status;
  end if;

  if v_status = 'stopped' then
    update inbound_results set status = 'stopped', stop_reason = p_decision->>'stop_reason' where id = p_inbound_id;
    insert into audit_log (actor, action, inbound_id, detail)
    values ('workflow:intake', 'result.stopped', p_inbound_id,
            jsonb_build_object('reason', p_decision->>'stop_reason', 'detail', p_decision->>'stop_detail',
                               'rules_version', p_decision->>'rules_version'));
    return jsonb_build_object('outcome', 'stopped', 'case_id', null);

  elsif v_status = 'no_flag' then
    update inbound_results set status = 'processed' where id = p_inbound_id;
    insert into audit_log (actor, action, inbound_id, detail)
    values ('workflow:intake', 'result.no_flag', p_inbound_id,
            jsonb_build_object('rules_version', p_decision->>'rules_version'));
    return jsonb_build_object('outcome', 'no_flag', 'case_id', null);

  elsif v_status = 'flagged' then
    insert into cases (patient_id, inbound_id, priority, route, due_at, contact_flag, test_case_id)
    values (v_in.patient_id, p_inbound_id, (p_decision->>'priority')::priority, p_decision->>'route',
            (p_decision->>'due_at')::timestamptz, coalesce((p_decision->>'contact_flag')::boolean, false), v_in.test_case_id)
    returning id into v_case;

    insert into case_findings (case_id, rule_code, priority, value_text, target_days)
    select v_case, f.rule_code, f.priority::priority, f.value_text, f.target_days
      from jsonb_to_recordset(p_decision->'findings')
        as f(rule_code text, priority text, value_text text, target_days int);

    update inbound_results set status = 'processed' where id = p_inbound_id;

    insert into audit_log (actor, action, case_id, inbound_id, detail)
    values ('workflow:intake', 'case.opened', v_case, p_inbound_id,
            jsonb_build_object('priority', p_decision->>'priority', 'route', p_decision->>'route',
                               'due_at', p_decision->>'due_at', 'contact_reasons', p_decision->'contact_reasons',
                               'findings', p_decision->'findings', 'rules_version', p_decision->>'rules_version'));
    return jsonb_build_object('outcome', 'case_opened', 'case_id', v_case);

  else
    raise exception 'Unknown decision status %', v_status;
  end if;
end $$;

-- Only the service role (n8n) may call these
revoke all on function receive_result(jsonb) from public, anon, authenticated;
revoke all on function record_decision(bigint, jsonb) from public, anon, authenticated;
grant execute on function receive_result(jsonb) to service_role;
grant execute on function record_decision(bigint, jsonb) to service_role;
