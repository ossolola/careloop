# CareLoop

Entry for the Future Health Digital Innovation Challenge, Population Health track: Closing the Screening-to-Care Loop.

## The problem

A person gets an abnormal screening result and then the follow-up falls through. They aren't told in time, the referral is never completed, or nobody clearly owns the next step because care is split across facilities.

## What CareLoop does

We help primary care teams make sure every abnormal screening result ends in completed care, using screening results and patient records from the health information exchange, plus each patient's insurance network.

1. A screening result comes in and is linked to the person's record.
2. Fixed clinical rules flag abnormal results and set a priority and a target time-to-care. The AI does not make this decision.
3. The patient is referred to the right service, matched to their insurance network and defaulting to their primary care doctor. Moderate, non-emergency cases go to a teleconsultation first.
4. Reminders go out until the patient books and attends. If they don't respond, the case is escalated to a care navigator.
5. The care team sees every open case, what has happened on it, and who is at risk of being lost to follow-up. The loop counts as closed when the clinical outcome is recorded.

## Stack

- n8n (self-hosted) for the workflows
- Supabase (Postgres) for data
- Gemini for patient-facing language only, working on de-identified data
- Mobile web app for patients
- Web dashboard for the care team
- FHIR-shaped data so it can connect to systems like Malaffi and Sahatna

## Data

All patient data in this repo is synthetic. No real patient information is used anywhere.

## Status

Build in progress. Submission due 20 November 2026.