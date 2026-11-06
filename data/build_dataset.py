"""Build the CareLoop demo dataset.

Takes Synthea patient bundles and the benchmark test cases and produces:
  data/patients/<patient-id>.json  trimmed patient record (what the health information exchange holds)
  data/inbound/<case-id>.json      a screening result as it would arrive from the lab
  data/manifest.csv                which case went to which patient

Usage:
  python data/build_dataset.py <synthea fhir folder> benchmark/test-cases.csv

Same inputs always give the same output (fixed random seed).
"""
import csv
import glob
import json
import os
import random
import re
import sys
from datetime import date

SEED = 2026
TODAY = date(2026, 11, 6)
SCREEN_DATES = ["2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06"]
HERE = os.path.dirname(os.path.abspath(__file__))
LOCAL = "http://careloop.example/codes"
LOINC = "http://loinc.org"

# History we keep from Synthea: only the measures CareLoop screens on
KEEP_OBS = {"85354-9", "39156-5", "4548-4", "2339-0", "18262-6", "33914-3", "2160-0"}
AREAS = ["Khalifa City", "Mussafah", "Al Shamkha", "Al Bateen", "Al Reem Island", "Mohammed Bin Zayed City"]


def age_on(birth, on=TODAY):
    b = date.fromisoformat(birth)
    return on.year - b.year - ((on.month, on.day) < (b.month, b.day))


def clean_name(s):
    return re.sub(r"\d+", "", s)


def load_patients(folder):
    people = []
    for fn in sorted(glob.glob(os.path.join(folder, "*.json"))):
        base = os.path.basename(fn)
        if base.startswith(("hospitalInformation", "practitionerInformation")):
            continue
        bundle = json.load(open(fn, encoding="utf-8"))
        res = [e["resource"] for e in bundle["entry"]]
        pat = next(r for r in res if r["resourceType"] == "Patient")
        if "deceasedDateTime" in pat:
            continue
        a = age_on(pat["birthDate"])
        if not 18 <= a <= 75:
            continue
        people.append({"patient": pat, "resources": res, "age": a, "sex": "F" if pat["gender"] == "female" else "M"})
    return people


def trim(person, n, rng, providers, case):
    """Turn a Synthea record into a small Abu Dhabi-flavoured record."""
    p = person["patient"]
    pid = p["id"]
    name = p["name"][0]
    plan = rng.choice(providers["plans"])
    clinics = [c for c in providers["clinics"] if plan["network"] in c["networks"]]
    clinic = rng.choice(clinics)
    gp = rng.choice([d for d in providers["practitioners"] if d["clinic"] == clinic["id"]])

    patient = {
        "resourceType": "Patient",
        "id": pid,
        "identifier": [{"system": "http://careloop.example/mrn", "value": f"CL-{n:04d}"}],
        "name": [{"family": clean_name(name["family"]), "given": [clean_name(g) for g in name.get("given", [])[:1]]}],
        "gender": p["gender"],
        "birthDate": p["birthDate"],
        "address": [{"city": "Abu Dhabi", "district": rng.choice(AREAS), "country": "AE"}],
        "generalPractitioner": [{"reference": f"Practitioner/{gp['id']}", "display": gp["name"]}],
        "managingOrganization": {"reference": f"Organization/{clinic['id']}", "display": clinic["name"]},
    }
    if case is None or case["phone"] != "no":
        patient["telecom"] = [{"system": "phone", "value": f"+971 50 000 {n:04d}"},
                              {"system": "email", "value": f"patient{n:04d}@example.com"}]
    if case and case["case_id"] == "TC41":
        patient["birthDate"] = f"{TODAY.year - 76}-{p['birthDate'][5:]}"
        patient["meta"] = {"tag": [{"system": LOCAL, "code": "birthdate-overridden",
                                    "display": "Birth date changed to make this patient 76 for TC41"}]}

    coverage = {"resourceType": "Coverage", "id": f"cov-{pid[:8]}", "status": "active",
                "beneficiary": {"reference": f"Patient/{pid}"},
                "class": [{"type": {"text": "plan"}, "value": plan["id"], "name": plan["name"]},
                          {"type": {"text": "network"}, "value": plan["network"]}]}
    declined = case is not None and case["consent"] == "no"
    consent = {"resourceType": "Consent", "id": f"consent-{pid[:8]}",
               "status": "rejected" if declined else "active",
               "scope": {"text": "Contact about screening results"},
               "patient": {"reference": f"Patient/{pid}"},
               "provision": {"type": "deny" if declined else "permit"}}

    cutoff = f"{TODAY.year - 5}-{TODAY.month:02d}"
    history = []
    for r in person["resources"]:
        if r["resourceType"] == "Observation":
            codes = {c["code"] for c in r.get("code", {}).get("coding", [])}
            if codes & KEEP_OBS and r.get("effectiveDateTime", "") >= cutoff:
                history.append({k: r[k] for k in ("resourceType", "id", "status", "code", "subject",
                                                    "effectiveDateTime", "valueQuantity", "component") if k in r})
        elif r["resourceType"] == "Condition":
            disp = r.get("code", {}).get("text", "")
            active = r.get("clinicalStatus", {}).get("coding", [{}])[0].get("code") == "active"
            if active and "(disorder)" in disp:
                history.append({k: r[k] for k in ("resourceType", "id", "clinicalStatus", "code", "subject", "onsetDateTime") if k in r})

    entries = [patient, coverage, consent] + history
    return {"resourceType": "Bundle", "type": "collection", "id": f"record-{pid[:8]}",
            "entry": [{"resource": r} for r in entries]}, plan, clinic, gp


def obs(case_id, i, pid, when, code, display, system=LOINC, **value):
    o = {"resourceType": "Observation", "id": f"{case_id.lower()}-{i}", "status": "final",
         "category": [{"coding": [{"system": "http://terminology.hl7.org/CodeSystem/observation-category", "code": "laboratory"}]}],
         "code": {"coding": [{"system": system, "code": code, "display": display}], "text": display},
         "subject": {"reference": f"Patient/{pid}"}, "effectiveDateTime": when}
    o.update(value)
    return o


def qty(v, unit):
    q = {"value": float(v)}
    if unit:
        q.update({"unit": unit, "system": "http://unitsofmeasure.org", "code": unit})
    return q


def screening_bundle(case, pid, when, rng):
    cid, out, i = case["case_id"], [], 0

    def add(*a, **k):
        nonlocal i
        i += 1
        out.append(obs(cid, i, pid, when, *a, **k))

    if case["sbp"] or case["dbp"]:
        comps = [{"code": {"coding": [{"system": LOINC, "code": "8480-6", "display": "Systolic blood pressure"}]}, "valueQuantity": qty(case["sbp"], "mm[Hg]")},
                 {"code": {"coding": [{"system": LOINC, "code": "8462-4", "display": "Diastolic blood pressure"}]}, "valueQuantity": qty(case["dbp"], "mm[Hg]")}]
        rng.shuffle(comps)  # real feeds don't promise an order
        add("85354-9", "Blood pressure panel", component=comps)
    if case["case_id"] == "TC33":
        add("4548-4", "Hemoglobin A1c/Hemoglobin.total in Blood",
            dataAbsentReason={"coding": [{"system": "http://terminology.hl7.org/CodeSystem/data-absent-reason", "code": "unknown"}]})
    elif case["hba1c_pct"]:
        add("4548-4", "Hemoglobin A1c/Hemoglobin.total in Blood", valueQuantity=qty(case["hba1c_pct"], "%"))
    if case["glucose"]:
        fasting = case["glucose_kind"] == "fasting"
        unit = case["glucose_unit"]
        if unit == "mmol/L":
            code, disp = ("14771-0", "Fasting glucose [Moles/volume] in Serum or Plasma") if fasting else ("15074-8", "Glucose [Moles/volume] in Blood")
        else:
            code, disp = ("1558-6", "Fasting glucose [Mass/volume] in Serum or Plasma") if fasting else ("2339-0", "Glucose [Mass/volume] in Blood")
        add(code, disp, valueQuantity=qty(case["glucose"], unit))
    if case["bmi"]:
        add("39156-5", "Body mass index (BMI) [Ratio]", valueQuantity=qty(case["bmi"], "kg/m2"))
    if case["ldl_mmol"]:
        add("22748-8", "Cholesterol in LDL [Moles/volume] in Serum or Plasma", valueQuantity=qty(case["ldl_mmol"], "mmol/L"))
    if case["egfr"]:
        add("62238-1", "Glomerular filtration rate/1.73 sq M.predicted (CKD-EPI)", valueQuantity=qty(case["egfr"], "mL/min/{1.73_m2}"))
    # Codes below are local placeholders, to be mapped to LOINC/SNOMED in a pilot
    if case["fit"]:
        add("fit", "Faecal immunochemical test", system=LOCAL, valueCodeableConcept={"text": case["fit"]})
    if case["cervical"]:
        add("cervical-screen", "Cervical screening result", system=LOCAL, valueCodeableConcept={"text": case["cervical"]})
    if case["mammogram"]:
        add("mammogram-birads", "Screening mammogram BI-RADS category", system=LOCAL, valueCodeableConcept={"text": case["mammogram"]})

    return {"resourceType": "Bundle", "type": "collection", "id": f"inbound-{cid.lower()}",
            "meta": {"tag": [{"system": LOCAL, "code": cid, "display": "benchmark test case"}]},
            "timestamp": f"{when}T09:00:00+04:00",
            "entry": [{"resource": r} for r in out]}


def fits(case, person):
    """Hard requirements for which patient a case can go to."""
    if case["cervical"] and case["case_id"] != "TC42":
        return person["sex"] == "F" and 25 <= person["age"] <= 65
    if case["case_id"] == "TC42":
        return person["sex"] == "M"
    if case["mammogram"]:
        return person["sex"] == "F" and person["age"] >= 40
    if case["fit"]:
        return person["age"] >= 40
    return True


def main(fhir_dir, cases_path):
    rng = random.Random(SEED)
    providers = json.load(open(os.path.join(HERE, "mock", "providers.json")))
    people = load_patients(fhir_dir)
    cases = list(csv.DictReader(open(cases_path)))

    # Most constrained cases pick first so they aren't starved
    order = sorted(cases, key=lambda c: (sum(1 for p in people if fits(c, p)), c["case_id"]))
    used, assigned, short = set(), {}, []
    for c in order:
        if c["case_id"] == "TC37":
            continue  # deliberately points at a patient who doesn't exist
        pool = [p for p in people if p["patient"]["id"] not in used and fits(c, p)]
        if not pool:
            short.append(c["case_id"])
            continue
        pick = rng.choice(pool)
        used.add(pick["patient"]["id"])
        assigned[c["case_id"]] = pick

    for d in ("patients", "inbound"):
        os.makedirs(os.path.join(HERE, d), exist_ok=True)
    by_pid = {a["patient"]["id"]: cid for cid, a in assigned.items()}
    case_by_id = {c["case_id"]: c for c in cases}

    rows = []
    for n, person in enumerate(people, 1):
        pid = person["patient"]["id"]
        cid = by_pid.get(pid)
        record, plan, clinic, gp = trim(person, n, rng, providers, case_by_id.get(cid))
        json.dump(record, open(os.path.join(HERE, "patients", f"{pid}.json"), "w"), indent=1)
        if cid:
            rows.append([cid, pid, f"CL-{n:04d}", person["sex"], age_on(record["entry"][0]["resource"]["birthDate"]),
                         plan["id"], clinic["id"], gp["id"]])

    for c in cases:
        cid = c["case_id"]
        when = rng.choice(SCREEN_DATES)
        if cid == "TC37":
            pid = "00000000-0000-0000-0000-000000000000"
        elif cid in assigned:
            pid = assigned[cid]["patient"]["id"]
        else:
            continue
        b = screening_bundle(c, pid, when, rng)
        json.dump(b, open(os.path.join(HERE, "inbound", f"{cid}.json"), "w"), indent=1)
        if cid == "TC43":  # the same result sent twice
            json.dump(b, open(os.path.join(HERE, "inbound", f"{cid}-duplicate.json"), "w"), indent=1)
        if cid == "TC37":
            rows.append([cid, pid, "", "", "", "", "", ""])

    rows.sort()
    with open(os.path.join(HERE, "manifest.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["case_id", "patient_id", "mrn", "sex", "age", "plan", "clinic", "family_doctor"])
        w.writerows(rows)

    print(f"usable patients: {len(people)}")
    print(f"cases built: {len(rows)} of {len(cases)}")
    print(f"patients with no screening case (history only): {len(people) - len(assigned)}")
    if short:
        print(f"NOT ENOUGH PATIENTS for {len(short)} cases: {', '.join(sorted(short))}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
