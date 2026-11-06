# Flagging rules (draft v0.1, 3 Nov)

Status: draft. Every threshold and timeframe needs a clinician to check it before it's treated as final.

Rows marked **Guideline** take the number straight from the cited source. Rows marked **CareLoop default** are my own choice where the source gives no timeframe. These are the ones to question first in review.

## Priority levels

| Priority | Meaning | Target time to care | Route |
| --- | --- | --- | --- |
| P1 Urgent | Possible danger to the patient now | Same day | Care team calls the patient. Emergency advice if symptomatic. |
| P2 High | Needs a doctor soon | Per rule, usually 5 working days to 4 weeks | In-person referral to primary care doctor or specialist |
| P3 Moderate | Needs follow-up, not urgent | Within 3 months | Teleconsultation first |
| P4 Routine | Lifestyle advice or a repeat test | At recall or next screening | Message plus reminder to repeat |

If a patient has more than one abnormal result, the case takes the highest priority among them, and every abnormal result is listed on the case.

## Hard stops (no flag, goes to a data-check queue)

| Condition | Action |
| --- | --- |
| Value missing | Stop. Ask the lab or clinic to resend. |
| Unit missing or not recognised | Stop. Never guess the unit. |
| Value outside a plausible range (SBP under 60 or over 300, DBP under 30 or over 200, HbA1c under 3% or over 20%, glucose under 1 or over 50 mmol/L, BMI under 10 or over 90) | Stop. Treat as a likely entry error. |
| Patient record can't be matched | Stop. Don't create a case on the wrong person. |

Missing contact details do **not** stop a case. It continues and gets flagged for the care team to find another way to reach the patient.

## Blood pressure (mmHg)

| Result | Priority | Target | Basis | Source |
| --- | --- | --- | --- | --- |
| SBP 180 or higher, or DBP 120 or higher | P1 | Same day | Guideline | ACC/AHA 2017 definition of severe hypertension |
| SBP 140 to 179, or DBP 90 to 119 (stage 2) | P2 | Within 4 weeks | Guideline | 2025 AHA/ACC categories (unchanged from 2017). 2017 guideline advises evaluation within 1 month for stage 2. |
| SBP 130 to 139, or DBP 80 to 89 (stage 1) | P3 | Within 3 months | Guideline | 2025 AHA/ACC: lifestyle first, reassess at 3 to 6 months |
| SBP 120 to 129 and DBP under 80 (elevated) | P4 | Next screening | Guideline | 2025 AHA/ACC categories |

Note: the guideline says a diagnosis needs confirming with home or ambulatory readings. CareLoop flags on the screening reading and the referral asks for confirmation.

## Blood sugar

| Result | Priority | Target | Basis | Source |
| --- | --- | --- | --- | --- |
| Any glucose 16.7 mmol/L (300 mg/dL) or higher | P1 | Same day | CareLoop default | Common threshold for severe hyperglycaemia. Needs clinician sign-off. |
| HbA1c 6.5% or higher, or fasting glucose 7.0 mmol/L (126 mg/dL) or higher | P2 | Within 4 weeks | Guideline for threshold, CareLoop default for timing | ADA Standards of Care diagnostic criteria |
| HbA1c 5.7% to 6.4%, or fasting glucose 5.6 to 6.9 mmol/L | P3 | Within 3 months | Guideline for threshold, CareLoop default for timing | ADA prediabetes criteria |

## BMI (kg/m²)

| Result | Priority | Target | Basis | Source |
| --- | --- | --- | --- | --- |
| 30 or higher | P3 | Within 3 months | Guideline for threshold, CareLoop default for timing | WHO obesity classification |
| 25 to 29.9 | P4 | Next screening | Guideline | WHO overweight classification |

## Cholesterol

| Result | Priority | Target | Basis | Source |
| --- | --- | --- | --- | --- |
| LDL 4.9 mmol/L (190 mg/dL) or higher | P2 | Within 4 weeks | Guideline for threshold, CareLoop default for timing | ACC/AHA 2018 cholesterol guideline (severe primary hypercholesterolaemia) |

## Kidney function (eGFR from creatinine, mL/min/1.73m²)

| Result | Priority | Target | Basis | Source |
| --- | --- | --- | --- | --- |
| Under 15 | P1 | Same day | CareLoop default | KDIGO stage G5. Needs clinician sign-off. |
| 15 to 29 | P2 | Within 2 weeks | CareLoop default | KDIGO stage G4 |
| 30 to 59 | P3 | Repeat within 3 months | Guideline | KDIGO: CKD needs reduced eGFR for more than 3 months |

## Colorectal cancer

| Result | Priority | Target | Basis | Source |
| --- | --- | --- | --- | --- |
| FIT positive | P2 | Colonoscopy within 60 days. Escalate if not done by 6 months. | CareLoop default, backed by evidence | Corley et al., JAMA 2017: cancer risk rises when colonoscopy is delayed past 10 months. USMSTF benchmark is 80% colonoscopy completion after a positive FIT. |

## Cervical cancer

| Result | Priority | Target | Basis | Source |
| --- | --- | --- | --- | --- |
| Visible suspicious lesion | P1 | Immediate | Guideline | DoH Cervical Cancer Screening Standard 2025, s.3.7.6: refer to gynae-oncology without waiting for results |
| HPV positive | P2 | Colposcopy within 3 months | Guideline | DoH standard, Appendix 4 tracks colposcopy within 3 months (80% acceptable, 88% desirable) |
| Unsatisfactory sample | P4 | Repeat in 6 to 12 weeks | Guideline | DoH standard, s.3.7.4 |

Patient must be told the result in writing within 21 days of the sample (DoH standard, s.3.7.2). CareLoop tracks this as a separate deadline.

Gap: the standard says HPV-positive results follow Appendix 1, but Appendix 1 is empty in the published copy. Need a clinician to confirm the HPV 16/18 versus other-type pathway.

## Breast cancer

| Result | Priority | Target | Basis | Source |
| --- | --- | --- | --- | --- |
| Mammogram BI-RADS 0, 4 or 5 | P2 | Assessment within 5 working days | Guideline | DoH Breast Cancer Screening and Diagnosis Standard 2025, Appendix 3 |
| BI-RADS 3 | P4 | Repeat imaging in about 6 months | Guideline | DoH breast standard, Appendix 6 |
| Confirmed cancer | P1 | Treatment referral within 10 working days | Guideline | DoH breast standard, s.3.9.11 |

Results must reach the patient within 15 working days (DoH breast standard, s.3.7.1).

## Out of scope for the prototype

Lung cancer screening (Lung-RADS), full blood count, depression screening and the hearing and vision checks are part of the IFHAS packages, but they're left out to keep the build tight. Mention this in the limitations.

## Sources

- [DoH IFHAS 2025 claims adjudication addendum](https://www.doh.gov.ae/-/media/Feature/shafifya/Prices/Adjudication-Rules/Addendum-03-to-DOH-claims-Adjudication-Rules_IFHAS-2025-Update.ashx) (what IFHAS screens for, by age)
- [DoH Cervical Cancer Screening Standard 2025](https://www.doh.gov.ae/-/media/Feature/Resources/Standards/2025/for-publication_-Standard-Cervical-Cancer-Screening-Standard.ashx)
- [DoH Breast Cancer Screening and Diagnosis Standard 2025](https://www.doh.gov.ae/-/media/B930A7CCC00F43DCBA9410E2731C3239.ashx)
- [2025 ACC/AHA High Blood Pressure Guideline summary](https://www.2minutemedicine.com/guidelines/high-blood-pressure/)
- [ADA Standards of Care in Diabetes 2026](https://diabetes.org/newsroom/press-releases/american-diabetes-association-releases-standards-care-diabetes-2026)
- [Corley et al., JAMA 2017, on delay after positive FIT](https://cm.healio.com/news/gastroenterology/20170425/delaying-colonoscopy-after-positive-fit-linked-to-higher-crc-risk)
- [Follow-up colonoscopy after positive FIT, JABFM](https://www.jabfm.org/content/34/1/61.full)
- [NKF / KDIGO CKD staging card](https://www.kidney.org/sites/default/files/NKF-CKD-Card.pdf)
