const dollars = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' });
const format = value => dollars.format(Number(value.replace(/[$,]/g, '')));
const names = {
  'Rental invoice': 'Rental total',
  'Net payments and credits on invoice': 'Payments and credits applied',
  'Remaining rental invoice': 'Remaining rental balance',
  'Security deposit on invoice': 'Security deposit'
};

export function balanceBreakdown(statement) {
  const result = { period: '', due: '', rental: [], payments: [], charges: [], notes: [] };
  // Descriptions can contain line breaks. Read through the monetary suffix of each charge.
  const lines = [];
  let pending = [];
  for (const line of String(statement || '').split('\n')) {
    const standalone = line.startsWith('Rental period: ') || /^.+: \$-?[\d,.]+$/.test(line) || line === 'Paid in full';
    if (standalone) {
      lines.push(...pending, line);
      pending = [];
    } else {
      pending.push(line);
      if (/\. Remaining \$[\d,.]+\.$/.test(line)) {
        lines.push(pending.join('\n'));
        pending = [];
      }
    }
  }
  lines.push(...pending);
  for (const line of lines) {
    if (line.startsWith('Rental period: ')) { result.period = line.slice(15); continue; }
    if (line === 'Paid in full') { result.due = '$0.00'; continue; }
    const amount = line.match(/^(.+): (\$-?[\d,.]+)$/);
    if (amount) {
      const [, key, value] = amount;
      if (key === 'Total still owed') { result.due = format(value); continue; }
      if ((key === 'Rental service fees' || key === 'Connecticut tourism surcharge') && format(value) === '$0.00') continue;
      const group = key === 'Net payments and credits on invoice' || key === 'Remaining rental invoice' ? result.payments : result.rental;
      group.push({ label: names[key] || key, amount: format(value), total: key === 'Rental invoice' || key === 'Remaining rental invoice' });
      continue;
    }
    const extra = line.match(/^([\s\S]+) — (\$[\d,.]+) including (\$[\d,.]+) tax\. (.+)\. Remaining (\$[\d,.]+)\.$/);
    if (!extra) { result.notes.push(line); continue; }
    const [, fullName, gross, tax, status, remaining] = extra;
    const parts = fullName.match(/^(.*?) \(([\s\S]+)\)$/);
    result.charges.push({ name: parts?.[1] || fullName, detail: parts?.[2] || '', gross: format(gross), tax: format(tax), status, remaining: format(remaining) });
  }
  return result;
}

export function balanceHtml(data, esc) {
  const heading = text => '<h2 style="margin:24px 0 6px;font-size:18px;line-height:1.3">' + text + '</h2>';
  const table = rows => '<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:15px;line-height:1.45">' + rows + '</table>';
  const section = (name, rows) => !rows.length ? '' : heading(name) + table(rows.map(row => {
    const style = 'border-bottom:1px solid #dae4de;padding:8px 0;font-weight:' + (row.total ? '700' : '400');
    return '<tr><td style="' + style + '">' + esc(row.label) + '</td><td align="right" style="' + style + ';padding-left:12px;white-space:nowrap">' + esc(row.amount) + '</td></tr>';
  }).join(''));
  const charge = c => '<tr><td style="border-top:1px solid #cbdad1;padding:14px 0;vertical-align:top"><b>' + esc(c.name) + '</b><br><span style="font-size:13px;color:#395846">' + esc(c.status) + ' · ' + esc(c.gross) + ' including ' + esc(c.tax) + ' tax</span>' +
    (c.detail ? '<div style="margin-top:4px;font-size:13px;color:#52655a">' + esc(c.detail) + '</div>' : '') +
    '</td><td align="right" style="border-top:1px solid #cbdad1;padding:14px 0 14px 12px;vertical-align:top;white-space:nowrap"><b>' + esc(c.remaining) + '</b><br><span style="color:#52655a;font-size:12px">remaining</span></td></tr>';
  return (data.due ? '<div style="background:#12442f;color:#fff;border-radius:8px;padding:16px 20px"><div style="font-size:15px;font-weight:bold">' + (data.due === '$0.00' ? 'Paid in full' : 'Balance due') + '</div><div style="font-size:34px;font-weight:bold;line-height:1.25">' + esc(data.due) + '</div></div>' : '') +
    (data.period ? '<p style="margin:12px 0;color:#40594b;font-size:14px">Rental period · ' + esc(data.period) + '</p>' : '') +
    section('Rental charges', data.rental) + section('Payments and credits', data.payments) +
    (data.charges.length ? heading('Additional charges') + table(data.charges.map(charge).join('')) : '') +
    data.notes.map(n => '<p>' + esc(n) + '</p>').join('');
}

export function balanceText(data) {
  const sections = [];
  if (data.due) sections.push((data.due === '$0.00' ? 'Paid in full' : 'Balance due') + ' · ' + data.due);
  if (data.period) sections.push('Rental period · ' + data.period);
  for (const [name, rows] of [['Rental charges', data.rental], ['Payments and credits', data.payments]]) {
    if (rows.length) sections.push([name, ...rows.map(row => row.label + ': ' + row.amount)].join('\n'));
  }
  if (data.charges.length) sections.push('Additional charges\n' + data.charges.map(c =>
    [c.name + ' · ' + c.status, 'Remaining: ' + c.remaining, c.gross + ' including ' + c.tax + ' tax', c.detail].filter(Boolean).join('\n')
  ).join('\n\n'));
  return [...sections, ...data.notes].join('\n\n');
}
