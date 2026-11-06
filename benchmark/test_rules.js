// Runs every benchmark test case through the flagging rules and scores them.
// Usage from the repo root:  node benchmark/test_rules.js
const path = require('path');
const { evaluate, RULES_VERSION } = require(path.join(__dirname, '..', 'workflows', 'flagging.js'));
const fixtures = require(path.join(__dirname, 'rules-fixtures.json'));

let pass = 0;
const failures = [];
for (const { case: c, bundle, patient } of fixtures) {
  const d = evaluate(bundle, patient);
  const expPriority = c.expected_priority === 'none' ? null : c.expected_priority;
  const expTriggers = (c.expected_triggers ? c.expected_triggers.split(';').map(s => s.trim()) : []).sort().join();
  const gotTriggers = (d.status === 'stopped' ? [d.stop_reason] : d.findings.map(f => f.rule_code)).sort().join();
  const expContact = c.phone === 'no' || c.consent === 'no';
  const errs = [];
  if (d.status !== c.expected_status) errs.push(`status ${d.status}, expected ${c.expected_status}`);
  if (d.status !== 'stopped' && d.priority !== expPriority) errs.push(`priority ${d.priority}, expected ${expPriority}`);
  if (gotTriggers !== expTriggers) errs.push(`triggers [${gotTriggers}], expected [${expTriggers}]`);
  if (d.status === 'flagged' && d.contact_flag !== expContact) errs.push('contact flag wrong');
  if (errs.length) failures.push(`${c.case_id} ${c.description}: ${errs.join('; ')}`); else pass++;
}
const urgent = fixtures.filter(f => f.case.expected_priority === 'P1');
const caught = urgent.filter(f => evaluate(f.bundle, f.patient).priority === 'P1').length;

console.log(`Rules ${RULES_VERSION}`);
console.log(`Cases passed: ${pass} / ${fixtures.length}`);
console.log(`Urgent (P1) cases caught: ${caught} / ${urgent.length}`);
failures.forEach(f => console.log('FAIL ' + f));
process.exit(failures.length ? 1 : 0);
