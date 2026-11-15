export function agreementCopy(rental) {
  if (!rental?.agreement_snapshot) throw new Error('No saved signed agreement is available.');
  const name = rental.agreement_signature_name || rental.profiles?.full_name || 'Customer';
  const dates = `${rental.pickup_date || 'start'} to ${rental.return_date || 'end'}`;
  const title = `${name} - Agreement - ${dates}`;
  const filename = title.replace(/[<>:"/\\|?*\x00-\x1f]/g, '-').trim().slice(0, 180) + '.html';
  const escape = value => String(value || '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const snapshot = String(rental.agreement_snapshot);
  const signature = snapshot.match(/Drawn Signature Image:\s*(data:image\/png;base64,[A-Za-z0-9+/=]+)/)?.[1] || '';
  const text = snapshot.replace(/Drawn Signature Image:\s*data:image\/png;base64,[^\s]+/, 'Drawn Signature Image: embedded below');
  const html = `<!doctype html><html><head><meta charset="utf-8"><title>${escape(title)}</title><style>body{font-family:Arial,sans-serif;color:#172033;line-height:1.5;padding:32px;max-width:900px;margin:auto}pre{white-space:pre-wrap;font-family:inherit}.signature{margin-top:24px;border:1px solid #d6dee8;border-radius:10px;padding:16px}.signature img{max-width:420px;width:100%;height:auto;display:block}</style></head><body><pre>${escape(text)}</pre>${signature ? `<div class="signature"><strong>Electronic Signature</strong><img src="${signature}" alt="Electronic renter signature"></div>` : ''}</body></html>`;
  return { title, filename, html };
}
