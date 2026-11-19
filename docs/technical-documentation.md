# CareLoop technical documentation

Future Health Digital Innovation Challenge, Population Health track: Closing the Screening-to-Care Loop.
Team CareLoop NG (Oluwasijibomi Solola). Last updated 19 November 2026.

## 1. What it does

An abnormal screening result in primary care should end with the patient seen and the outcome written down. CareLoop follows each result until that happens.

1. A lab or screening site sends the result as a FHIR bundle. CareLoop matches it to the patient and checks that it makes sense.
2. Fixed clinical rules decide whether it is abnormal, how urgent it is (P1 to P4) and the deadline for care. No AI is involved in this step.
3. The patient is referred to their own family doctor, or to an in-network service for tests such as colonoscopy, colposcopy or breast assessment.
4. A plain-language message is drafted for the patient. The patient's family doctor reads it, can edit it, and approves it. Nothing reaches a patient without that approval.
5. The patient opens the app, sees the approved message and books a slot. If they don't book, reminders go out on day 3 and day 7. On day 10 the case goes to the screening coordinator, who calls the patient and books for them.
6. The doctor records whether the patient attended and what was found. That closes the loop.

## 2. Links

| What | Where |
|---|---|
| Patient app | https://ossolola.github.io/careloop/app/ |
| Care-team dashboard | https://ossolola.github.io/careloop/dashboard/ |
| Source code | https://github.com/ossolola/careloop |
| Privacy page | https://ossolola.github.io/careloop/privacy.html |

Demo sign-ins:

| Who | How to sign in |
|---|---|
| Patient Rashid Khaleef | Record number CL-0032, date of birth 29 August 1981 |
| Coordinator Layla Demo | Pick "Layla Demo" from the list, PIN 2026 |
| Family doctors Aisha, Noura, Yusuf, Khalid | Pick the doctor's name, PIN 2026 |

Every name, clinic, phone number and result in the demo is synthetic.

## 3. Architecture

```
 Lab / screening site
        │  FHIR bundle over HTTPS, header X-CareLoop-Key
        ▼
 ┌─────────────────────────── n8n (self-hosted, Docker) ───────────────────────────┐
 │ WF1 Intake        webhook → check and flag (rules in a Code node) → save case   │
 │ WF2 Referral      every minute → pick provider → build facts → Gemini rewords   │
 │                   → draft checker → save draft for doctor approval              │
 │ WF3 Follow-up     every minute → send approved messages, reminders,             │
 │                   escalations, coordinator alert emails (Gmail)                 │
 │ WF4 Patient app   webhook for the app (sign in, consent, book, ask for help)    │
 │ WF5 Dashboard     webhook for the care team (queues, approve, book, close)      │
 │ WF0 Settings      manual only (demo clock, coordinator email, reminder days)    │
 └───────────────────────────────────┬─────────────────────────────────────────────┘
                                     │  RPC calls with the service key
                                     ▼
                  Supabase Postgres: tables + plpgsql functions
          (patients, cases, findings, referrals, messages, audit log)

 Patient app and dashboard: static pages on GitHub Pages. They hold no keys and
 talk only to the WF4 and WF5 webhooks, which only accept calls from that site.
```

Design choices:

- The logic lives in the database. Referral choice, approvals, booking, reminders and escalation are Postgres functions. n8n schedules and connects them. A rule can be read and tested in one place, and the same function serves the workflow and the dashboard.
- Rules are code, not a model. The flagging rules are a plain JavaScript function (`workflows/flagging.js`) with a written source for every threshold in `rules/flagging-rules.md`.
- AI only rewords. Gemini gets a short list of facts (reading, doctor, clinic, deadline) and rewrites them in friendly language. The draft checker (`workflows/check_draft.js`) throws the wording away and uses a fixed template if any fact is missing, if it sounds like a diagnosis ("diabetes", "cancer", "you have a…"), or if it is too long. The call-998 safety line on urgent messages is always added by code, never left to the AI. If Gemini is down or rate-limited, the template is used and nothing stops.
- Every step is logged. The audit log is append-only (a trigger blocks edits and deletes). The dashboard timeline is read straight from it.

## 4. Data and dataset assumptions

- No real patient data. 70 adults aged 18 to 75 were generated with Synthea (seed 2026). Names are American because Synthea generates them that way. The demo patient was renamed Rashid Khaleef.
- Abu Dhabi details are made up: district, phone, insurance plan (three plans with different networks), family doctor, clinic. Four clinics, eight doctors and seven services sit in a mock directory, all marked "Demo".
- 56 screening test cases were written against the rules: blood pressure, glucose and HbA1c, BMI, LDL cholesterol, eGFR, FIT, cervical and mammogram results, plus bad data (missing units, impossible values, unmatched patients, a male record with a cervical result, a duplicate). The expected answer for each is in `benchmark/test-cases.csv`.
- Data is FHIR-shaped (Patient, Observation, Consent), so a later connection to Malaffi or Sahatna would map onto the same structure. Both are mocked in this prototype.
- Every patient is assumed to have insurance and a family doctor, as described for Abu Dhabi in the explainer session. Flagged cases go to that doctor first.
- Time rules: "5 working days" is coded as 7 calendar days. "Next screening" is coded as 3 years.

## 5. Clinical rules and boundaries

Thresholds come from ACC/AHA (blood pressure, cholesterol), ADA (glucose, HbA1c), WHO (BMI), KDIGO (kidney function) and the DoH Abu Dhabi 2025 cervical and breast screening standards. The full table with sources is in `rules/flagging-rules.md`.

| Priority | Meaning | Target | What CareLoop does |
|---|---|---|---|
| P1 | Possible danger now | Same day | Phone call from the care team, call-998 line in the message, coordinator alerted if nobody acts by end of day |
| P2 | Needs a doctor soon | Usually 1 to 4 weeks | In-person referral to the family doctor or an in-network service |
| P3 | Follow-up, not urgent | Within 3 months | Teleconsultation first |
| P4 | Advice or repeat test | Next screening | Advice message and a recall date. The case closes once the advice is sent |

What CareLoop will not do:

- It does not diagnose. Messages say "This is not a diagnosis. Your doctor will explain what the results mean for you."
- It does not guess. A missing value, a missing or unknown unit, an impossible reading, a record that can't be matched or a result that doesn't fit the patient goes to a data-check list. No case is opened.
- It does not send a result message without a family doctor's approval.
- It does not close a case that needed clinical follow-up unless a family doctor records the outcome. The coordinator can mark a case lost to follow-up, but cannot record a clinical outcome.
- It does not put readings, names or contact details in alert emails. The email carries a record number, clinic, priority, reason and deadline.

Six rules fill gaps in the guidelines and are my proposals, pending a clinician's review: diastolic equal to or above systolic (held as implausible), patients outside 18 to 75 (acted on, with a flag), cervical or mammogram results on a non-female record (held), duplicate results (ignored), random glucose 11.1 to 16.6 mmol/L (P2), and very low blood pressure (no rule yet).

## 6. Access and safety

- Doctors see only their own patients: the ones they are the family doctor for, or that were referred to them. The coordinator sees every case. This is checked inside the database function, not just hidden on the page.
- Row level security is on for every table and there are no public policies. The public Supabase keys cannot run any CareLoop function.
- The intake webhook needs a lab key. The app and dashboard webhooks only accept calls from the GitHub Pages site.
- The demo reset can only be run from the Supabase SQL editor.
- `db/safety_check.sql` runs 21 read-only checks covering access, patient safety and data integrity. Every check passes on the live database.
- If a coordinator alert email fails, for example because the Gmail sign-in expired, the follow-up workflow tries again every 15 minutes until it goes through, and the safety check flags any alert not delivered within 20 minutes.

## 7. Testing and results

`benchmark/send_benchmark.py` sends all 56 test results, plus one repeat, to the live intake workflow and scores the answers. Latest run, 16 November 2026:

| Check | Result |
|---|---|
| Cases decided correctly | 56 / 56 |
| Urgent (P1) cases caught | 15 / 15 |
| Bad or unmatched results held for a data check | 7 / 7 |
| Cases opened that should not have been | 0 |
| Guideline-gap cases decided as proposed | 6 / 6 |
| Repeat of the same result ignored | yes |
| Response time, median / slowest | 2.3 s / 3.3 s |

The full loop (result in, flagged, referred, doctor approves, patient books, attends, outcome recorded) was also run on the live system with practitioners testing the dashboard and app.

## 8. Demo clock

For judging, a setting can make one day pass in one minute. Reminders then arrive after 3 and 7 minutes and the coordinator takes over after 10. With it off, CareLoop uses real days. The current setting is shown by safety check 26.

## 9. Limitations

- Tested on synthetic data only. It has not been used on real patients or in a real clinic.
- Malaffi, Sahatna and insurer systems are mocked. A pilot needs real feeds, the insurer's live cover check and pre-approval.
- Some thresholds are proposals that need clinician sign-off (section 5). There is no rule for very low blood pressure.
- FIT, cervical and mammogram results use placeholder codes. A pilot would map them to proper LOINC or SNOMED codes.
- Lung cancer screening, full blood count, depression screening and hearing and vision checks are out of scope.
- Staff sign in with a shared demo PIN. A pilot would use the clinic's own staff sign-on.
- The prototype runs on one self-hosted n8n instance reached through ngrok, with Supabase in Europe. A pilot would run on managed hosting with data held in the UAE.
- Gemini runs on the free tier. Under load it hits rate limits and the template wording is used instead, which is safe but less friendly.
- Messages are sent in English only. Arabic is the obvious next step.

## 10. Path to a pilot

Run CareLoop in shadow mode for 12 weeks at one Abu Dhabi primary care centre with a screening coordinator, covering blood pressure, diabetes and cervical screening. It would follow real results alongside the current process without contacting patients, so its decisions and timings can be compared with what actually happened before anything goes live.

## 11. Repository map

| Folder | What is in it |
|---|---|
| `app/` | Patient app (single HTML page) |
| `dashboard/` | Care-team dashboard (single HTML page) |
| `db/` | Schema, all Postgres functions, demo reset, safety check |
| `workflows/` | Flagging rules, message facts and draft checker used inside n8n |
| `rules/` | Flagging rules with thresholds and sources |
| `data/` | Dataset builder, synthetic patients, test result bundles, mock directory |
| `benchmark/` | Test cases, local rule tests, live benchmark script and results |
| `docs/` | This document, the assumptions log and the build log |
