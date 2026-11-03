# Assumptions log

Notes on what I'm assuming as I build. Will tidy this into the final assumptions and limitations section before submission.

## Assumptions

3 Nov
- Using synthetic patient data. No test data was provided and I can't use real patient records. The organisers said synthetic is fine.
- Adults 18 to 75 only. That's the age range given for this challenge.
- Every patient has insurance with a provider network. This was said for Abu Dhabi during the explainer session.
- Every patient has a primary care doctor, and flagged cases go back to them first.
- Malaffi and Sahatna are mocked for now. I don't have access to them. The data follows FHIR so a real connection later should be manageable.
- Abnormal results are flagged with fixed rules, not AI. Gemini only writes the messages patients read. I want the flagging to be something a doctor can check line by line.

## Dependencies

- n8n (self-hosted). Needs to be reachable online so the judges can test it.
- Supabase, free tier.
- Gemini API. If it's down, messages fall back to fixed templates.

## Limitations

- Not tested on real patients or in a real clinic. Any test results only show the logic works on synthetic cases.

## Still to figure out

- Who on the care team actually handles follow-up day to day? Need to look into this and ask the practitioners during review.
- Submission format (hosting, source code, login). Waiting on Hack2Skill to post it. Check before 11 Nov.