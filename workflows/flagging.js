// CareLoop flagging rules, v0.2
// Source of truth for the rules: rules/flagging-rules.md
// This exact function runs inside the "Apply flagging rules" Code node in n8n.
// It is deterministic: no AI, no randomness. Same input, same decision.

const RULES_VERSION = 'v0.2';

function evaluate(bundle, patient) {
  const RANK = { P1: 1, P2: 2, P3: 3, P4: 4 };
  const TARGET_DAYS = {
    BP_SEVERE: 0, BP_STAGE2: 28, BP_STAGE1: 90, BP_ELEVATED: 1095,
    GLU_SEVERE: 0, A1C_DIABETES: 28, GLU_FASTING_DIABETES: 28, GLU_RANDOM_HIGH: 28,
    A1C_PREDIABETES: 90, GLU_FASTING_PREDIABETES: 90,
    BMI_OBESE: 90, BMI_OVERWEIGHT: 1095,
    LDL_SEVERE: 28,
    EGFR_G5: 0, EGFR_G4: 14, EGFR_G3: 90,
    FIT_POS: 60,
    CERVIX_LESION: 0, HPV_POS: 90, CERVIX_UNSAT: 42,
    MAMMO_SUSPICIOUS: 7, MAMMO_SHORT_INTERVAL: 180,
  };
  const received = bundle.timestamp || new Date().toISOString();
  const findings = [];
  const stop = (reason, detail) => ({
    status: 'stopped', stop_reason: reason, stop_detail: detail,
    priority: null, findings: [], route: 'data_check_queue', due_at: null,
    contact_flag: false, contact_reasons: [], rules_version: RULES_VERSION,
  });
  const add = (rule_code, priority, value_text) =>
    findings.push({ rule_code, priority, value_text, target_days: TARGET_DAYS[rule_code] ?? null });

  // 1. The result must belong to a patient we know
  if (!patient) return stop('NO_MATCH', 'No patient record matches ' + (bundle.patient_ref || 'the result'));

  const obs = (bundle.entry || []).map(e => e.resource).filter(r => r && r.resourceType === 'Observation');
  if (obs.length === 0) return stop('MISSING_VALUE', 'Result contains no observations');

  const codeOf = o => ((o.code || {}).coding || [])[0]?.code;
  const qty = (o, label) => {
    const q = o.valueQuantity;
    if (!q || q.value === undefined || q.value === null || q.value === '') return { err: stop('MISSING_VALUE', label + ' has no value') };
    if (!q.unit && !q.code) return { err: stop('MISSING_UNIT', label + ' has no unit') };
    return { value: Number(q.value), unit: q.code || q.unit };
  };
  const inRange = (v, lo, hi) => Number.isFinite(v) && v >= lo && v <= hi;
  const isFemale = patient.gender === 'female';

  for (const o of obs) {
    const code = codeOf(o);
    if (o.dataAbsentReason) return stop('MISSING_VALUE', (o.code.text || code) + ' was not returned by the lab');

    // Blood pressure: read each value by its code, never by position
    if (code === '85354-9') {
      const comps = {};
      for (const c of o.component || []) comps[(c.code.coding || [])[0]?.code] = c;
      const s = comps['8480-6'], d = comps['8462-4'];
      if (!s || !d) return stop('MISSING_VALUE', 'Blood pressure is missing systolic or diastolic');
      const sq = qty(s, 'Systolic BP'); if (sq.err) return sq.err;
      const dq = qty(d, 'Diastolic BP'); if (dq.err) return dq.err;
      const sbp = sq.value, dbp = dq.value;
      if (!inRange(sbp, 60, 300) || !inRange(dbp, 30, 200)) return stop('IMPLAUSIBLE', `Blood pressure ${sbp}/${dbp} is outside possible values`);
      if (dbp >= sbp) return stop('IMPLAUSIBLE', `Diastolic ${dbp} is not lower than systolic ${sbp}`);
      const t = `${sbp}/${dbp} mmHg`;
      if (sbp >= 180 || dbp >= 120) add('BP_SEVERE', 'P1', t);
      else if (sbp >= 140 || dbp >= 90) add('BP_STAGE2', 'P2', t);
      else if (sbp >= 130 || dbp >= 80) add('BP_STAGE1', 'P3', t);
      else if (sbp >= 120) add('BP_ELEVATED', 'P4', t);
    }

    else if (code === '4548-4') {
      const q = qty(o, 'HbA1c'); if (q.err) return q.err;
      if (q.unit !== '%') return stop('MISSING_UNIT', 'HbA1c unit "' + q.unit + '" not recognised');
      if (!inRange(q.value, 3, 20)) return stop('IMPLAUSIBLE', 'HbA1c ' + q.value + '% is outside possible values');
      const t = q.value + '%';
      if (q.value >= 6.5) add('A1C_DIABETES', 'P2', t);
      else if (q.value >= 5.7) add('A1C_PREDIABETES', 'P3', t);
    }

    else if (['14771-0', '15074-8', '1558-6', '2339-0'].includes(code)) {
      const fasting = code === '14771-0' || code === '1558-6';
      const q = qty(o, 'Glucose'); if (q.err) return q.err;
      let mmol;
      if (q.unit === 'mmol/L') mmol = q.value;
      else if (q.unit === 'mg/dL') mmol = q.value / 18.0;
      else return stop('MISSING_UNIT', 'Glucose unit "' + q.unit + '" not recognised');
      if (!inRange(mmol, 1, 50)) return stop('IMPLAUSIBLE', 'Glucose ' + q.value + ' ' + q.unit + ' is outside possible values');
      const t = `${q.value} ${q.unit}${q.unit === 'mg/dL' ? ' (' + mmol.toFixed(1) + ' mmol/L)' : ''}, ${fasting ? 'fasting' : 'random'}`;
      if (mmol >= 16.7) add('GLU_SEVERE', 'P1', t);
      else if (fasting && mmol >= 7.0) add('GLU_FASTING_DIABETES', 'P2', t);
      else if (fasting && mmol >= 5.6) add('GLU_FASTING_PREDIABETES', 'P3', t);
      else if (!fasting && mmol >= 11.1) add('GLU_RANDOM_HIGH', 'P2', t); // PROPOSED rule, awaiting clinician review
    }

    else if (code === '39156-5') {
      const q = qty(o, 'BMI'); if (q.err) return q.err;
      if (!inRange(q.value, 10, 90)) return stop('IMPLAUSIBLE', 'BMI ' + q.value + ' is outside possible values');
      const t = q.value + ' kg/m2';
      if (q.value >= 30) add('BMI_OBESE', 'P3', t);
      else if (q.value >= 25) add('BMI_OVERWEIGHT', 'P4', t);
    }

    else if (code === '22748-8' || code === '18262-6') {
      const q = qty(o, 'LDL'); if (q.err) return q.err;
      const mmol = q.unit === 'mg/dL' ? q.value / 38.67 : q.value;
      if (!inRange(mmol, 0.1, 20)) return stop('IMPLAUSIBLE', 'LDL ' + q.value + ' ' + q.unit + ' is outside possible values');
      if (mmol >= 4.9) add('LDL_SEVERE', 'P2', `${q.value} ${q.unit}`);
    }

    else if (['62238-1', '33914-3', '98979-8'].includes(code)) {
      const q = qty(o, 'eGFR'); if (q.err) return q.err;
      if (!inRange(q.value, 1, 200)) return stop('IMPLAUSIBLE', 'eGFR ' + q.value + ' is outside possible values');
      const t = q.value + ' mL/min/1.73m2';
      if (q.value < 15) add('EGFR_G5', 'P1', t);
      else if (q.value < 30) add('EGFR_G4', 'P2', t);
      else if (q.value < 60) add('EGFR_G3', 'P3', t);
    }

    else if (code === 'fit') {
      const v = (o.valueCodeableConcept || {}).text;
      if (!v) return stop('MISSING_VALUE', 'FIT has no result');
      if (v === 'positive') add('FIT_POS', 'P2', 'FIT positive');
    }

    else if (code === 'cervical-screen') {
      const v = (o.valueCodeableConcept || {}).text;
      if (!v) return stop('MISSING_VALUE', 'Cervical screen has no result');
      if (!isFemale) return stop('INCONSISTENT', 'Cervical screening result on a record that is not female');
      if (v === 'visible_lesion') add('CERVIX_LESION', 'P1', 'Visible suspicious lesion');
      else if (v === 'hpv_positive') add('HPV_POS', 'P2', 'HPV positive');
      else if (v === 'unsatisfactory') add('CERVIX_UNSAT', 'P4', 'Unsatisfactory sample');
    }

    else if (code === 'mammogram-birads') {
      const v = (o.valueCodeableConcept || {}).text;
      if (!v) return stop('MISSING_VALUE', 'Mammogram has no BI-RADS category');
      if (!isFemale) return stop('INCONSISTENT', 'Mammogram result on a record that is not female');
      if (['birads_0', 'birads_4', 'birads_5'].includes(v)) add('MAMMO_SUSPICIOUS', 'P2', v.replace('birads_', 'BI-RADS '));
      else if (v === 'birads_3') add('MAMMO_SHORT_INTERVAL', 'P4', 'BI-RADS 3');
    }
  }

  if (findings.length === 0) {
    return { status: 'no_flag', stop_reason: null, priority: null, findings: [], route: 'none',
             due_at: null, contact_flag: false, contact_reasons: [], rules_version: RULES_VERSION };
  }

  // Age outside the programme: still act on it, but mark it (PROPOSED, awaiting clinician review)
  const when = new Date(received);
  const b = new Date(patient.birth_date + 'T00:00:00Z');
  let age = when.getUTCFullYear() - b.getUTCFullYear();
  if (when.getUTCMonth() < b.getUTCMonth() || (when.getUTCMonth() === b.getUTCMonth() && when.getUTCDate() < b.getUTCDate())) age--;
  if (age < 18 || age > 75) findings.push({ rule_code: 'OUT_OF_SCOPE_AGE', priority: 'P4', value_text: 'Age ' + age, target_days: null });

  findings.sort((x, y) => RANK[x.priority] - RANK[y.priority]);
  const priority = findings[0].priority;
  const codes = new Set(findings.map(f => f.rule_code));

  let route;
  if (priority === 'P1') route = codes.has('CERVIX_LESION') ? 'gynae_oncology_now' : 'same_day_call';
  else if (priority === 'P2') {
    const r = [];
    const p2 = findings.filter(f => f.priority === 'P2').map(f => f.rule_code);
    if (p2.some(c => !['FIT_POS', 'HPV_POS', 'MAMMO_SUSPICIOUS'].includes(c))) r.push('in_person_family_doctor');
    if (codes.has('FIT_POS')) r.push('colonoscopy');
    if (codes.has('HPV_POS')) r.push('colposcopy');
    if (codes.has('MAMMO_SUSPICIOUS')) r.push('breast_assessment');
    route = r.join('+');
  } else if (priority === 'P3') route = 'teleconsult';
  else route = 'message_recall';

  // Deadline: the earliest target across all findings. Same day = end of that day in Abu Dhabi (UTC+4).
  const days = Math.min(...findings.map(f => f.target_days).filter(d => d !== null));
  let due;
  if (days === 0) {
    const local = new Date(when.getTime() + 4 * 3600e3);
    due = new Date(Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate(), 23, 59, 59) - 4 * 3600e3);
  } else {
    due = new Date(when.getTime() + days * 86400e3);
  }

  const contact_reasons = [];
  if (!patient.phone) contact_reasons.push('NO_PHONE');
  if (patient.consent_status === 'rejected') contact_reasons.push('CONSENT_DECLINED');

  return {
    status: 'flagged', stop_reason: null, priority, findings, route,
    target_days: days, due_at: due.toISOString(),
    contact_flag: contact_reasons.length > 0, contact_reasons,
    rules_version: RULES_VERSION,
  };
}

if (typeof module !== 'undefined') module.exports = { evaluate, RULES_VERSION };
