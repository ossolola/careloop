// Workflow 2, "Check draft" (Run once for each item).
// Accepts Gemini's wording only if it keeps the facts and avoids diagnosis words. Otherwise uses the template.
const BANNED = /diagnos(?!is\. your doctor)|diabet|hypertens|cancer|malignan|tumou?r|kidney (disease|failure)|you have (a|an) /i;

function check(draft, f) {
  const problems = [];
  const text = (draft || '').trim();
  if (!text) problems.push('no AI text');
  if (text.length > 900) problems.push('too long');
  if (/[\[\]{}]/.test(text)) problems.push('placeholder brackets');
  if (BANNED.test(text.replace(/This is not a diagnosis\.?/i, ''))) problems.push('diagnosis wording');
  for (const m of f.must_mention || []) if (m && !text.includes(m)) problems.push('missing: ' + m);
  const ok = problems.length === 0;
  let body = ok ? text : f.template;
  if (ok && f.safety && !body.includes('998')) body = body + ' ' + f.safety;  // safety line is never left to the AI
  return { body, drafted_by: ok ? 'gemini' : 'template', check_notes: ok ? 'passed checks' : problems.join('; ') };
}
if (typeof module !== 'undefined') module.exports = { check };
