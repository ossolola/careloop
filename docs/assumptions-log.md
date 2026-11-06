# Assumptions log

Notes on what I'm assuming as I build. Will tidy this into the final assumptions and limitations section before submission.

## Assumptions

- Using synthetic patient data. No test data was provided and I can't use real patient records. The organisers said synthetic is fine.
- Patients come from Synthea (seed 2026), so names are American. Everything else (district, phone, insurance plan, family doctor, clinic) is made up for Abu Dhabi.
- Adults 18 to 75 only. That's the age range given for this challenge.
- Every patient has insurance with a provider network. This was said for Abu Dhabi during the explainer session.
- Every patient has a primary care doctor, and flagged cases go back to them first.
- Malaffi and Sahatna are mocked for now. I don't have access to them. The data follows FHIR so a real connection later should be manageable.
- Abnormal results are flagged with fixed rules, not AI. Gemini only writes the messages patients read. I want the flagging to be something a doctor can check line by line.
- Thresholds come from ADA, AHA/ACC, WHO and KDIGO, plus the DoH 2025 cervical and breast screening standards. I couldn't find Abu Dhabi's own numbers for BP, sugar, BMI, cholesterol or kidney function.
- "5 working days" is coded as 7 calendar days. "Next screening" is coded as 3 years.

## Dependencies

- n8n (self-hosted in Docker). Needs to be reachable online so the judges can test it. Right now that's through ngrok.
- Supabase, free tier, Europe region. A real pilot would host the data in the UAE.
- Gemini API. If it's down, messages fall back to fixed templates.
- Synthea, for generating the test patients.

## Limitations

- Not tested on real patients or in a real clinic. Test results only show the logic works on synthetic cases.
- Some rules are my proposals and still need a doctor to confirm them: diastolic higher than systolic, patients over 75, cervical or mammogram results on a male record, and random glucose between 11.1 and 16.6.
- There's no rule for very low blood pressure yet.
- FIT, cervical and mammogram results use placeholder codes. A pilot would map them to proper LOINC or SNOMED codes.
- Lung cancer screening, full blood count, depression screening and the hearing and vision checks are left out to keep the build tight.

## Still to figure out

- Who on the care team handles follow-up day to day? The DoH cancer screening standards point to a facility screening programme coordinator. Confirm with the practitioners on 14 or 15 Nov.
- HPV-positive pathway. The DoH cervical standard points to an Appendix 1 that's empty in the published copy. Ask a clinician.
- Submission format (hosting, source code, login). Waiting on Hack2Skill to post it. Check before 11 Nov.
- Judges need a stable link. The ngrok address changes when it restarts, so sort out a fixed URL before submitting.
