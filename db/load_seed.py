"""Load providers and patients into Supabase.

Needs two settings, either as environment variables or in a .env file in the repo root:
  SUPABASE_URL=https://<your-project>.supabase.co
  SUPABASE_SERVICE_ROLE_KEY=<service role key>

Usage (from the repo root):
  python db/load_seed.py

Safe to re-run: existing rows are updated, not duplicated.
Inbound screening results are NOT loaded here. They arrive through the n8n workflow.
"""
import glob
import json
import os
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def settings():
    env = dict(os.environ)
    path = os.path.join(ROOT, ".env")
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env.setdefault(k.strip(), v.strip().strip('"').strip("'"))
    url, key = env.get("SUPABASE_URL"), env.get("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key:
        sys.exit("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY (in .env or as environment variables).")
    return url.rstrip("/"), key


def upsert(url, key, table, rows, batch=50):
    for i in range(0, len(rows), batch):
        req = urllib.request.Request(
            f"{url}/rest/v1/{table}",
            data=json.dumps(rows[i:i + batch]).encode(),
            method="POST",
            headers={
                "apikey": key,
                # Legacy service_role keys are JWTs and also go in Authorization. New sb_secret_ keys don't.
                **({"Authorization": f"Bearer {key}"} if key.startswith("eyJ") else {}),
                "Content-Type": "application/json",
                "Prefer": "resolution=merge-duplicates,return=minimal",
            },
        )
        try:
            urllib.request.urlopen(req)
        except urllib.error.HTTPError as e:
            sys.exit(f"{table}: {e.code} {e.read().decode()}")
    print(f"{table}: {len(rows)} rows")


def patient_row(bundle):
    res = [e["resource"] for e in bundle["entry"]]
    p = next(r for r in res if r["resourceType"] == "Patient")
    cov = next(r for r in res if r["resourceType"] == "Coverage")
    con = next(r for r in res if r["resourceType"] == "Consent")
    tel = {t["system"]: t["value"] for t in p.get("telecom", [])}
    name = p["name"][0]
    return {
        "id": p["id"],
        "mrn": p["identifier"][0]["value"],
        "given_name": (name.get("given") or [""])[0],
        "family_name": name.get("family"),
        "gender": p["gender"],
        "birth_date": p["birthDate"],
        "district": p["address"][0].get("district"),
        "phone": tel.get("phone"),
        "email": tel.get("email"),
        "plan_id": next(c["value"] for c in cov["class"] if c["type"]["text"] == "plan"),
        "clinic_id": p["managingOrganization"]["reference"].split("/")[1],
        "gp_id": p["generalPractitioner"][0]["reference"].split("/")[1],
        "consent_status": con["status"],
        "fhir": bundle,
    }


def main():
    url, key = settings()
    prov = json.load(open(os.path.join(ROOT, "data", "mock", "providers.json"), encoding="utf-8"))
    upsert(url, key, "plans", prov["plans"])
    upsert(url, key, "clinics", [{"id": c["id"], "name": c["name"], "area": c["area"], "networks": c["networks"]} for c in prov["clinics"]])
    upsert(url, key, "practitioners", [{"id": d["id"], "name": d["name"], "role": d["role"], "clinic_id": d["clinic"]} for d in prov["practitioners"]])
    upsert(url, key, "services", prov["services"])

    files = sorted(glob.glob(os.path.join(ROOT, "data", "patients", "*.json")))
    if not files:
        sys.exit("No files in data/patients. Run data/build_dataset.py first.")
    upsert(url, key, "patients", [patient_row(json.load(open(f, encoding="utf-8"))) for f in files], batch=20)
    print("Done.")


if __name__ == "__main__":
    main()
