// Runs the real signing UI with synthetic rental data; no Supabase/Stripe calls.
// PLAYWRIGHT_MODULE may point to an existing Playwright installation.
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import assert from 'node:assert/strict';
import { resolve } from 'node:path';
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = resolve('rentmect-client-portal');
const folder = await mkdtemp(root + '/.signing-test-');
const source = await readFile(root + '/src/main.jsx', 'utf8');
const components = source.slice(source.indexOf('function AgreementModal('), source.indexOf('function InsuranceOptionsPanel('));
const focus = source.slice(source.indexOf('function useDialogFocus('), source.indexOf('class PortalErrorBoundary'));
await writeFile(folder + '/index.html', '<meta name="viewport" content="width=device-width, initial-scale=1"><div id="root"></div><script type="module" src="./test.jsx"></script>');
await writeFile(folder + '/test.jsx', `import React, { useState, useEffect, useRef } from 'react';
import { createRoot } from 'react-dom/client';
import { X, ArrowDown, FileSignature } from 'lucide-react';
import '../src/styles.css'; import '../src/final-overrides.css';
const extractSignatureImage = () => ''; const downloadAgreement = () => {};
${focus}\n${components}
function App() {
 const [checked, setChecked] = useState(false), [name, setName] = useState(''), [image, setImage] = useState('');
 const [saving, setSaving] = useState(false), [error, setError] = useState(''), [done, setDone] = useState(false);
 const signed = new URLSearchParams(location.search).has('signed');
 return done ? <p role="status">Agreement saved. Continue to payment.</p> : <AgreementModal
 agreementText={'NEW AGREEMENT\\n'.repeat(150)} agreementChecked={checked} setAgreementChecked={setChecked}
 signatureName={name} setSignatureName={setName} signatureImageData={image} setSignatureImageData={setImage}
 agreementSigned={signed} currentRental={{ agreement_snapshot: 'OLD SIGNED COPY', agreement_signature_name: 'Past Renter' }}
 agreementSaving={saving} agreementError={error} onClose={() => {}}
 signAgreement={async () => { setSaving(true); await new Promise(r => setTimeout(r, 100));
 if (new URLSearchParams(location.search).has('fail')) { setError('Connection interrupted. Please try again.'); setSaving(false); }
 else setDone(true); }} />;
} createRoot(document.getElementById('root')).render(<App/>);`);
const server = spawn(process.execPath, [root + '/node_modules/vite/bin/vite.js', '--host', '127.0.0.1', '--port', '5188', '--strictPort'], { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
let browser;
try {
 await new Promise((resolveReady, reject) => { server.stdout.on('data', d => { if (d.toString().includes('Local:')) resolveReady(); }); server.on('error', reject); server.on('exit', () => reject(Error('Vite exited'))); });
 browser = await chromium.launch({ headless: true, ...(process.env.PLAYWRIGHT_CHANNEL ? { channel: process.env.PLAYWRIGHT_CHANNEL } : {}) });
 const url = 'http://127.0.0.1:5188/' + folder.split('/').at(-1) + '/index.html';
 for (const mobile of [false, true]) {
   const page = await browser.newPage({ viewport: mobile ? { width: 390, height: 664 } : { width: 1280, height: 900 }, isMobile: mobile, hasTouch: mobile });
   const errors = []; page.on('pageerror', e => errors.push(e.message));
   await page.goto(url);
   await page.getByRole('button', { name: '3. Agree, sign & continue' }).click();
   await page.getByRole('alert').filter({ hasText: 'Step 1:' }).waitFor();
   // An unsigned rental with an old snapshot must still allow signing the NEW agreement.
   assert.match(await page.getByLabel('Complete rental agreement').innerText(), /NEW AGREEMENT/);
   await page.getByRole('checkbox').check();
   await page.getByRole('textbox', { name: '2. Full legal name' }).fill('Test Renter');
   await page.getByRole('button', { name: 'Use my typed signature' }).click();
   await page.getByRole('status').filter({ hasText: 'Signature ready' }).waitFor();
   await page.getByRole('textbox', { name: '2. Full legal name' }).fill('Corrected Renter');
   assert.match(await page.getByRole('status').innerText(), /not been saved yet/);
   await page.getByRole('button', { name: 'Use my typed signature' }).click();
   await page.screenshot({ path: '/tmp/rentme-signing-' + (mobile ? 'mobile' : 'desktop') + '.png', fullPage: true });
   await page.getByRole('button', { name: '3. Agree, sign & continue' }).click();
   await page.getByRole('status').filter({ hasText: 'Agreement saved' }).waitFor();
   await page.goto(url + '?fail=1');
   await page.getByRole('checkbox').check();
   await page.getByRole('textbox', { name: '2. Full legal name' }).fill('Drawn Renter');
   const canvas = page.locator('canvas'); await canvas.scrollIntoViewIfNeeded();
   const box = await canvas.boundingBox();
   if (mobile) {
     const cdp = await page.context().newCDPSession(page);
     await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: box.x + 20, y: box.y + 30 }] });
     await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: box.x + 100, y: box.y + 60 }] });
     await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
   } else {
     await page.mouse.move(box.x + 20, box.y + 30); await page.mouse.down();
     await page.mouse.move(box.x + 100, box.y + 60, { steps: 8 }); await page.mouse.up();
   }
   await page.getByRole('status').filter({ hasText: 'Signature ready' }).waitFor();
   await page.getByRole('button', { name: '3. Agree, sign & continue' }).click();
   await page.getByRole('alert').filter({ hasText: 'Connection interrupted' }).waitFor();
   assert.equal(await page.getByRole('button', { name: '3. Agree, sign & continue' }).isEnabled(), true);
   await page.getByRole('button', { name: 'Clear signature' }).click();
   assert.match(await page.getByRole('status').innerText(), /not been saved yet/);
   await page.goto(url + '?signed=1');
   await page.getByText('OLD SIGNED COPY', { exact: true }).waitFor();
   assert.equal(await page.getByRole('checkbox').count(), 0);
   assert.deepEqual(errors, []);
   await page.close(); console.log((mobile ? 'Mobile touch' : 'Desktop mouse') + ': typed/drawn signing, validation, stale snapshot, saved copy, clear and retry passed.');
 }
} finally {
 await browser?.close(); server.kill(); await once(server, 'exit'); await rm(folder, { recursive: true, force: true });
}
