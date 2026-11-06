// Workflow 2, "Build message facts" (Run once for all items).
// Turns each referred case into plain facts for the message. No names, no IDs, no contact details.
const LABEL = {
  BP_SEVERE: 'blood pressure', BP_STAGE2: 'blood pressure', BP_STAGE1: 'blood pressure', BP_ELEVATED: 'blood pressure',
  A1C_DIABETES: 'HbA1c (average blood sugar)', A1C_PREDIABETES: 'HbA1c (average blood sugar)',
  GLU_SEVERE: 'blood sugar', GLU_FASTING_DIABETES: 'fasting blood sugar', GLU_FASTING_PREDIABETES: 'fasting blood sugar', GLU_RANDOM_HIGH: 'blood sugar',
  BMI_OBESE: 'BMI (weight for height)', BMI_OVERWEIGHT: 'BMI (weight for height)',
  LDL_SEVERE: 'LDL cholesterol', EGFR_G5: 'kidney function (eGFR)', EGFR_G4: 'kidney function (eGFR)', EGFR_G3: 'kidney function (eGFR)',
  FIT_POS: 'bowel screening test (FIT)', HPV_POS: 'cervical screening test', CERVIX_LESION: 'cervical screening check', CERVIX_UNSAT: 'cervical screening sample',
  MAMMO_SUSPICIOUS: 'mammogram', MAMMO_SHORT_INTERVAL: 'mammogram',
};
const fmtDate = iso => new Date(iso).toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'Asia/Dubai' });

function build(c) {
  const readings = (c.findings || []).filter(f => LABEL[f.rule_code]).map(f => `${LABEL[f.rule_code]}: ${f.value}`);
  const refs = c.referrals || [];
  const first = refs[0];
  const deadline = fmtDate(c.due_at);
  let next_step, must_mention = [deadline];
  if (c.priority === 'P1' && c.route === 'same_day_call') {
    next_step = `Your care team at ${c.clinic} will call you today to talk about your results.`;
    must_mention = [c.clinic];
  } else if (c.priority === 'P1') {
    next_step = `You need an appointment with the ${first.to} straight away. Your care team will call you today to arrange it.`;
    must_mention = [first.to];
  } else if (!first) {
    const codes = (c.findings || []).map(f => f.rule_code);
    if (codes.includes('CERVIX_UNSAT')) {
      next_step = `The sample from your cervical screening could not be read, so the test needs to be repeated. Please book a repeat test at ${c.clinic} by ${deadline}.`;
      must_mention.push(c.clinic);
    } else if (codes.includes('MAMMO_SHORT_INTERVAL')) {
      next_step = `Your mammogram needs a follow-up scan to check that nothing has changed. Please book it by ${deadline}.`;
    } else {
      next_step = `You don't need an appointment now. Small changes like regular activity and less salt and sugar can help, and we will remind you about your next check.`;
      must_mention = [];
    }
  } else if (first.mode === 'teleconsult') {
    next_step = `Please book a video consultation with the ${first.to} by ${deadline}.`;
    must_mention.push(first.to);
  } else {
    const places = refs.map(r => r.to === r.place ? `the ${r.to}` : `${r.to} at ${r.place}`);
    next_step = `Please book an appointment with ${places.join(' and with ')} by ${deadline}.`;
    must_mention.push(...refs.map(r => r.to));
  }
  const safety = c.priority === 'P1'
    ? 'If you have chest pain, a severe headache, trouble breathing or feel very unwell, call 998 now.' : '';
  const template = [
    'Your recent health screening results need a follow-up.',
    readings.length ? `Results to discuss: ${readings.join('; ')}.` : '',
    next_step,
    'This is not a diagnosis. Your doctor will explain what the results mean for you.',
    safety,
  ].filter(Boolean).join(' ');
  const coordinator_note = `Patient declined app messages. Contact by phone or at the clinic. ${c.priority} case, `
    + `${readings.join('; ') || 'see findings'}. Next step: ${next_step} Deadline ${deadline}.`;
  const internal = c.channel === 'internal';
  return {
    case_id: c.case_id, priority: c.priority, channel: c.channel,
    facts: { age_band: `${Math.floor(c.age / 10) * 10}s`, sex: c.sex, urgency: c.priority, readings, next_step, deadline },
    must_mention, safety, template,
    needs_ai: !internal,
    kind: internal ? 'coordinator-note' : 'result',
    final_body: internal ? coordinator_note : null,
    drafted_by: internal ? 'template' : null,
    check_notes: internal ? 'consent declined: coordinator note, no AI' : null,
  };
}
if (typeof module !== 'undefined') module.exports = { build };
