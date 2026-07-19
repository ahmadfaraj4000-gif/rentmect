# Performance budget

## Baseline captured July 19, 2026

- Public fleet images referenced by `cars.html`: approximately 47 MB.
- First four eagerly loaded vehicle PNGs: approximately 6.5 MB.
- Client portal source vehicle images: approximately 49.6 MB.
- Client portal production vehicle images: approximately 49.6 MB.
- Typical vehicle PNG: 1.6–1.9 MB at roughly 1536×1024.

## Enforced budgets

- Each built-in vehicle image: 200 KB maximum WebP.
- Complete built-in vehicle fleet: 3 MB maximum.
- Homepage background: 200 KB maximum WebP.
- Eager vehicle images on `cars.html`: one maximum.
- Client portal JavaScript: 180 KB gzip maximum.
- Admin portal JavaScript: 180 KB gzip maximum.
- Admin vehicle uploads: resized to 1200×900 maximum, target 300 KB, hard limit 450 KB, WebP only.

Run `npm run perf:check` after image or portal changes. The command rebuilds both portals and rejects oversized assets or bundles.
