# CareLoop

Entry for the Future Health Digital Innovation Challenge, Population Health track: Closing the Screening-to-Care Loop.

CareLoop follows every abnormal screening result in primary care until the patient has been seen and the outcome recorded.

- Patient app: https://ossolola.github.io/careloop/app/ (record CL-0032, born 29 August 1981)
- Care-team dashboard: https://ossolola.github.io/careloop/dashboard/ (any name, PIN 2026)
- Technical documentation: [docs/technical-documentation.md](docs/technical-documentation.md)

## The problem

A person gets an abnormal screening result and then the follow-up falls through. They aren't told in time, the referral never happens, or nobody clearly owns the next step because care is split across facilities.

## How it works

1. A screening result comes in as a FHIR bundle and is matched to the patient.
2. Fixed clinical rules flag it and set a priority (P1 to P4) and a deadline. AI plays no part in that decision.
3. The patient is referred to their own family doctor, or to an in-network service for further tests.
4. Gemini rewords a plain-language message from fixed facts. A checker rejects anything that sounds like a diagnosis or drops a fact, and the family doctor approves every message before it is sent.
5. The patient books in the app. Reminders go out on day 3 and day 7, and on day 10 the screening coordinator takes over.
6. The family doctor records the outcome, which closes the loop.

On the live system: 56 of 56 test results decided correctly, all 15 urgent results caught, and none of the 7 bad results opened a case.

## Stack

- n8n (self-hosted) for the workflows
- Supabase Postgres for the data and the core logic, written as database functions
- Gemini for rewording patient messages, with a fixed template as fallback
- Static patient app and dashboard on GitHub Pages
- FHIR-shaped data, so it can later connect to systems like Malaffi and Sahatna

## Data

All patient data in this repo is synthetic (Synthea, plus a made-up Abu Dhabi directory). No real patient information is used anywhere.
