-- CareLoop referral functions, called by workflow 2.
-- Run in the Supabase SQL editor. Safe to re-run; does not touch data.
--
-- prepare_referrals   picks up new cases, chooses an in-network doctor or service for each,
--                     creates the referrals and returns what the message step needs (no names, no IDs)
-- save_message_draft  stores a drafted patient message, waiting for the doctor's approval

create or replace function prepare_referrals(p_limit int default 20)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  c        record;
  v_net    text;
  v_part   text;
  v_type   text;
  v_svc    services%rowtype;
  v_refs   jsonb;
  v_out    jsonb := '[]'::jsonb;
  v_gp     practitioners%rowtype;
  v_clinic clinics%rowtype;
  v_in_net boolean;
begin
  for c in
    select cs.*, p.gender, p.birth_date, p.plan_id, p.gp_id, p.clinic_id, p.consent_status, p.phone
      from cases cs join patients p on p.id = cs.patient_id
     where cs.status = 'new'
     order by cs.priority, cs.due_at
     limit p_limit
       for update of cs skip locked
  loop
    select network into v_net from plans where id = c.plan_id;
    select * into v_gp from practitioners where id = c.gp_id;
    select * into v_clinic from clinics where id = c.clinic_id;
    v_refs := '[]'::jsonb;

    foreach v_part in array string_to_array(c.route, '+') loop
      if v_part in ('same_day_call', 'in_person_family_doctor') then
        v_in_net := v_net = any(v_clinic.networks);
        insert into referrals (case_id, practitioner_id, mode, in_network, reason)
        values (c.id, v_gp.id,
                case when v_part = 'same_day_call' then 'phone' else 'in-person' end,
                v_in_net,
                case when v_in_net then 'Patient''s own family doctor'
                     else 'Patient''s own family doctor, outside their plan network: coordinator to check cover' end);
        v_refs := v_refs || jsonb_build_object('to', v_gp.name, 'place', v_clinic.name,
                    'mode', case when v_part = 'same_day_call' then 'phone' else 'in-person' end, 'in_network', v_in_net);

      elsif v_part = 'message_recall' then
        null;  -- P4: advice and a recall date, no referral

      else
        v_type := case v_part
                    when 'teleconsult'        then 'teleconsult'
                    when 'colonoscopy'        then 'colonoscopy'
                    when 'colposcopy'         then 'colposcopy'
                    when 'breast_assessment'  then 'breast-assessment'
                    when 'gynae_oncology_now' then 'gynae-oncology'
                  end;
        if v_type is null then
          raise exception 'Unknown route part % on case %', v_part, c.id;
        end if;
        select * into v_svc from services where type = v_type and v_net = any(networks) order by id limit 1;
        v_in_net := found;
        if not found then
          select * into v_svc from services where type = v_type order by id limit 1;
        end if;
        insert into referrals (case_id, service_id, mode, in_network, reason)
        values (c.id, v_svc.id,
                case when v_type = 'teleconsult' then 'teleconsult' else 'in-person' end,
                v_in_net,
                case when v_in_net then 'In-network ' || v_type
                     else 'No in-network ' || v_type || ' service: coordinator to check cover' end);
        v_refs := v_refs || jsonb_build_object('to', v_svc.name, 'place', v_svc.name,
                    'mode', case when v_type = 'teleconsult' then 'teleconsult' else 'in-person' end, 'in_network', v_in_net);
      end if;
    end loop;

    update cases set status = 'referred' where id = c.id;

    insert into audit_log (actor, action, case_id, detail)
    values ('workflow:referral', 'referral.created', c.id, jsonb_build_object('referrals', v_refs));

    v_out := v_out || jsonb_build_object(
      'case_id', c.id,
      'priority', c.priority,
      'route', c.route,
      'due_at', c.due_at,
      'contact_flag', c.contact_flag,
      'channel', case when c.consent_status = 'rejected' then 'internal' else 'app' end,
      'sex', c.gender,
      'age', date_part('year', age(c.birth_date))::int,
      'findings', (select jsonb_agg(jsonb_build_object('rule_code', f.rule_code, 'priority', f.priority, 'value', f.value_text)
                                    order by f.priority)
                     from case_findings f where f.case_id = c.id),
      'referrals', v_refs,
      'family_doctor', v_gp.name,
      'clinic', v_clinic.name
    );
  end loop;

  return v_out;
end $$;


create or replace function save_message_draft(p_case_id bigint, p_body text, p_drafted_by text,
                                              p_channel text, p_kind text default 'result',
                                              p_check_notes text default null)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_id bigint;
begin
  if p_drafted_by not in ('gemini', 'template') then
    raise exception 'drafted_by must be gemini or template';
  end if;
  insert into messages (case_id, kind, channel, body, drafted_by, status)
  values (p_case_id, p_kind, p_channel, p_body, p_drafted_by, 'draft')
  returning id into v_id;

  insert into audit_log (actor, action, case_id, detail)
  values ('workflow:referral', 'message.drafted', p_case_id,
          jsonb_build_object('message_id', v_id, 'drafted_by', p_drafted_by, 'channel', p_channel,
                             'check_notes', p_check_notes));
  return jsonb_build_object('message_id', v_id, 'case_id', p_case_id, 'status', 'draft');
end $$;

revoke all on function prepare_referrals(int) from public, anon, authenticated;
revoke all on function save_message_draft(bigint, text, text, text, text, text) from public, anon, authenticated;
grant execute on function prepare_referrals(int) to service_role;
grant execute on function save_message_draft(bigint, text, text, text, text, text) to service_role;
