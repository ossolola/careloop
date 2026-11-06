-- CareLoop database schema (Supabase / Postgres)
-- Run in the Supabase SQL editor. Safe to re-run: it drops and recreates every CareLoop table,
-- which also deletes their data. Re-run db/load_seed.py afterwards.

drop view if exists open_cases;
drop table if exists audit_log, messages, referrals, case_findings, cases, inbound_results,
  patients, services, practitioners, clinics, plans cascade;
drop function if exists block_audit_changes() cascade;
drop function if exists touch_updated_at() cascade;
drop type if exists priority, case_status, inbound_status cascade;

-- ---------- Types ----------

create type priority as enum ('P1', 'P2', 'P3', 'P4');

create type case_status as enum (
  'new',          -- flagged, nothing sent yet
  'referred',     -- referral created, waiting for doctor to approve the message
  'notified',     -- patient has been told
  'booked',       -- appointment booked
  'attended',     -- patient seen, outcome not yet recorded
  'escalated',    -- no response, with the coordinator
  'closed',       -- outcome recorded: loop closed
  'lost'          -- coordinator could not reach the patient
);

create type inbound_status as enum ('received', 'processed', 'stopped', 'duplicate');

-- ---------- Reference data (from data/mock/providers.json) ----------

create table plans (
  id        text primary key,
  name      text not null,
  network   text not null
);

create table clinics (
  id        text primary key,
  name      text not null,
  area      text,
  networks  text[] not null
);

create table practitioners (
  id        text primary key,
  name      text not null,
  role      text not null,
  clinic_id text references clinics(id)
);

create table services (
  id        text primary key,
  name      text not null,
  type      text not null,      -- teleconsult, colonoscopy, colposcopy, gynae-oncology, breast-assessment
  networks  text[] not null
);

-- ---------- Patients (from data/patients/*.json) ----------

create table patients (
  id             uuid primary key,
  mrn            text unique not null,
  given_name     text,
  family_name    text,
  gender         text,
  birth_date     date not null,
  district       text,
  phone          text,              -- null = no phone on file
  email          text,
  plan_id        text references plans(id),
  clinic_id      text references clinics(id),
  gp_id          text references practitioners(id),
  consent_status text not null default 'active',   -- 'active' or 'rejected'
  fhir           jsonb not null,                   -- the full trimmed FHIR bundle
  created_at     timestamptz not null default now()
);

-- ---------- Inbound screening results ----------

create table inbound_results (
  id            bigint generated always as identity primary key,
  message_id    text unique not null,      -- bundle id from the lab; unique stops duplicates
  patient_ref   text,                       -- as sent by the lab, may not match anyone
  patient_id    uuid references patients(id),
  received_at   timestamptz not null default now(),
  status        inbound_status not null default 'received',
  stop_reason   text,                       -- MISSING_VALUE, MISSING_UNIT, IMPLAUSIBLE, NO_MATCH, INCONSISTENT
  test_case_id  text,                       -- benchmark tag, null for real traffic
  bundle        jsonb not null
);

-- ---------- Cases: one per abnormal screening ----------

create table cases (
  id             bigint generated always as identity primary key,
  patient_id     uuid not null references patients(id),
  inbound_id     bigint not null unique references inbound_results(id),
  priority       priority not null,
  status         case_status not null default 'new',
  route          text not null,             -- same-day call, in-person, teleconsult, message + recall, ...
  due_at         timestamptz not null,      -- earliest deadline across all findings
  contact_flag   boolean not null default false,   -- missing phone or consent declined
  outcome        text,                      -- what the doctor recorded
  outcome_by     text references practitioners(id),
  opened_at      timestamptz not null default now(),
  closed_at      timestamptz,
  updated_at     timestamptz not null default now(),
  test_case_id   text,
  constraint closed_needs_outcome check (status <> 'closed' or outcome is not null)
);

-- Every abnormal result on a case, so nothing is hidden behind the top priority
create table case_findings (
  id          bigint generated always as identity primary key,
  case_id     bigint not null references cases(id) on delete cascade,
  rule_code   text not null,                -- e.g. BP_STAGE2, A1C_DIABETES
  priority    priority not null,
  value_text  text not null,                -- as shown to the care team, e.g. '156/94 mmHg'
  target_days integer                       -- null = next screening
);

create table referrals (
  id              bigint generated always as identity primary key,
  case_id         bigint not null references cases(id) on delete cascade,
  practitioner_id text references practitioners(id),
  service_id      text references services(id),
  mode            text not null,            -- in-person, teleconsult, phone
  in_network      boolean not null,
  reason          text,                     -- why this provider was picked
  status          text not null default 'pending',   -- pending, booked, attended, no-show, cancelled
  appointment_at  timestamptz,
  created_at      timestamptz not null default now(),
  constraint one_target check ((practitioner_id is null) <> (service_id is null))
);

-- Everything sent to (or queued for) a patient, including reminders
create table messages (
  id             bigint generated always as identity primary key,
  case_id        bigint not null references cases(id) on delete cascade,
  kind           text not null,             -- result, reminder, appointment, escalation-note
  channel        text not null,             -- app, email, sms
  body           text not null,
  drafted_by     text not null,             -- gemini or template
  approved_by    text references practitioners(id),
  approved_at    timestamptz,
  scheduled_for  timestamptz,
  sent_at        timestamptz,
  status         text not null default 'draft',   -- draft, approved, sent, failed, cancelled
  constraint sent_needs_approval check (sent_at is null or approved_at is not null or drafted_by = 'template')
);

-- ---------- Audit log: append-only ----------

create table audit_log (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  actor      text not null,                 -- 'system', 'workflow:flagging', or a practitioner id
  action     text not null,                 -- e.g. result.received, case.opened, message.approved
  case_id    bigint references cases(id),
  inbound_id bigint references inbound_results(id),
  detail     jsonb not null default '{}'
);

create function block_audit_changes() returns trigger language plpgsql as $$
begin
  raise exception 'audit_log is append-only';
end $$;

create trigger audit_log_no_update before update or delete on audit_log
  for each row execute function block_audit_changes();

create function touch_updated_at() returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger cases_touch before update on cases
  for each row execute function touch_updated_at();

-- ---------- Indexes ----------

create index on cases (status, priority, due_at);
create index on case_findings (case_id);
create index on referrals (case_id);
create index on messages (case_id);
create index on messages (status, scheduled_for);
create index on audit_log (case_id, at);
create index on inbound_results (status);

-- ---------- Dashboard view ----------

create view open_cases as
select
  c.id,
  c.priority,
  c.status,
  c.route,
  c.due_at,
  c.due_at < now() as overdue,
  c.contact_flag,
  c.opened_at,
  p.mrn,
  p.given_name || ' ' || p.family_name as patient_name,
  date_part('year', age(p.birth_date))::int as age,
  p.gender,
  pr.name as family_doctor,
  cl.name as clinic,
  (select string_agg(f.rule_code, ', ' order by f.priority) from case_findings f where f.case_id = c.id) as findings
from cases c
join patients p on p.id = c.patient_id
left join practitioners pr on pr.id = p.gp_id
left join clinics cl on cl.id = p.clinic_id
where c.status not in ('closed', 'lost');

-- ---------- Access ----------
-- Row level security on, no policies yet: only the service role (n8n, the loader) can read or write.
-- Policies for the dashboard and patient app get added when those are built.

alter table plans           enable row level security;
alter table clinics         enable row level security;
alter table practitioners   enable row level security;
alter table services        enable row level security;
alter table patients        enable row level security;
alter table inbound_results enable row level security;
alter table cases           enable row level security;
alter table case_findings   enable row level security;
alter table referrals       enable row level security;
alter table messages        enable row level security;
alter table audit_log       enable row level security;
