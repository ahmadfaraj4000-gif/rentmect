// The three independently deployed readers format the immutable signing snapshot.
import { agreementLogo } from './agreementLogo.js';

const escape = value => String(value ?? '').replace(/[&<>"']/g, ch => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
})[ch]);

export function taxRateSuffix(rate) {
  if (rate == null || rate === '' || !Number.isFinite(Number(rate))) return '';
  return ' (' + (Number(rate) * 100).toFixed(2) + '%)';
}

const styles = `
.rm-agreement{box-sizing:border-box;max-width:820px;margin:auto;padding:clamp(16px,4vw,38px);background:white;color:#192322;font:15px/1.52 Georgia,serif;overflow-wrap:anywhere;text-align:left}
.rm-agreement .rm-head{border-bottom:3px solid #146544;padding-bottom:14px;margin-bottom:18px}
.rm-agreement .rm-logo{display:block;width:148px;height:auto;margin:0 0 14px}
.rm-agreement .rm-title{font:600 32px/1.08 Georgia,serif;margin:0;color:#142e25}
.rm-agreement h3{font:700 16px/1.25 Arial,sans-serif;margin:22px 0 8px;color:#164c38;break-after:avoid}
.rm-agreement p{font:inherit;color:inherit;margin:0 0 8px;orphans:2;widows:2}
.rm-agreement dl{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:0 18px;margin:0}
.rm-agreement dl div{padding:7px 0;border-bottom:1px solid #d9e1dc;break-inside:avoid}
.rm-agreement .rm-wide{grid-column:1/-1}.rm-agreement dt{color:#435d52;font:700 11px/1.25 Arial,sans-serif}
.rm-agreement dd{margin:3px 0 0;font:15px/1.35 Georgia,serif}
.rm-agreement .rm-signature{border-top:2px solid #315e48;margin-top:24px;padding-top:12px;break-inside:avoid}
.rm-agreement .rm-signature img{display:block;max-width:240px;max-height:76px;object-fit:contain}
@media(max-width:480px){.rm-agreement dl{grid-template-columns:1fr}.rm-agreement .rm-title{font-size:25px}}
`;
const printStyles = `@page{size:letter;margin:.62in .72in .65in;@bottom-right{content:"Rent Me CT   ·   " counter(page) " / " counter(pages);font:9pt Arial,sans-serif;color:#435d52}}
body{margin:0;background:#edf1ee}.rm-agreement{margin:20px auto}
@media print{body{background:white}.rm-agreement{padding:0;margin:0;max-width:none;font-size:10.5pt}.rm-agreement h3{font-size:12pt}.rm-agreement dd{font-size:10.5pt}.rm-agreement dl{grid-template-columns:repeat(2,minmax(0,1fr))}.rm-agreement dl div{padding:4pt 0}.rm-agreement .rm-title{font-size:24pt}}`;

export function agreementMarkup(snapshot, signedAt) {
  const source = String(snapshot || '');
  const signature = /Drawn Signature Image:\s*(data:image\/png;base64,[A-Za-z0-9+/=]+)/.exec(source)?.[1];
  const lines = source.replace(/Drawn Signature Image:[ \t]*(?:data:image\/png;base64,[^\s]+|Pending)/g,'').split(/\r?\n/);
  const start = lines.findIndex(line => line.trim() === 'AUTO-FILLED RENTAL DETAILS');
  const end = lines.findIndex((line,i) => i > start && /^-{10,}$/.test(line.trim()));
  const details = start >= 0 && end > start ? lines.slice(start+1,end) : [];
  const body = details.length ? [...lines.slice(0,start), ...lines.slice(end+1)] : lines;
  const fields = new Map();
  const groups = [];
  let rows = [];
  let signer = '';
  const record = [];
  function flush() { if (rows.length) groups.push('<dl>'+rows.join('')+'</dl>'); rows=[]; }
  for (const raw of details) {
    const line = raw.trim();
    if (!line) { flush(); continue; }
    const match = /^([^:]{1,80}):(?:\s+(.*)|$)/.exec(line);
    if (!match) { flush(); groups.push('<p>'+escape(line)+'</p>'); continue; }
    const [,key,value = ''] = match;
    fields.set(key,value);
    if (key === 'Typed Signature') { signer = value; continue; }
    const cell=(value.length > 85 ? '<div class="rm-wide"><dt>' : '<div><dt>')+escape(key)+'</dt><dd>'+escape(value)+'</dd></div>';
    if (['Agreement Version','Signed Snapshot Generated','Signature Entry Method'].includes(key)) record.push(cell);
    else rows.push(cell);
  }
  flush();
  const duplicateFields = { 'Full Legal Name':'Renter Name','Address':'Address','Phone':'Phone','Email':'Email','Make':'Make','Model':'Model','Year':'Year','VIN':'VIN','License Plate':'License Plate','Rental Start Date':'Pickup Date/Time','Rental End Date':'Return Date/Time','Return Location':'Return Location','Daily Rate':'Daily Rate','Security Deposit':'Security Deposit' };
  let heading = '', paragraphs = [], addendum = false, removedFields = false;
  const terms = [];
  function section() {
    if (paragraphs.length || (heading && !removedFields)) terms.push((heading ? '<h3>'+escape(heading)+'</h3>' : '')+paragraphs.join(''));
    paragraphs=[]; removedFields=false;
  }
  for (const raw of body) {
    const line=raw.trim();
    if (!line || line==='RENTMECT' || line==='MASTER VEHICLE RENTAL AGREEMENT') continue;
    if (line==='RENTAL ADDENDUM') addendum=true;
    if (/^[A-Z][A-Z &’'/,();.0-9–-]+$/.test(line)) { section(); heading=line; continue; }
    const [key] = line.split(':');
    const blank = /^[^:]+:\s*\$?_+[\s\S]*$/.test(line) && !line.replace(/^[^:]+:/,'').replace(/(?:Time|Date|License #):/g,'').replace(/[_\s$]/g,'');
    if (blank && ((addendum && fields.has(duplicateFields[key])) ||
        (details.length && heading === 'SIGNATURES' && source.includes('Company Representative: ____________________ Date:')) ||
        (details.length && heading === 'ACKNOWLEDGMENT' && key === 'Renter Signature'))) {
      removedFields=true;
      continue;
    }
    paragraphs.push('<p>'+escape(line)+'</p>');
  }
  section();
  const signed = signer && signer !== 'Pending';
  const signatureBlock = signed || signature || signedAt ? '<section class="rm-signature"><h3>Renter signature</h3>'+
    (signature ? '<img src="'+escape(signature)+'" alt="Electronic renter signature">' : '')+
    (signed ? '<p>'+escape(signer)+'</p>' : '')+(signedAt ? '<p>Signed '+escape(signedAt)+'</p>' : '')+'</section>' : '';
  return '<style>'+styles+'</style><article class="rm-agreement"><header class="rm-head"><img class="rm-logo" src="'+agreementLogo+'" alt="Rent Me CT"><h2 class="rm-title">Master Vehicle Rental Agreement</h2></header>'+
    (groups.length ? '<h3>Rental details</h3>'+groups.join('') : '')+terms.join('')+signatureBlock+(record.length ? '<h3>Agreement record</h3><dl>'+record.join('')+'</dl>' : '')+'</article>';
}

export function agreementCopy(rental) {
  if (!rental?.agreement_snapshot) throw new Error('No saved signed agreement is available.');
  const name = rental.agreement_signature_name || rental.profiles?.full_name || 'Customer';
  const title = name+' - Agreement - '+(rental.pickup_date || 'start')+' to '+(rental.return_date || 'end');
  const filename = title.replace(/[<>:"/\\|?*\x00-\x1f]/g,'-').trim().slice(0,180)+'.html';
  const html='<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>'+escape(title)+'</title></head><body>'+agreementMarkup(rental.agreement_snapshot,rental.agreement_signed_at)+'<style>'+printStyles+'</style></body></html>';
  return {title,filename,html};
}
