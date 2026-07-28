import { readdirSync, readFileSync, statSync } from 'node:fs';
import { gzipSync } from 'node:zlib';

const kb = (bytes) => `${(bytes / 1024).toFixed(1)} KB`;
const vehiclePattern = /^(Audi|Benz|BMW|Buick|Cadillac|Dodge|Ford|Kia|Mercedes).+\.webp$/;
const assetNames = readdirSync('assets');
const vehicleImages = assetNames.filter((name) => vehiclePattern.test(name));
const checks = [];

for (const name of vehicleImages) {
  checks.push([`Vehicle ${name}`, `assets/${name}`, 200 * 1024, false]);
}

const fleetBytes = vehicleImages.reduce((total, name) => total + statSync(`assets/${name}`).size, 0);
checks.push(['Complete vehicle fleet', null, 3 * 1024 * 1024, false, fleetBytes]);
checks.push(['Homepage background', 'assets/background.webp', 200 * 1024, false]);

for (const [label, directory, pattern, budget] of [
  ['Client portal JavaScript', 'rentmect-client-portal/dist/assets', /^index-.*\.js$/, 180 * 1024],
  ['Admin portal JavaScript', 'rentmect-admin-portal/dist/assets', /^index-.*\.js$/, 180 * 1024],
]) {
  const bundle = readdirSync(directory).find((name) => pattern.test(name));
  if (bundle) checks.push([label, `${directory}/${bundle}`, budget, true]);
}

const carsHtml = readFileSync('cars.html', 'utf8');
const eagerVehicleImages = (carsHtml.match(/<img[^>]+loading="eager"[^>]*>/g) || []).length;
const pngVehicleReferences = (carsHtml.match(/assets\/(?:Audi|Benz|BMW|Buick|Cadillac|Dodge|Ford|Kia|Mercedes)[^"']+\.png/g) || []).length;

let failed = false;
for (const [label, file, budget, compressed, suppliedBytes] of checks) {
  const bytes = suppliedBytes ?? (compressed ? gzipSync(readFileSync(file)).length : statSync(file).size);
  const passes = bytes <= budget;
  failed ||= !passes;
  console.log(`${passes ? 'PASS' : 'FAIL'} ${label}: ${kb(bytes)} / ${kb(budget)}${compressed ? ' gzip' : ''}`);
}

for (const [label, value, budget] of [
  ['Eager vehicle images', eagerVehicleImages, 1],
  ['PNG vehicle references', pngVehicleReferences, 0],
]) {
  const passes = value <= budget;
  failed ||= !passes;
  console.log(`${passes ? 'PASS' : 'FAIL'} ${label}: ${value} / ${budget}`);
}

if (vehicleImages.length < 29) {
  failed = true;
  console.log(`FAIL Built-in vehicle coverage: ${vehicleImages.length} / 29 images`);
} else {
  console.log(`PASS Built-in vehicle coverage: ${vehicleImages.length} / 29 images`);
}

if (failed) process.exitCode = 1;
