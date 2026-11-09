"""
Sends every benchmark test case to the live CareLoop intake (workflow 1) as if a lab had just
sent it, then scores what CareLoop decided against the expected answers in test-cases.csv.

Each result is re-dated to right now, so the cases it opens are live: same-day deadlines fall
today and the follow-up clock starts now. That also makes this the way to load fresh demo data.

Usage, from the repo root:
    python benchmark/send_benchmark.py            asks before sending
    python benchmark/send_benchmark.py --yes      sends without asking

Run  select demo_reset('RESET CARELOOP DEMO');  in Supabase first if you want a clean start.

Settings (optional) come from .env in the repo root:
    CARELOOP_RESULTS_URL   intake webhook, defaults to the ngrok address below
    CARELOOP_LAB_KEY       sent as the X-CareLoop-Key header if workflow 1 checks it

Writes benchmark/results/run-<date>-<time>.csv (one row per case) and a short summary .md.
"""
import csv
import json
import os
import statistics
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_URL = "https://nonreversing-hurly-clotilde.ngrok-free.dev/webhook/careloop/results"
ABU_DHABI = timezone(timedelta(hours=4))


def read_env():
    env = {}
    path = os.path.join(ROOT, ".env")
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def redate(bundle, now, run_tag):
    """Make the result look like it arrived just now, with an id that is new for this run."""
    b = json.loads(json.dumps(bundle))
    b["id"] = f"{bundle['id']}-{run_tag}"     # the duplicate copy of TC43 gets the same id, as it should
    b["timestamp"] = now.isoformat(timespec="seconds")
    for e in b.get("entry", []):
        r = e.get("resource", {})
        if "effectiveDateTime" in r:
            r["effectiveDateTime"] = now.date().isoformat()
        if "issued" in r:
            r["issued"] = now.isoformat(timespec="seconds")
    return b


def post(url, body, key, expect_duplicate=False):
    """Send one result. Retries if the connection drops before any reply (the free ngrok tunnel does this now and then)."""
    headers = {"Content-Type": "application/json", "ngrok-skip-browser-warning": "1",
               "User-Agent": "careloop-benchmark"}
    if key:
        headers["X-CareLoop-Key"] = key
    data = json.dumps(body).encode()
    start = time.perf_counter()
    for attempt in range(1, 4):
        req = urllib.request.Request(url, data=data, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=60) as res:
                text, status = res.read().decode(), res.status
            break
        except urllib.error.HTTPError as e:
            text, status = e.read().decode(errors="replace"), e.code
            break
        except (urllib.error.URLError, ConnectionError, TimeoutError, OSError) as e:
            if attempt == 3:
                return 0, {"raw": f"no reply after 3 tries ({e.__class__.__name__})"}, round((time.perf_counter() - start) * 1000)
            print(f"    connection dropped ({e.__class__.__name__}), trying again")
            time.sleep(2 * attempt)
    ms = round((time.perf_counter() - start) * 1000)
    try:
        reply = json.loads(text)
    except ValueError:
        return status, {"raw": text[:300]}, ms
    if attempt > 1 and reply.get("outcome") == "duplicate_ignored" and not expect_duplicate:
        reply = {"raw": "the first try was saved but its reply was lost, so this case could not be scored"}
    return status, reply, ms


def score(case, reply):
    """Same checks as benchmark/test_rules.js, applied to what the live system returned."""
    d = reply.get("decision") or {}
    got_status = d.get("status")
    exp_priority = None if case["expected_priority"] == "none" else case["expected_priority"]
    exp_triggers = sorted(t.strip() for t in case["expected_triggers"].split(";") if t.strip())
    got_triggers = sorted([d.get("stop_reason")] if got_status == "stopped"
                          else [f["rule_code"] for f in d.get("findings", [])])
    exp_contact = case["phone"] == "no" or case["consent"] == "no"
    errs = []
    if got_status != case["expected_status"]:
        errs.append(f"status {got_status}, expected {case['expected_status']}")
    if got_status != "stopped" and d.get("priority") != exp_priority:
        errs.append(f"priority {d.get('priority')}, expected {exp_priority}")
    if got_triggers != exp_triggers:
        errs.append(f"triggers {got_triggers}, expected {exp_triggers}")
    if got_status == "flagged" and bool(d.get("contact_flag")) != exp_contact:
        errs.append("contact flag wrong")
    # Safety: a stopped or unflagged result must never open a case
    if got_status in ("stopped", "no_flag") and reply.get("case_id"):
        errs.append("opened a case when it should not have")
    if got_status == "flagged" and not reply.get("case_id"):
        errs.append("flagged but no case was saved")
    return errs, got_status, d.get("priority"), got_triggers


def main():
    env = read_env()
    url = os.environ.get("CARELOOP_RESULTS_URL") or env.get("CARELOOP_RESULTS_URL") or DEFAULT_URL
    key = os.environ.get("CARELOOP_LAB_KEY") or env.get("CARELOOP_LAB_KEY")
    cases = list(csv.DictReader(open(os.path.join(ROOT, "benchmark", "test-cases.csv"), encoding="utf-8")))
    inbound = os.path.join(ROOT, "data", "inbound")
    missing = [c["case_id"] for c in cases if not os.path.exists(os.path.join(inbound, c["case_id"] + ".json"))]
    if missing:
        sys.exit(f"Missing result files for {', '.join(missing)}. Run data/build_dataset.py first.")

    print(f"Sending {len(cases)} test results (plus one repeat) to {url}")
    if "--yes" not in sys.argv:
        if input("This opens real cases in CareLoop. Continue? (y/n) ").strip().lower() != "y":
            sys.exit("Nothing sent.")

    now = datetime.now(ABU_DHABI)
    run_tag = now.strftime("%Y%m%d%H%M%S")
    rows, times, fails = [], [], []
    for c in cases:
        cid = c["case_id"]
        bundle = redate(json.load(open(os.path.join(inbound, cid + ".json"), encoding="utf-8")), now, run_tag)
        status, reply, ms = post(url, bundle, key)
        if status != 200 or "decision" not in reply:
            errs, got = [f"HTTP {status}: {json.dumps(reply)[:200]}"], (None, None, [])
        else:
            errs, *got = score(c, reply)
        times.append(ms)
        time.sleep(0.3)
        rows.append({"case_id": cid, "description": c["description"], "type": c["type"],
                     "expected_status": c["expected_status"], "got_status": got[0],
                     "expected_priority": c["expected_priority"], "got_priority": got[1] or "none",
                     "expected_triggers": c["expected_triggers"], "got_triggers": ";".join(t for t in got[2] if t),
                     "case_opened": reply.get("case_id") or "", "ms": ms,
                     "result": "pass" if not errs else "FAIL", "notes": "; ".join(errs)})
        print(f"  {cid}  {'pass' if not errs else 'FAIL'}  {ms} ms" + (f"   {'; '.join(errs)}" if errs else ""))
        if errs:
            fails.append(cid)

        if cid == "TC43":  # the lab sends the same result twice
            dup = redate(json.load(open(os.path.join(inbound, "TC43-duplicate.json"), encoding="utf-8")), now, run_tag)
            status, reply, ms = post(url, dup, key, expect_duplicate=True)
            ok = status == 200 and reply.get("outcome") == "duplicate_ignored"
            rows.append({"case_id": "TC43-repeat", "description": "Same result sent a second time",
                         "type": "hard", "expected_status": "duplicate_ignored", "got_status": reply.get("outcome"),
                         "expected_priority": "", "got_priority": "", "expected_triggers": "", "got_triggers": "",
                         "case_opened": "", "ms": ms, "result": "pass" if ok else "FAIL",
                         "notes": "" if ok else json.dumps(reply)[:200]})
            print(f"  TC43 repeat  {'ignored, pass' if ok else 'FAIL'}  {ms} ms")
            if not ok:
                fails.append("TC43-repeat")

    scored = [r for r in rows if r["case_id"] != "TC43-repeat"]
    passed = sum(r["result"] == "pass" for r in scored)
    p1 = [r for r in scored if r["expected_priority"] == "P1"]
    p1_caught = sum(r["got_priority"] == "P1" for r in p1)
    stops = [r for r in scored if r["expected_status"] == "stopped"]
    stops_held = sum(r["got_status"] == "stopped" and not r["case_opened"] for r in stops)
    unsafe = sum("opened a case when it should not have" in r["notes"] for r in scored)
    gaps = [r for r in scored if c_type(cases, r["case_id"]) == "gap"]
    dup_ok = any(r["case_id"] == "TC43-repeat" and r["result"] == "pass" for r in rows)

    os.makedirs(os.path.join(ROOT, "benchmark", "results"), exist_ok=True)
    base = os.path.join(ROOT, "benchmark", "results", f"run-{now.strftime('%Y-%m-%d-%H%M')}")
    with open(base + ".csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)

    summary = [
        f"# CareLoop benchmark run, {now.strftime('%d %b %Y %H:%M')} Abu Dhabi time",
        "",
        f"Sent to: `{url}`",
        "",
        "| Check | Result |",
        "|---|---|",
        f"| Cases decided correctly | {passed} / {len(scored)} |",
        f"| Urgent (P1) cases caught | {p1_caught} / {len(p1)} |",
        f"| Bad or unmatched results held for a data check (no case opened) | {stops_held} / {len(stops)} |",
        f"| Cases opened when they should not have been | {unsafe} |",
        f"| Cases covering gaps in the guidelines decided as proposed | {sum(r['result'] == 'pass' for r in gaps)} / {len(gaps)} |",
        f"| Repeat of the same result ignored | {'yes' if dup_ok else 'no'} |",
        f"| Response time, median / slowest | {round(statistics.median(times))} ms / {max(times)} ms |",
        "",
        "Every result was re-dated to the time of the run and sent through the live intake workflow,",
        "so this tests the deployed system, not a copy of the rules.",
    ]
    if fails:
        summary += ["", "Failed: " + ", ".join(fails), "Details are in the CSV."]
    open(base + ".md", "w", encoding="utf-8").write("\n".join(summary) + "\n")

    print()
    print("\n".join(summary[4:13]))
    print(f"\nSaved {os.path.relpath(base + '.csv', ROOT)} and {os.path.relpath(base + '.md', ROOT)}")
    sys.exit(1 if fails else 0)


def c_type(cases, cid):
    return next((c.get("rule_status") for c in cases if c["case_id"] == cid), None)


if __name__ == "__main__":
    main()