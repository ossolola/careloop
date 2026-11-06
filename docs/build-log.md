# Build log

Short notes on what got built and what broke, newest first.

| Date | What happened | Notes |
| --- | --- | --- |
| 6 Nov | Intake workflow live in n8n. Test result opened a case in Supabase (P2, BP 156/94 and HbA1c 7.4%). | Sent the same result again: ignored, no second case. First run failed because I left the function path off the Supabase URLs. Fixed. |
| 6 Nov | Flagging rules written into the n8n Code node. | 56 of 56 test cases pass, 15 of 15 urgent cases caught. |
| 6 Nov | Supabase set up and loaded: 70 patients, 4 clinics, 8 doctors, 3 plans, 7 services. | Europe region for the prototype. |
| 6 Nov | Generated 70 patients with Synthea, seed 2026, ages 18 to 75. Attached 56 screening cases. | First run with 40 patients wasn't enough for all the test cases. |
| 4 Nov | Flagging rules and test cases drafted. | Found 6 situations the rules don't cover yet. |
| 3 Nov | Repo set up, team CareLoop NG registered, practitioner messages sent. | |
