import fs from 'node:fs/promises';
import path from 'node:path';

const root = process.cwd();
const carsSource = await fs.readFile(path.join(root, 'cars.html'), 'utf8');
const cards = [...carsSource.matchAll(
  /<article[^>]*data-wheelbase-rental-id="(\d+)"[^>]*>[\s\S]*?<h3>[^<]*#([A-Z0-9]+)<\/h3>[\s\S]*?<\/article>/gi
)].map((match) => ({
  rentalId: match[1],
  fleetNumber: match[2].toUpperCase(),
}));

if (cards.length !== 29) {
  throw new Error(`Expected 29 Wheelbase-connected vehicles, found ${cards.length}.`);
}

const galleryMap = {};
for (let index = 0; index < cards.length; index += 5) {
  const batch = cards.slice(index, index + 5);
  const results = await Promise.all(batch.map(async ({ rentalId, fleetNumber }) => {
    const response = await fetch(`https://api.outdoorsy.co/v0/rentals/${rentalId}`, {
      headers: { Accept: 'application/json' },
    });
    if (!response.ok) throw new Error(`Wheelbase rental ${rentalId} failed (${response.status}).`);
    const rental = await response.json();
    const supportingPhotos = (Array.isArray(rental.images) ? rental.images : [])
      .filter((image) => image?.url && !image.primary)
      .sort((a, b) => Number(a.position ?? 0) - Number(b.position ?? 0));
    const preferredPositions = fleetNumber === '001' ? new Set([1, 2, 4, 5]) : null;
    const realPhotos = supportingPhotos
      // Wheelbase position 0 is a second generated showroom image. The local
      // showroom asset is already the primary image, so never repeat it.
      .filter((image) => Number(image.position ?? 0) > 0)
      // Audi S3 #001 includes an extra trunk-open shot between the exterior
      // and interior photos. Match the original cars.html gallery exactly.
      .filter((image) => !preferredPositions || preferredPositions.has(Number(image.position)))
      .slice(0, 4)
      .map((image) => highResolutionCloudinaryUrl(image.url));
    if (realPhotos.length !== 4) {
      throw new Error(`Wheelbase rental ${rentalId} exposes ${realPhotos.length} supporting photos; expected 4.`);
    }
    return [fleetNumber, realPhotos];
  }));
  results.forEach(([fleetNumber, images]) => { galleryMap[fleetNumber] = images; });
}

const orderedMap = Object.fromEntries(Object.entries(galleryMap).sort(([a], [b]) => a.localeCompare(b)));
const browserSource = `// Generated from the public Wheelbase rental records by tools/sync-wheelbase-gallery.mjs.\nwindow.RENTMECT_FLEET_GALLERY_IMAGES = Object.freeze(${JSON.stringify(orderedMap, null, 2)});\n`;
const moduleSource = `// Generated from the public Wheelbase rental records by tools/sync-wheelbase-gallery.mjs.\nconst FLEET_GALLERY_IMAGES = Object.freeze(${JSON.stringify(orderedMap, null, 2)});\n\nexport default FLEET_GALLERY_IMAGES;\n`;

await fs.writeFile(path.join(root, 'fleet-gallery-data.js'), browserSource);
await fs.writeFile(path.join(root, 'rentmect-client-portal', 'src', 'fleetGalleryImages.js'), moduleSource);
console.log(`Synced ${Object.keys(orderedMap).length} five-photo vehicle galleries from Wheelbase.`);

function highResolutionCloudinaryUrl(value) {
  const url = String(value || '');
  if (!url.includes('/image/upload/')) return url;
  return url.replace('/image/upload/', '/image/upload/c_limit,f_auto,q_auto,w_1200/');
}
