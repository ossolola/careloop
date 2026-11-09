# Build log

Short notes on what got built and what broke, newest first.

| Date | What happened | Notes |
| --- | --- | --- |
| 7 Nov | Coordinator alert email working end to end. Sent an urgent test result (BP 192/118), workflow 3 picked it up and emailed the coordinator inbox. | Email gives the case number, reason and deadline, not the readings. Running it again doesn't send a second email. |
| 7 Nov | Added CareLoop 0, a small admin workflow for changing settings (coordinator email, demo mode, reminder timing). | Manual only, no webhook, so nobody outside n8n can change settings. |
| 7 Nov | Built workflow 3: follow-up and escalation. Reminders on day 3 and day 7, escalation on day 10, appointment reminder the day before, missed appointments escalate, urgent cases escalate if nobody acts by end of day. | 18 lifecycle checks passed locally. Added a demo clock so one day can pass in one minute for judges. |
| 7 Nov | Workflow 2 live: case 1 referred to Dr Aisha Demo at Clinic West, in network. Gemini drafted the message and it passed the checks. | Draft is waiting for doctor approval. Nothing goes to a patient without it. |
| 6 Nov | Built workflow 2: referral and patient message. Supabase picks the provider, code builds the facts, Gemini only rewords them. | Caught a mistake while testing: an unreadable cervical sample was told "no appointment needed". Fixed it to ask for a repeat test. |
| 6 Nov | Intake workflow live in n8n. Test result opened a case in Supabase (P2, BP 156/94 and HbA1c 7.4%). | Sent the same result again: ignored, no second case. First run failed because I left the function path off the Supabase URLs. Fixed. |
| 6 Nov | Flagging rules written into the n8n Code node. | 56 of 56 test cases pass, 15 of 15 urgent cases caught. |
| 6 Nov | Supabase set up and loaded: 70 patients, 4 clinics, 8 doctors, 3 plans, 7 services. | Europe region for the prototype. |
| 6 Nov | Generated 70 patients with Synthea, seed 2026, ages 18 to 75. Attached 56 screening cases. | First run with 40 patients wasn't enough for all the test cases. |
| 4 Nov | Flagging rules and test cases drafted. | Found 6 situations the rules don't cover yet. |
| 3 Nov | Repo set up, team CareLoop NG registered, practitioner messages sent. | |