import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');
const checks = [];
const check = (label, passed) => checks.push({ label, passed: Boolean(passed) });
const includes = (file, text, label) => check(label, read(file).includes(text));

const publicV2Pages = [
  'index.html',
  'requirements.html',
  'agreement.html',
  'contact.html',
  'car-rental-farmington-ct.html',
  'bradley-airport-car-rental.html',
  'luxury-car-rental-connecticut.html',
  'weekly-car-rental-ct.html',
  'privacy-policy.html',
  'terms.html',
  'ftc-disclosure.html',
];

for (const page of publicV2Pages) {
  const source = read(page);
  check(`${page} loads the scoped V2 stylesheet`, source.includes('href="site-v2.css"'));
  check(`${page} opts into the scoped V2 theme`, /<body[^>]*class="[^"]*\bsite-v2\b/.test(source));
  check(`${page} has balanced navigation tags`, count(source, /<nav(?:\s|>)/g) === count(source, /<\/nav>/g));
  check(`${page} includes the olive phone banner`,
    source.includes('class="top-bar"') && source.includes('href="tel:+18605586031"'));
}

const productionCars = read('cars.html');
const wheelbaseBackup = read('cars-wheelbase.html');
const home = read('index.html');
const cars2Html = read('cars-2.html');
const cars2Js = read('cars-2.js');
const cars2Css = read('cars-2.css');
const publicStyles = read('styles.css');
const cleanPromotionCss = publicStyles.slice(
  publicStyles.indexOf('/* ===== CLEAN PUBLIC PROMOTIONS ====='),
  publicStyles.indexOf('/* ===== END CLEAN PUBLIC PROMOTIONS =====')
);
const fleetGalleryData = read('fleet-gallery-data.js');
const productionCards = [...productionCars.matchAll(/class="vehicle-card car-item"/g)].length;
const wheelbaseIds = [...productionCars.matchAll(/data-wheelbase-rental-id="\d+"/g)].length;
const fleetNumbers = [...productionCars.matchAll(/<h3>[^<]*#([A-Z0-9]+)<\/h3>/gi)].map((match) => match[1].toUpperCase());
const jpgGalleryImages = new Set([
  '001-2', '002-1', '002-2', '100-3', '148-1', '157-2',
  '191-1', '191-2', '210-1', '210-2', '225-2', '321-1',
  '451-2', '474-1', '649-2', '656-1', '656-2', '656-3',
]);

check('Production cars page retains every Wheelbase rental id', productionCards === 29 && wheelbaseIds === productionCards);
check('Every production fleet vehicle exposes four supporting gallery files',
  fleetNumbers.length === productionCards
  && fleetNumbers.every((fleet) => Array.from({ length: 4 }, (_, index) => {
    const imageKey = `${fleet}-${index + 1}`;
    const extension = jpgGalleryImages.has(imageKey) ? 'jpg' : 'webp';
    return fs.existsSync(path.join(root, 'assets', 'fleet-2', `${imageKey}.${extension}`));
  }).every(Boolean)));
check('Production cars page still loads the Wheelbase SDK', productionCars.includes('wheelbase-widget.min.js'));
check('Production cars page keeps Wheelbase as the default checkout',
  productionCars.includes('function goToWheelbaseCheckout')
  && productionCars.includes('function continueSelectedCarBooking')
  && productionCars.includes('const WHEELBASE_ACCOUNT_ID = "4960447"'));
check('Production cars page keeps its live Wheelbase availability proxy',
  productionCars.includes('const WHEELBASE_AVAILABILITY_PROXY_URL =')
  && productionCars.includes('data-wheelbase-rental-id='));
check('Production cars page is indexable', productionCars.includes('name="robots" content="index, follow"'));
check('Production cars redesign is isolated to its scoped stylesheet',
  productionCars.includes('href="cars-wheelbase-v2.css"')
  && /<body[^>]*class="[^"]*\bcars-wheelbase-v2\b/.test(productionCars)
  && !productionCars.includes('src="cars-2.js"'));
check('Wheelbase redesign uses the exact olive and organized three-column cards',
  read('cars-wheelbase-v2.css').includes('--fleet-olive: #123d2a')
  && read('cars-wheelbase-v2.css').includes('grid-template-columns: repeat(3, minmax(0, 1fr))')
  && read('cars-wheelbase-v2.css').includes('max-width: none')
  && read('cars-wheelbase-v2.css').includes('padding: 0')
  && read('cars-wheelbase-v2.css').includes('transition: none')
  && read('cars-wheelbase-v2.css').includes('animation: none'));
check('Cars-2 and the standalone landing page include the olive phone banner',
  cars2Html.includes('class="top-bar"')
  && cars2Html.includes('href="tel:+18605586031"')
  && read('landing-page.html').includes('class="phone-banner"')
  && read('landing-page.html').includes('href="tel:+18605586031"'));
check('Public phone banner is visible and uses the exact olive',
  read('site-v2.css').includes('.site-v2 .top-bar')
  && read('site-v2.css').includes('background: var(--v2-olive)')
  && !/\.site-v2 \.top-bar\s*\{\s*display:\s*none/m.test(read('site-v2.css')));
check('Wheelbase backup stays excluded from search indexing',
  wheelbaseBackup.includes('name="robots" content="noindex, nofollow"'));
check('Cars-2 is isolated from Wheelbase checkout', !/wheelbase-widget|wheelbase\.pro\/rentals/i.test(cars2Html + cars2Js));
check('Cars-2 is available for search indexing', !/name="robots"[^>]+noindex/i.test(cars2Html));
check('Cars-2 uses the exact admin-sidebar green', cars2Css.includes('--cars2-olive: #123d2a'));
check('Unavailable vehicles remain strongly red in both fleet experiences',
  cars2Css.includes('.cars2-card-status.unavailable')
  && cars2Css.includes('background: #b4232c')
  && read('cars-wheelbase-v2.css').includes('.availability.availability-unavailable')
  && read('cars-wheelbase-v2.css').includes('background: #b4232c'));
check('Public V2 uses the exact admin-sidebar green', read('site-v2.css').includes('--v2-olive: #123d2a'));
check('Legacy button shimmer has been removed', !read('styles.css').includes('buttonShimmer'));
check('Admin-created promotion popup uses the clean public design',
  cleanPromotionCss.includes('.promo-modal .promo-modal-panel')
  && cleanPromotionCss.includes('border-radius: 16px')
  && cleanPromotionCss.includes('background: #ffffff')
  && cleanPromotionCss.includes('animation: none')
  && cleanPromotionCss.includes('text-shadow: none')
  && !/radial-gradient|linear-gradient/.test(cleanPromotionCss));
check('Admin-created promotion banner uses the clean olive public design',
  cleanPromotionCss.includes('.promo-banner .promo-banner-code')
  && cleanPromotionCss.includes('background: #123d2a')
  && cleanPromotionCss.includes('border-top: 1px solid #cfd9d2')
  && cleanPromotionCss.includes('@media (max-width: 520px)'));
check('Dynamic promotion surfaces retain copy-code and CTA behavior',
  read('script.js').includes('function createPromotionPopup()')
  && read('script.js').includes('function createPromotionBanner()')
  && read('script.js').includes('copyWeekendPromoCode(button)')
  && read('script.js').includes('destination.searchParams.set("promo", promotion.coupon_code)'));
check('Homepage uses the clean logo-free showroom background',
  fs.existsSync(path.join(root, 'assets', 'background-clean.webp'))
  && read('site-v2.css').includes('url("assets/background-clean.webp") center / cover no-repeat'));
check('Homepage hero shadow is explicitly disabled', read('site-v2.css').includes('text-shadow: none !important'));
check('Homepage reservation controls share one exact height', read('site-v2.css').includes('height: 52px') && read('site-v2.css').includes('grid-template-columns: repeat(5, minmax(0, 1fr))'));
check('Homepage reservation form exposes a live trip summary', home.includes('id="bookingSelectionSummary"') && read('script.js').includes('function updateQuickBookingSummary'));
check('Customer time choices use clear half-hour slots without ambiguous midnight', read('script.js').includes('minutes < 24 * 60; minutes += 30'));
check('Homepage features use a balanced two-column grid', /\.site-v2 \.feature-grid\s*\{\s*grid-template-columns: repeat\(2,/m.test(read('site-v2.css')));
check('Homepage reviews use one balanced three-column row', /\.site-v2 \.review-grid\s*\{\s*grid-template-columns: repeat\(3,/m.test(read('site-v2.css')));
check('Homepage removes the childlike explanation-card section', !home.includes('intro-section') && !home.includes('Wheelbase Checkout') && !home.includes('Clear Rental Terms'));
check('Homepage keeps the 860 number in the olive banner only',
  home.includes('class="top-bar"')
  && home.includes('>860-558-6031</a>')
  && !home.includes('class="header-phone"'));
check('Homepage keeps the Contact action in navigation',
  home.includes('data-contact-modal>Contact</a>'));
check('Contact modal retains both business phone numbers',
  read('script.js').includes('959-261-0721')
  && read('script.js').includes('860-558-6031'));
check('Homepage uses the requested section order',
  home.indexOf('vehicles-preview') < home.indexOf('dark-section')
  && home.indexOf('dark-section') < home.indexOf('insurance-section')
  && home.indexOf('insurance-section') < home.indexOf('reviews-section')
  && home.indexOf('reviews-section') < home.indexOf('cta-section'));
check('Homepage shows the 9 AM to midnight operating window', home.includes('9AM–MIDNIGHT'));
check('Homepage structured hours match the 9 AM to midnight window', home.includes('"openingHours": "Mo-Su 09:00-23:59"'));
check('Homepage red statistics have no text shadow', read('site-v2.css').includes('.site-v2 .stats-grid strong') && read('site-v2.css').includes('text-shadow: none !important'));
includes('cars-2.js', 'get_admin_calendar_fleet_availability', 'Cars-2 checks live calendar availability');
includes('cars-2.js', 'create_website_pending_booking', 'Cars-2 creates the database-backed checkout hold');
includes('cars-2.js', 'NO_LONGER_AVAILABLE', 'Cars-2 protects the final availability race');
includes('cars-2.js', 'neq.${TEST_VEHICLE_ID}', 'Cars-2 excludes the internal test vehicle');
includes('cars-2.js', 'portalUrl.searchParams.set("promo", promo)', 'Cars-2 carries promotion codes to checkout');
includes('cars-2.js', 'Array.from({ length: 4 }', 'Cars-2 appends the same four supporting photos as cars.html');
includes('cars-2.js', '].slice(0, 5)', 'Cars-2 caps every gallery at five photos');
includes('cars-2.js', 'data-gallery-direction', 'Cars-2 fleet cards expose previous and next photo controls');
includes('cars-2.js', 'showDetailImage', 'Cars-2 booking preview has an interactive gallery');
includes('cars-2.js', 'vehicleFeatures(vehicle)', 'Cars-2 uses one vehicle-feature source across cards and details');
check('Cars-2 no longer displays the empty feature placeholder', !cars2Js.includes('Vehicle features are being updated.'));
check('Cars-2 is labeled as Supabase at the bottom without a testing banner',
  cars2Html.includes('class="cars2-provider-signature"')
  && cars2Html.includes('>Supabase</p>')
  && !cars2Html.includes('SUPABASE TESTING'));
check('Cars-2 includes the complete public navigation',
  cars2Html.includes('class="site-header cars2-site-navigation"')
  && cars2Html.includes('<nav id="mainNav">')
  && ['index.html', 'cars-2.html', 'requirements.html', 'agreement.html']
    .every((href) => cars2Html.includes(`href="${href}"`))
  && cars2Html.includes('data-contact-modal>Contact</a>')
  && cars2Html.includes('class="nav-cta reserve-btn" href="cars-2.html"'));
check('Cars-2 exposes no other internal database-preview language',
  !/calendar-connected|private preview|admin calendar|supabase testing/i.test(cars2Html));
check('Cars-2 filter controls match the Wheelbase layout',
  cars2Html.includes('id="cars2AvailableOnly"')
  && cars2Html.includes('>All Cars</button>')
  && cars2Html.includes('id="cars2RentalLength"')
  && cars2Css.includes('.cars2-price-filter')
  && cars2Js.includes('state.pricingDays'));
check('Public booking links follow the admin-selected provider',
  read('script.js').includes('get_public_booking_page_setting')
  && read('script.js').includes('function applyBookingPageRouting')
  && read('script.js').includes('window.getActiveBookingPage')
  && home.includes('window.getActiveBookingPage?.()'));
check('Admin supports confirmed immediate and scheduled provider changes',
  read('rentmect-admin-portal/src/main.jsx').includes('Live Booking Page')
  && read('rentmect-admin-portal/src/main.jsx').includes('Switch now')
  && read('rentmect-admin-portal/src/main.jsx').includes('Schedule switch')
  && read('rentmect-admin-portal/src/main.jsx').includes('BookingPageConfirmationModal')
  && read('rentmect-admin-portal/src/main.jsx').includes('schedule_booking_page_switch'));
check('Booking routing migration keeps Wheelbase as the fail-safe default',
  read('supabase/migrations/20260728150000_booking_page_routing.sql').includes("active_provider text not null default 'wheelbase'")
  && read('supabase/migrations/20260728150000_booking_page_routing.sql').includes('get_public_booking_page_setting')
  && read('supabase/migrations/20260728150000_booking_page_routing.sql').includes('p_scheduled_at <= now()'));
check('Wheelbase fleet hero has no inherited red glow or gradient',
  read('cars-wheelbase-v2.css').includes('.cars-wheelbase-v2 .page-hero')
  && read('cars-wheelbase-v2.css').includes('background: transparent'));
check('High-resolution gallery map covers all 29 vehicles and 116 supporting photos',
  [...fleetGalleryData.matchAll(/^\s{2}"[A-Z0-9]+": \[/gm)].length === 29
  && [...fleetGalleryData.matchAll(/c_limit,f_auto,q_auto,w_1200/g)].length === 116);
check('Audi S3 #001 gallery has one showroom image and the original four real views',
  !fleetGalleryData.includes('pdsf7yykt8hr3qgg5wlz')
  && !fleetGalleryData.includes('pdgrbpbp50hnoq3xsqsk')
  && ['fcliz9jq9pytsl6sq8vr', 'rwnq8qemevxjnizmyeis', 'lauiz6s5fz27yindhzmr', 'p8kaiodp2qpk8jysfevy']
    .every((imageId) => fleetGalleryData.includes(imageId)));
check('Public fleet and cars-2 load the high-resolution gallery map',
  productionCars.includes('src="fleet-gallery-data.js"')
  && cars2Html.includes('src="fleet-gallery-data.js"'));
check('Wheelbase and cars-2 fleet pages show the insurance requirement near the top',
  productionCars.includes('class="section insurance-top-notice"')
  && cars2Html.includes('class="cars2-insurance-top-note"'));
check('Wheelbase and cars-2 fleet pages include all four insurance-provider links',
  ['https://bonzah.com/', 'rentalcover.com/', 'withfaye.com/info/rental-car-coverage/', 'capitalone.com/learn-grow/more-than-money/capital-one-rental-car-insurance/']
    .every((link) => productionCars.includes(link) && cars2Html.includes(link)));
check('Cars-2 checkout visibly repeats the insurance requirement',
  cars2Html.includes('class="cars2-checkout-insurance-note"'));
check('Cars-2 insurance reminder intercepts checkout before the hold is created',
  cars2Js.includes('elements.cars2BookVehicle.addEventListener("click", openInsuranceReminder)')
  && cars2Html.includes('I understand — start checkout')
  && cars2Html.includes('id="cars2InsuranceModal"'));
includes('cars-2.html', 'id="cars2GalleryPrevious"', 'Cars-2 booking preview includes a previous-photo control');
includes('cars-2.html', 'id="cars2GalleryNext"', 'Cars-2 booking preview includes a next-photo control');
includes('cars-2.html', 'id="cars2Thumbnails"', 'Cars-2 booking preview includes clickable thumbnails');
includes('cars-2.js', '"Start checkout"', 'Cars-2 booking preview names the checkout handoff clearly');
includes('cars-2.css', '@media (max-width: 960px)', 'Cars-2 includes tablet layout handling');
includes('cars-2.css', '@media (max-width: 440px)', 'Cars-2 includes narrow mobile layout handling');
includes('cars-2.css', '@media (prefers-reduced-motion: reduce)', 'Cars-2 respects reduced-motion preferences');
check('Cars-2 JavaScript has balanced braces', balanced(cars2Js, '{', '}'));
check('Cars-2 stylesheet has balanced braces', balanced(cars2Css.replace(/\/\*[\s\S]*?\*\//g, ''), '{', '}'));
check('Scoped Wheelbase redesign stylesheet has balanced braces',
  balanced(read('cars-wheelbase-v2.css').replace(/\/\*[\s\S]*?\*\//g, ''), '{', '}'));
check('Scoped public stylesheet has balanced braces', balanced(read('site-v2.css').replace(/\/\*[\s\S]*?\*\//g, ''), '{', '}'));
includes('rentmect-admin-portal/src/main.jsx', "value: 'cars-2.html'", 'Promotion Manager can target the preview page');
includes('rentmect-client-portal/src/main.jsx', 'Promotion or discount code', 'Client preview exposes discount code entry');
includes('rentmect-client-portal/src/main.jsx', "get('holdExpires')", 'Client preview restores the cars-2 hold timer');
includes('rentmect-client-portal/src/main.jsx', "cars2BookingHandoff ? 'checkout' : 'details'", 'Cars-2 handoffs bypass the duplicate portal vehicle page');
includes('rentmect-client-portal/src/main.jsx', '<PreviewVehicleGallery vehicle={displayVehicle} compact />', 'Checkout summary carries the interactive five-photo gallery');
includes('rentmect-client-portal/src/main.jsx', 'const features = getVehicleFeatures(displayVehicle);', 'Checkout and preview share the same vehicle features');
includes('rentmect-client-portal/src/main.jsx', 'PUBLIC_FLEET_ASSET_BASE_URL}/fleet-2/${imageKey}.${extension}', 'Portal rebuilds the original supporting gallery images');
includes('rentmect-client-portal/src/main.jsx', "import FLEET_GALLERY_IMAGES from './fleetGalleryImages'", 'Client checkout uses the high-resolution Wheelbase gallery map');
includes('rentmect-client-portal/index.html', 'https://res.cloudinary.com', 'Client security policy allows Wheelbase gallery images');
includes('rentmect-client-portal/src/main.jsx', 'getVehicleImageFallback(vehicle, index)', 'Client gallery falls back instead of showing broken thumbnails');
includes('rentmect-client-portal/src/main.jsx', '<CheckoutExpiredScreen reservationForm={reservationForm} />', 'Expired checkout replaces disabled forms with a restart screen');
includes('rentmect-client-portal/src/main.jsx', 'Choose a vehicle and restart', 'Expired checkout gives customers a clear restart action');
includes('supabase/migrations/20260724193000_bulletproof_rental_lifecycle.sql', 'p.expires_at > now()', 'Expired website holds stop blocking vehicle availability immediately');
includes('supabase/migrations/20260724202000_ensure_rental_lifecycle_cron.sql', "'* * * * *'", 'Expired checkout records are cleaned every minute');

for (const result of checks) {
  console.log(`${result.passed ? 'PASS' : 'FAIL'} ${result.label}`);
}

const failed = checks.filter((result) => !result.passed);
if (failed.length) process.exit(1);

function balanced(source, open, close) {
  let count = 0;
  for (const character of source) {
    if (character === open) count += 1;
    if (character === close) count -= 1;
    if (count < 0) return false;
  }
  return count === 0;
}

function count(source, pattern) {
  return [...source.matchAll(pattern)].length;
}
