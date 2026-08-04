const RENT_ME_CT_ADDRESS = "12 Holmes Circle, Farmington, CT";

let selectedVehicleName = "";
let selectedRentalPeriod = "";
let lastRentalTimeNotice = "";
let quickBookingReturnTimeCustomized = false;

document.addEventListener("DOMContentLoaded", function () {
  document.querySelectorAll(".chatbot-toggle, .chatbot").forEach((element) => element.remove());
  setupBookingPageRouting();
  observeBookingPageLinks();
  setupMobileNavigation();
  setupSitePromotion();
  setupVehicleGalleries();
  loadAdminVehicleImages();
  populateTimeSelects();
  setMinDates();
  loadBookingDatesIntoForm();
  normalizeRentalDateInputs();
  normalizeRentalTimeInputs({ notify: true });
  restoreBookingPreview();
  setupContactModal();
  window.syncVehicleAvailability?.();
});

const SITE_PROMOTIONS_API_URL = "https://gqmiktepthaafupwdmcl.supabase.co/rest/v1/site_promotions";
const SITE_PROMOTIONS_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdxbWlrdGVwdGhhYWZ1cHdkbWNsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc1ODgxNzgsImV4cCI6MjA5MzE2NDE3OH0.dDM6SSAwd03FLWcdOc8OemcFmZ7yOxKsuPq3qpmqoWI";
const SITE_VEHICLES_API_URL = SITE_PROMOTIONS_API_URL.replace(/site_promotions$/, "vehicles");
const BOOKING_PAGE_SETTING_API_URL = SITE_PROMOTIONS_API_URL.replace(
  /rest\/v1\/site_promotions$/,
  "rest/v1/rpc/get_public_booking_page_setting"
);
const BOOKING_PAGE_PATHS = new Set(["cars.html", "cars-2.html"]);
let activeBookingPagePath = "cars.html";
let bookingPageRefreshTimer = 0;
let bookingPagePollingTimer = 0;
let bookingPageLinkObserver = null;

window.getActiveBookingPage = () => activeBookingPagePath;
window.resolveBookingPageUrl = (value) => resolveBookingPageUrl(value);

async function setupBookingPageRouting() {
  try {
    const response = await fetch(BOOKING_PAGE_SETTING_API_URL, {
      method: "POST",
      cache: "no-store",
      headers: {
        apikey: SITE_PROMOTIONS_ANON_KEY,
        Authorization: `Bearer ${SITE_PROMOTIONS_ANON_KEY}`,
        "Content-Type": "application/json",
      },
      body: "{}",
    });
    if (!response.ok) throw new Error(`Booking page setting request failed (${response.status})`);
    const [setting] = await response.json();
    activeBookingPagePath = BOOKING_PAGE_PATHS.has(setting?.page_path) ? setting.page_path : "cars.html";
    applyBookingPageRouting();
    scheduleBookingPageRefresh(setting);
  } catch (error) {
    activeBookingPagePath = "cars.html";
    applyBookingPageRouting();
    console.warn("Using Wheelbase booking-page fallback.", error);
  }
}

function observeBookingPageLinks() {
  if (bookingPageLinkObserver || !document.body) return;
  bookingPageLinkObserver = new MutationObserver((records) => {
    records.forEach((record) => {
      record.addedNodes.forEach((node) => {
        if (node.nodeType === Node.ELEMENT_NODE) applyBookingPageRouting(node);
      });
    });
  });
  bookingPageLinkObserver.observe(document.body, { childList: true, subtree: true });
  if (!bookingPagePollingTimer) {
    bookingPagePollingTimer = window.setInterval(setupBookingPageRouting, 60000);
  }
}

function scheduleBookingPageRefresh(setting) {
  window.clearTimeout(bookingPageRefreshTimer);
  if (!setting?.scheduled_at) return;
  const scheduledAt = new Date(setting.scheduled_at).getTime();
  const serverNow = new Date(setting.server_now || Date.now()).getTime();
  if (!Number.isFinite(scheduledAt) || !Number.isFinite(serverNow)) return;
  const delay = Math.max(250, Math.min(scheduledAt - serverNow + 250, 2147483000));
  bookingPageRefreshTimer = window.setTimeout(setupBookingPageRouting, delay);
}

function applyBookingPageRouting(root = document) {
  document.body?.setAttribute("data-booking-provider", activeBookingPagePath === "cars-2.html" ? "supabase" : "wheelbase");
  const previewLink = document.getElementById("bookingPreviewLink");
  if (previewLink) {
    const previewIsAvailable = activeBookingPagePath === "cars.html";
    previewLink.hidden = !previewIsAvailable;
    previewLink.setAttribute("aria-hidden", String(!previewIsAvailable));
    if (previewIsAvailable) previewLink.setAttribute("href", "cars-2.html");
  }

  const anchors = [];
  if (root.matches?.("a[href]")) anchors.push(root);
  root.querySelectorAll?.("a[href]").forEach((anchor) => anchors.push(anchor));
  anchors.forEach((anchor) => {
    if (anchor.id === "bookingPreviewLink") return;
    const resolved = resolveBookingPageUrl(anchor.getAttribute("href"));
    if (resolved && resolved !== anchor.getAttribute("href")) anchor.setAttribute("href", resolved);
  });
}

function resolveBookingPageUrl(value) {
  const href = String(value || "").trim();
  if (!href) return href;
  try {
    const url = new URL(href, window.location.href);
    const currentPage = url.pathname.split("/").pop()?.toLowerCase();
    if (!BOOKING_PAGE_PATHS.has(currentPage)) return href;
    url.pathname = url.pathname.replace(/[^/]+$/, activeBookingPagePath);
    if (/^[a-z][a-z0-9+.-]*:/i.test(href)) return url.toString();
    if (href.startsWith("/")) return `${url.pathname}${url.search}${url.hash}`;
    return `${activeBookingPagePath}${url.search}${url.hash}`;
  } catch {
    return href;
  }
}

const VEHICLE_GALLERY_JPG_IMAGES = new Set([
  "001-2", "002-1", "002-2", "100-3", "148-1", "157-2",
  "191-1", "191-2", "210-1", "210-2", "225-2", "321-1",
  "451-2", "474-1", "649-2", "656-1", "656-2", "656-3",
]);
const DEFAULT_SITE_PROMOTION = {
  id: "weekend071726",
  updated_at: "2026-07-19T00:00:00-04:00",
  coupon_code: "WEEKEND071726",
  badge_text: "15% OFF",
  offer_value: "15%",
  offer_suffix: "off",
  popup_kicker: "Weekend Special",
  popup_title: "Your weekend ride just got better.",
  popup_body: "Book before midnight Monday and use this discount code at checkout.",
  banner_title: "Weekend special ends Monday at midnight",
  banner_body: "Use code",
  cta_label: "Choose Your Car",
  cta_url: "cars.html",
  fine_print: "Ends at 12:00 AM Tuesday, July 21, 2026 (Eastern)—the end of Monday night. Terms may apply.",
  starts_at: "2026-07-17T00:00:00-04:00",
  ends_at: "2026-07-21T00:00:00-04:00",
  popup_enabled: true,
  banner_enabled: true,
  popup_pages: ["index.html"],
  banner_pages: ["cars.html"],
  active: true,
};
let activeSitePromotion = null;
let activeSitePromotionEnd = null;
let weekendPromoTimer = null;
let weekendPromoBannerObserver = null;
let weekendPromoBannerResizeHandler = null;

async function setupSitePromotion() {
  const currentPage = getCurrentPromotionPage();
  const result = await fetchSitePromotions();
  const candidates = result.ok ? result.promotions : [DEFAULT_SITE_PROMOTION];
  const now = Date.now();
  const promotion = candidates.find((candidate) => promotionTargetsPage(candidate, currentPage, now));

  if (!promotion) {
    removePromotionSurfaces();
    return;
  }

  activeSitePromotion = promotion;
  activeSitePromotionEnd = new Date(promotion.ends_at);
  renderPromotionSurfaces(promotion, currentPage);

  const promoModal = document.getElementById("weekendPromoModal");
  const countdowns = [...document.querySelectorAll("[data-promo-countdown]")];
  const promoSurfaces = [...document.querySelectorAll("[data-promo-surface]")];
  const promotionIsActive = Date.now() < activeSitePromotionEnd.getTime();

  if (!promotionIsActive) {
    promoSurfaces.forEach((surface) => surface.hidden = true);
    if (promoModal) promoModal.remove();
    return;
  }

  if (countdowns.length) {
    updateWeekendPromoCountdown();
    weekendPromoTimer = window.setInterval(updateWeekendPromoCountdown, 1000);
  }

  setupWeekendPromoBannerLayout();

  document.querySelectorAll("[data-promo-copy]").forEach((button) => {
    button.addEventListener("click", () => copyWeekendPromoCode(button));
  });

  if (!promoModal || hasSeenSitePromotion(promotion)) return;

  markSitePromotionSeen(promotion);
  window.setTimeout(() => openWeekendPromoModal(), 350);

  promoModal.querySelectorAll("[data-promo-close]").forEach((trigger) => {
    trigger.addEventListener("click", closeWeekendPromoModal);
  });

  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && promoModal.classList.contains("open")) {
      closeWeekendPromoModal();
    }
  });
}

async function fetchSitePromotions() {
  try {
    const query = new URLSearchParams({
      select: "*",
      active: "eq.true",
      order: "updated_at.desc",
    });
    const response = await fetch(`${SITE_PROMOTIONS_API_URL}?${query}`, {
      cache: "no-store",
      headers: {
        apikey: SITE_PROMOTIONS_ANON_KEY,
        Authorization: `Bearer ${SITE_PROMOTIONS_ANON_KEY}`,
      },
    });
    if (!response.ok) throw new Error(`Promotion request failed (${response.status})`);
    const promotions = await response.json();
    return { ok: true, promotions: Array.isArray(promotions) ? promotions : [] };
  } catch (error) {
    console.warn("Using the built-in promotion because Promotion Manager is unavailable.", error);
    return { ok: false, promotions: [] };
  }
}

async function loadAdminVehicleImages() {
  const vehicleCards = [...document.querySelectorAll(".car-item[data-vehicle-id]")];
  if (!vehicleCards.length) return;

  try {
    const query = new URLSearchParams({ select: "id,image_urls,published" });
    const response = await fetch(`${SITE_VEHICLES_API_URL}?${query}`, {
      headers: {
        apikey: SITE_PROMOTIONS_ANON_KEY,
        Authorization: `Bearer ${SITE_PROMOTIONS_ANON_KEY}`,
      },
    });
    if (!response.ok) throw new Error(`Vehicle image request failed (${response.status})`);

    const vehicles = await response.json();
    const imageByVehicleId = new Map(
      (Array.isArray(vehicles) ? vehicles : [])
        .filter((vehicle) => vehicle?.id && Array.isArray(vehicle.image_urls) && vehicle.image_urls[0])
        .map((vehicle) => [vehicle.id, vehicle.image_urls[0]])
    );
    const publicationByVehicleId = new Map(
      (Array.isArray(vehicles) ? vehicles : [])
        .filter((vehicle) => vehicle?.id)
        .map((vehicle) => [vehicle.id, vehicle.published !== false])
    );

    vehicleCards.forEach((card) => {
      if (publicationByVehicleId.get(card.dataset.vehicleId) === false) {
        card.hidden = true;
        card.setAttribute("aria-hidden", "true");
        return;
      }

      card.hidden = false;
      card.removeAttribute("aria-hidden");
      const customImageUrl = imageByVehicleId.get(card.dataset.vehicleId);
      const image = card.querySelector(".vehicle-image img");
      if (!customImageUrl || !image || image.src === customImageUrl) return;

      const gallery = card.vehicleGallery;
      if (gallery) {
        gallery.images[0] = customImageUrl;
        if (gallery.index === 0) gallery.show(0);
        return;
      }

      image.src = customImageUrl;
    });
  } catch (error) {
    console.warn("Using built-in optimized vehicle pictures because admin pictures are unavailable.", error);
  }
}

function getFleetGalleryImages(fleetNumber) {
  const highResolutionImages = window.RENTMECT_FLEET_GALLERY_IMAGES?.[fleetNumber];
  if (Array.isArray(highResolutionImages) && highResolutionImages.length >= 4) {
    return highResolutionImages.slice(0, 4);
  }
  return Array.from({ length: 4 }, (_, index) => {
    const imageKey = `${fleetNumber}-${index + 1}`;
    const extension = VEHICLE_GALLERY_JPG_IMAGES.has(imageKey) ? "jpg" : "webp";
    return `assets/fleet-2/${imageKey}.${extension}`;
  });
}

function setupVehicleGalleries() {
  document.querySelectorAll(".car-item").forEach((card) => {
    const imageContainer = card.querySelector(".vehicle-image");
    const image = imageContainer?.querySelector("img");
    const vehicleName = card.querySelector("h3")?.textContent.trim() || "Vehicle";
    const fleetNumber = vehicleName.match(/#([a-z0-9]+)/i)?.[1]?.toUpperCase();
    if (!imageContainer || !image || !fleetNumber) return;

    const images = [image.currentSrc || image.src, ...getFleetGalleryImages(fleetNumber)];
    const originalAlt = image.alt;
    const counter = document.createElement("span");
    const previousButton = document.createElement("button");
    const nextButton = document.createElement("button");

    counter.className = "vehicle-gallery-counter";
    counter.setAttribute("aria-live", "polite");
    previousButton.className = "vehicle-gallery-arrow vehicle-gallery-previous";
    nextButton.className = "vehicle-gallery-arrow vehicle-gallery-next";
    previousButton.type = "button";
    nextButton.type = "button";
    previousButton.setAttribute("aria-label", `Show previous photo of ${vehicleName}`);
    nextButton.setAttribute("aria-label", `Show next photo of ${vehicleName}`);
    previousButton.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M15 18 9 12l6-6" /></svg>';
    nextButton.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="m9 18 6-6-6-6" /></svg>';

    const gallery = {
      images,
      index: 0,
      show(index) {
        this.index = (index + this.images.length) % this.images.length;
        image.src = this.images[this.index];
        image.alt = `${originalAlt} — photo ${this.index + 1} of ${this.images.length}`;
        counter.textContent = `${this.index + 1} / ${this.images.length}`;
      },
    };

    previousButton.addEventListener("click", () => gallery.show(gallery.index - 1));
    nextButton.addEventListener("click", () => gallery.show(gallery.index + 1));
    imageContainer.append(previousButton, nextButton, counter);
    card.vehicleGallery = gallery;
    gallery.show(0);
  });
}

function getCurrentPromotionPage() {
  const fileName = window.location.pathname.split("/").pop();
  return fileName || "index.html";
}

function promotionTargetsPage(promotion, page, now = Date.now()) {
  if (!promotion?.active) return false;
  const startsAt = promotion.starts_at ? new Date(promotion.starts_at).getTime() : Number.NEGATIVE_INFINITY;
  const endsAt = new Date(promotion.ends_at).getTime();
  if (!Number.isFinite(endsAt) || now < startsAt || now >= endsAt) return false;
  const popupMatches = promotion.popup_enabled && promotion.popup_pages?.includes(page);
  const bannerMatches = promotion.banner_enabled && promotion.banner_pages?.includes(page);
  return Boolean(popupMatches || bannerMatches);
}

function renderPromotionSurfaces(promotion, page) {
  const showPopup = Boolean(promotion.popup_enabled && promotion.popup_pages?.includes(page));
  const showBanner = Boolean(promotion.banner_enabled && promotion.banner_pages?.includes(page));
  const existingPopup = document.getElementById("weekendPromoModal");
  const existingBanner = document.querySelector(".promo-banner");

  if (showPopup) hydratePromotionPopup(existingPopup || createPromotionPopup(), promotion);
  else existingPopup?.remove();

  if (showBanner) hydratePromotionBanner(existingBanner || createPromotionBanner(), promotion);
  else if (existingBanner) existingBanner.hidden = true;
}

function createPromotionPopup() {
  const modal = document.createElement("div");
  modal.className = "promo-modal";
  modal.id = "weekendPromoModal";
  modal.setAttribute("aria-hidden", "true");
  modal.setAttribute("role", "dialog");
  modal.setAttribute("aria-modal", "true");
  modal.setAttribute("aria-labelledby", "weekendPromoTitle");
  modal.innerHTML = `
    <div class="promo-modal-backdrop" data-promo-close></div>
    <div class="promo-modal-panel">
      <button class="promo-modal-close" type="button" data-promo-close aria-label="Close promotion">×</button>
      <p class="promo-kicker" data-promo-kicker></p>
      <p class="promo-discount"><strong data-promo-offer></strong> <span data-promo-offer-suffix></span></p>
      <h2 id="weekendPromoTitle" data-promo-popup-title></h2>
      <p class="promo-copy" data-promo-popup-body></p>
      <button class="promo-code" type="button" data-promo-copy>
        <span>Discount code</span>
        <strong data-promo-code></strong>
        <small data-promo-copy-label>Tap to copy</small>
      </button>
      <div class="promo-countdown-wrap">
        <p>Offer ends in</p>
        <div class="promo-countdown" data-promo-countdown aria-label="Time remaining in promotion"></div>
      </div>
      <a class="promo-cta" data-promo-cta><span data-promo-cta-label></span> <span aria-hidden="true">→</span></a>
      <p class="promo-fine-print" data-promo-fine-print></p>
    </div>`;
  document.body.appendChild(modal);
  return modal;
}

function createPromotionBanner() {
  const banner = document.createElement("aside");
  banner.className = "promo-banner";
  banner.dataset.promoSurface = "banner";
  banner.setAttribute("aria-label", "Current promotion");
  banner.innerHTML = `
    <div class="promo-banner-main">
      <span class="promo-banner-badge" data-promo-badge></span>
      <div><strong data-promo-banner-title></strong><span data-promo-banner-body></span></div>
      <button class="promo-banner-code" type="button" data-promo-copy>
        <span data-promo-code></span>
        <small data-promo-copy-label>Copy</small>
      </button>
    </div>
    <div class="promo-banner-timer">
      <span>Time left</span>
      <div class="promo-countdown promo-countdown-compact" data-promo-countdown aria-label="Time remaining in promotion"></div>
    </div>`;
  const header = document.querySelector("header");
  if (header) header.insertAdjacentElement("afterend", banner);
  else document.body.prepend(banner);
  return banner;
}

function hydratePromotionPopup(modal, promotion) {
  setPromotionText(modal, "[data-promo-kicker]", promotion.popup_kicker);
  setPromotionText(modal, "[data-promo-offer]", promotion.offer_value);
  setPromotionText(modal, "[data-promo-offer-suffix]", promotion.offer_suffix);
  setPromotionText(modal, "[data-promo-popup-title]", promotion.popup_title);
  setPromotionText(modal, "[data-promo-popup-body]", promotion.popup_body);
  setPromotionText(modal, "[data-promo-code]", promotion.coupon_code);
  setPromotionText(modal, "[data-promo-cta-label]", promotion.cta_label);
  setPromotionText(modal, "[data-promo-fine-print]", promotion.fine_print || formatPromotionEnd(promotion.ends_at));
  const copyButton = modal.querySelector("[data-promo-copy]");
  copyButton.dataset.promoCopy = promotion.coupon_code;
  copyButton.setAttribute("aria-label", `Copy discount code ${promotion.coupon_code}`);
  const cta = modal.querySelector("[data-promo-cta]");
  const destination = new URL(resolveBookingPageUrl(safePromotionUrl(promotion.cta_url)), window.location.href);
  if (promotion.coupon_code) destination.searchParams.set("promo", promotion.coupon_code);
  cta.href = destination.toString();
}

function hydratePromotionBanner(banner, promotion) {
  banner.hidden = false;
  setPromotionText(banner, "[data-promo-badge]", promotion.badge_text);
  setPromotionText(banner, "[data-promo-banner-title]", promotion.banner_title);
  setPromotionText(banner, "[data-promo-banner-body]", promotion.banner_body);
  setPromotionText(banner, "[data-promo-code]", promotion.coupon_code);
  const copyButton = banner.querySelector("[data-promo-copy]");
  copyButton.dataset.promoCopy = promotion.coupon_code;
  copyButton.setAttribute("aria-label", `Copy discount code ${promotion.coupon_code}`);
}

function setPromotionText(container, selector, value) {
  const element = container.querySelector(selector);
  if (element) element.textContent = value || "";
}

function safePromotionUrl(value) {
  const url = String(value || "cars.html").trim();
  return /^(?:https?:\/\/|\/|\.\/|\.\.\/|[a-z0-9][a-z0-9._/-]*\.html(?:[?#].*)?$)/i.test(url) ? url : "cars.html";
}

function formatPromotionEnd(value) {
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return "Terms may apply.";
  return `Ends ${new Intl.DateTimeFormat("en-US", { dateStyle: "long", timeStyle: "short", timeZone: "America/New_York" }).format(date)} Eastern. Terms may apply.`;
}

function promotionSeenKey(promotion) {
  const version = String(promotion.updated_at || promotion.ends_at || "").replace(/[^a-z0-9]/gi, "");
  return `rentmect_promotion_${promotion.id || promotion.coupon_code}_${version}_seen`;
}

function hasSeenSitePromotion(promotion) {
  try {
    return localStorage.getItem(promotionSeenKey(promotion)) === "true";
  } catch {
    return false;
  }
}

function markSitePromotionSeen(promotion) {
  try {
    localStorage.setItem(promotionSeenKey(promotion), "true");
  } catch {
    // The promotion still works when storage is unavailable.
  }
}

function openWeekendPromoModal() {
  const modal = document.getElementById("weekendPromoModal");
  if (!modal || !activeSitePromotionEnd || Date.now() >= activeSitePromotionEnd.getTime()) return;

  modal.classList.add("open");
  modal.setAttribute("aria-hidden", "false");
  document.body.classList.add("promo-modal-open");
  modal.querySelector(".promo-modal-close")?.focus();
}

function closeWeekendPromoModal() {
  const modal = document.getElementById("weekendPromoModal");
  if (!modal) return;

  modal.classList.remove("open");
  modal.setAttribute("aria-hidden", "true");
  document.body.classList.remove("promo-modal-open");
}

function updateWeekendPromoCountdown() {
  const remaining = activeSitePromotionEnd?.getTime() - Date.now();

  if (!Number.isFinite(remaining) || remaining <= 0) {
    window.clearInterval(weekendPromoTimer);
    removePromotionSurfaces();
    return;
  }

  const totalSeconds = Math.floor(remaining / 1000);
  const values = [
    [Math.floor(totalSeconds / 86400), "Days"],
    [Math.floor((totalSeconds % 86400) / 3600), "Hrs"],
    [Math.floor((totalSeconds % 3600) / 60), "Min"],
    [totalSeconds % 60, "Sec"]
  ];

  document.querySelectorAll("[data-promo-countdown]").forEach((countdown) => {
    countdown.innerHTML = values.map(([value, label]) => `
      <span class="promo-time-unit"><strong>${String(value).padStart(2, "0")}</strong><small>${label}</small></span>
    `).join("");
  });
}

function removePromotionSurfaces() {
  document.querySelectorAll("[data-promo-surface]").forEach((surface) => surface.hidden = true);
  teardownWeekendPromoBannerLayout();
  closeWeekendPromoModal();
  document.getElementById("weekendPromoModal")?.remove();
}

function setupWeekendPromoBannerLayout() {
  const banner = document.querySelector(".promo-banner:not([hidden])");
  if (!banner) return;

  const syncBannerHeight = () => {
    document.body.style.setProperty("--promo-banner-height", `${Math.ceil(banner.getBoundingClientRect().height)}px`);
  };

  document.body.classList.add("promo-banner-active");
  syncBannerHeight();

  if ("ResizeObserver" in window) {
    weekendPromoBannerObserver = new ResizeObserver(syncBannerHeight);
    weekendPromoBannerObserver.observe(banner);
  } else {
    weekendPromoBannerResizeHandler = syncBannerHeight;
    window.addEventListener("resize", weekendPromoBannerResizeHandler);
  }
}

function teardownWeekendPromoBannerLayout() {
  weekendPromoBannerObserver?.disconnect();
  weekendPromoBannerObserver = null;
  if (weekendPromoBannerResizeHandler) {
    window.removeEventListener("resize", weekendPromoBannerResizeHandler);
    weekendPromoBannerResizeHandler = null;
  }
  document.body.classList.remove("promo-banner-active");
  document.body.style.removeProperty("--promo-banner-height");
}

async function copyWeekendPromoCode(button) {
  const code = button.dataset.promoCopy || activeSitePromotion?.coupon_code || "";
  const label = button.querySelector("[data-promo-copy-label]");

  try {
    await navigator.clipboard.writeText(code);
    if (label) label.textContent = "Copied!";
  } catch {
    if (label) label.textContent = code;
  }

  window.setTimeout(() => {
    if (label) label.textContent = button.classList.contains("promo-banner-code") ? "Copy" : "Tap to copy";
  }, 1800);
}

function toggleMenu() {
  const nav = document.getElementById("mainNav");
  if (!nav) return;

  const isOpen = nav.classList.toggle("open");
  const button = document.querySelector(".mobile-menu-btn");
  if (button) {
    button.setAttribute("aria-expanded", String(isOpen));
    button.setAttribute("aria-label", isOpen ? "Close navigation" : "Open navigation");
  }
}

function setupMobileNavigation() {
  const nav = document.getElementById("mainNav");
  const button = document.querySelector(".mobile-menu-btn");
  if (!nav || !button) return;

  button.setAttribute("aria-controls", "mainNav");
  button.setAttribute("aria-expanded", String(nav.classList.contains("open")));
  button.setAttribute("aria-label", nav.classList.contains("open") ? "Close navigation" : "Open navigation");

  nav.querySelectorAll("a").forEach((link) => {
    link.addEventListener("click", () => {
      nav.classList.remove("open");
      button.setAttribute("aria-expanded", "false");
      button.setAttribute("aria-label", "Open navigation");
    });
  });
}

function setupContactModal() {
  if (!document.getElementById("contactModal")) {
    const modal = document.createElement("div");
    modal.className = "contact-modal";
    modal.id = "contactModal";
    modal.setAttribute("aria-hidden", "true");
    modal.setAttribute("role", "dialog");
    modal.setAttribute("aria-modal", "true");
    modal.setAttribute("aria-labelledby", "contactModalTitle");
    modal.innerHTML = `
      <div class="contact-modal-backdrop" data-contact-close></div>
      <div class="contact-modal-panel">
        <button class="contact-modal-close" type="button" data-contact-close aria-label="Close contact popup">×</button>
        <p class="eyebrow">Contact</p>
        <h2 id="contactModalTitle">Call Rent Me CT</h2>
        <div class="contact-number-list">
          <div class="contact-number-row">
            <div>
              <span>Office Cell</span>
              <strong>959-261-0721</strong>
            </div>
            <a class="btn-primary" href="tel:+19592610721">Call Office</a>
          </div>
          <div class="contact-number-row">
            <div>
              <span>Services Cell</span>
              <strong>860-558-6031</strong>
            </div>
            <a class="btn-primary" href="tel:+18605586031">Call Services</a>
          </div>
        </div>
      </div>
    `;
    document.body.appendChild(modal);
  }

  document.querySelectorAll('.site-footer a[href^="tel:"], a[data-contact-modal]').forEach((link) => {
    link.setAttribute("data-contact-modal", "");
  });

  document.addEventListener("click", function (event) {
    const closeTrigger = event.target.closest("[data-contact-close]");
    if (closeTrigger) {
      closeContactModal();
      return;
    }

    const contactLink = event.target.closest("a[data-contact-modal]");
    if (!contactLink) return;

    event.preventDefault();
    openContactModal();
  });

  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape") closeContactModal();
  });
}

function openContactModal() {
  const modal = document.getElementById("contactModal");
  if (!modal) return;
  modal.classList.add("open");
  modal.setAttribute("aria-hidden", "false");
}

function closeContactModal() {
  const modal = document.getElementById("contactModal");
  if (!modal) return;
  modal.classList.remove("open");
  modal.setAttribute("aria-hidden", "true");
}

function populateTimeSelects() {
  const pickup = document.getElementById("pickupTime");
  const dropoff = document.getElementById("returnTime");

  if (!pickup || !dropoff) return;

  const currentPickupValue = pickup.value;
  const currentReturnValue = dropoff.value;
  const times = getRentalTimeOptions();

  [pickup, dropoff].forEach((select) => {
    select.innerHTML = "";
    times.forEach((time) => {
      const option = document.createElement("option");
      option.value = time;
      option.textContent = time;
      select.appendChild(option);
    });
  });

  pickup.value = currentPickupValue || "9:00 AM";
  dropoff.value = currentReturnValue || "9:00 AM";
  normalizeRentalTimeInputs();
}

function getRentalTimeOptions() {
  const times = [];
  for (let minutes = 9 * 60; minutes < 24 * 60; minutes += 30) {
    const hour = Math.floor(minutes / 60);
    const minute = minutes % 60;
    const suffix = hour >= 12 && hour < 24 ? "PM" : "AM";
    const displayHour = hour % 12 || 12;
    times.push(`${displayHour}:${String(minute).padStart(2, "0")} ${suffix}`);
  }
  return times;
}

function getRentalDateTime(dateValue, timeLabel) {
  const match = String(timeLabel || "").trim().match(/^(\d{1,2})(?::(\d{2}))?\s*(AM|PM)$/i);
  if (!dateValue || !match) return null;

  let hours = Number(match[1]);
  const minutes = Number(match[2] || 0);
  const period = match[3].toUpperCase();

  if (period === "AM" && hours === 12) hours = 0;
  if (period === "PM" && hours !== 12) hours += 12;

  return new Date(`${dateValue}T${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}:00`);
}

function getFirstFutureRentalTime(dateValue) {
  const now = new Date();
  return getRentalTimeOptions().find((time) => {
    const dateTime = getRentalDateTime(dateValue, time);
    return dateTime && dateTime > now;
  }) || "";
}

function setRentalTimeNotice(message) {
  const note = document.querySelector("#bookingPanel .booking-note");
  if (note && message) note.textContent = message;
}

function notifyRentalTimeAdjusted(message, noticeKey) {
  setRentalTimeNotice(message);
  updateQuickBookingSummary(message, "valid");
  if (!noticeKey || lastRentalTimeNotice === noticeKey) return;

  lastRentalTimeNotice = noticeKey;
}

function normalizeRentalTimeInputs(options = {}) {
  const shouldNotify = Boolean(options.notify);
  const pickupDate = document.getElementById("pickupDate");
  const returnDate = document.getElementById("returnDate");
  const pickupTime = document.getElementById("pickupTime");
  const returnTime = document.getElementById("returnTime");

  if (!pickupDate || !returnDate || !pickupTime || !returnTime) return;

  const today = getLocalDateInputValue();
  let timeWasAdjusted = false;
  if (pickupDate.value === today) {
    const nextTime = getFirstFutureRentalTime(today);

    if (!nextTime) {
      const nextPickupDate = getNextDateInputValue(today);
      pickupDate.value = getNextDateInputValue(today);
      returnDate.min = getNextDateInputValue(pickupDate.value);
      if (returnDate.value < returnDate.min) returnDate.value = returnDate.min;
      pickupTime.value = "9:00 AM";
      if (shouldNotify) {
        timeWasAdjusted = true;
        notifyRentalTimeAdjusted(
          "Pickup is closed for today, so we moved your pickup to tomorrow at 9:00 AM.",
          `closed-${nextPickupDate}`
        );
      }
    } else {
      const selectedPickup = getRentalDateTime(today, pickupTime.value);
      if (!selectedPickup || selectedPickup <= new Date()) {
        pickupTime.value = nextTime;
        if (shouldNotify) {
          timeWasAdjusted = true;
          notifyRentalTimeAdjusted(
            `That pickup time has passed, so we moved pickup to ${nextTime}.`,
            `time-${today}-${nextTime}`
          );
        }
      }
    }
  }

  if (!returnTime.value) returnTime.value = pickupTime.value || "9:00 AM";
  if (!quickBookingReturnTimeCustomized && pickupTime.value) {
    returnTime.value = pickupTime.value;
  }
  updatePickupTimeAvailability();
  if (!timeWasAdjusted) updateQuickBookingSummary();
  window.syncVehicleAvailability?.();
}

function updatePickupTimeAvailability() {
  const pickupDate = document.getElementById("pickupDate");
  const pickupTime = document.getElementById("pickupTime");
  if (!pickupDate || !pickupTime) return;

  const now = new Date();
  const today = getLocalDateInputValue(now);
  [...pickupTime.options].forEach((option) => {
    const optionDateTime = getRentalDateTime(pickupDate.value, option.value);
    option.disabled = pickupDate.value === today && Boolean(optionDateTime && optionDateTime <= now);
  });
}

function updateQuickBookingSummary(message = "", state = "") {
  const summary = document.getElementById("bookingSelectionSummary");
  if (!summary) return;

  summary.classList.remove("valid", "error");
  if (message) {
    summary.textContent = message;
    if (state) summary.classList.add(state);
    return;
  }

  const pickupDate = document.getElementById("pickupDate")?.value;
  const returnDate = document.getElementById("returnDate")?.value;
  const pickupTime = document.getElementById("pickupTime")?.value;
  const returnTime = document.getElementById("returnTime")?.value;
  const pickup = getRentalDateTime(pickupDate, pickupTime);
  const dropoff = getRentalDateTime(returnDate, returnTime);

  if (!pickup || !dropoff) {
    summary.textContent = "Choose your pickup and return once—we’ll carry them into the available fleet.";
    return;
  }
  if (dropoff <= pickup) {
    summary.textContent = "Return must be after pickup.";
    summary.classList.add("error");
    return;
  }

  const rentalDays = Math.max(1, Math.ceil((new Date(`${returnDate}T12:00:00`) - new Date(`${pickupDate}T12:00:00`)) / 86400000));
  const shortDate = (value) => new Date(`${value}T12:00:00`).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
  });
  summary.textContent = `${rentalDays} rental day${rentalDays === 1 ? "" : "s"} · ${shortDate(pickupDate)} at ${pickupTime} → ${shortDate(returnDate)} at ${returnTime}`;
  summary.classList.add("valid");
}

function checkFleetAvailability(event) {
  event?.preventDefault();

  const pickupDate = document.getElementById("pickupDate")?.value;
  const returnDate = document.getElementById("returnDate")?.value;
  const pickupTime = document.getElementById("pickupTime")?.value;
  const returnTime = document.getElementById("returnTime")?.value;
  const pickup = getRentalDateTime(pickupDate, pickupTime);
  const dropoff = getRentalDateTime(returnDate, returnTime);

  if (!pickup || !dropoff) {
    updateQuickBookingSummary("Choose all four date and time fields.", "error");
    return;
  }
  if (dropoff <= pickup) {
    updateQuickBookingSummary("Return must be after pickup.", "error");
    return;
  }
  if (pickup <= new Date()) {
    updateQuickBookingSummary("Pickup must be later than the current time.", "error");
    normalizeRentalTimeInputs({ notify: true });
    return;
  }

  updateQuickBookingSummary();
  window.syncVehicleAvailability?.();
  document.getElementById("availabilityFilterStatus")?.scrollIntoView({ behavior: "smooth", block: "center" });
}

function setMinDates() {
  const today = getLocalDateInputValue();

  const pickup = document.getElementById("pickupDate");
  const dropoff = document.getElementById("returnDate");

  if (pickup) pickup.min = today;
  if (dropoff) dropoff.min = getNextDateInputValue(today);

  pickup?.addEventListener("change", () => {
    normalizeRentalDateInputs();
    normalizeRentalTimeInputs({ notify: true });
    window.syncVehicleAvailability?.();
  });

  dropoff?.addEventListener("change", () => {
    normalizeRentalDateInputs();
    normalizeRentalTimeInputs({ notify: true });
    window.syncVehicleAvailability?.();
  });

  document.getElementById("pickupTime")?.addEventListener("change", () => {
    const returnTime = document.getElementById("returnTime");
    if (document.querySelector("[data-booking-widget]") && returnTime && !quickBookingReturnTimeCustomized) {
      returnTime.value = document.getElementById("pickupTime").value;
    }
    normalizeRentalTimeInputs({ notify: true });
  });
  document.getElementById("returnTime")?.addEventListener("change", () => {
    if (document.querySelector("[data-booking-widget]")) quickBookingReturnTimeCustomized = true;
    normalizeRentalTimeInputs({ notify: true });
  });

  window.setInterval(() => {
    if (document.visibilityState !== "hidden") normalizeRentalTimeInputs({ notify: true });
  }, 60000);

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") normalizeRentalTimeInputs({ notify: true });
  });
}

function getLocalDateInputValue(date = new Date()) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function getNextDateInputValue(value) {
  const date = new Date(`${value}T00:00:00`);
  date.setDate(date.getDate() + 1);
  return getLocalDateInputValue(date);
}

function normalizeRentalDateInputs() {
  const pickup = document.getElementById("pickupDate");
  const dropoff = document.getElementById("returnDate");
  if (!pickup || !dropoff) return;

  const today = getLocalDateInputValue();
  const datesAreOptional = document.getElementById("bookingPanel")?.dataset.optionalDates === "true";

  pickup.min = today;
  if (datesAreOptional) {
    if (pickup.value) {
      dropoff.min = getNextDateInputValue(pickup.value);
      if (dropoff.value && dropoff.value < dropoff.min) dropoff.value = "";
    } else {
      dropoff.min = getNextDateInputValue(today);
    }
    normalizeRentalTimeInputs();
    return;
  }

  const defaultReturn = getNextDateInputValue(today);

  if (!pickup.value || pickup.value < today) pickup.value = today;

  const minReturn = getNextDateInputValue(pickup.value);
  dropoff.min = minReturn;

  if (!dropoff.value || dropoff.value < minReturn) {
    dropoff.value = pickup.value === today ? defaultReturn : minReturn;
  }

  normalizeRentalTimeInputs();
}

function loadBookingDatesIntoForm() {
  let bookingData = {};

  const saved =
    localStorage.getItem("rentmect_pending_booking") ||
    localStorage.getItem("rentMeCtBooking") ||
    localStorage.getItem("pendingBooking");

  try {
    bookingData = saved ? JSON.parse(saved) : {};
  } catch {
    bookingData = {};
  }

  const params = new URLSearchParams(window.location.search);

  const pickupDate = params.get("pickupDate") || bookingData.pickupDate || bookingData.pickup_date || "";
  const returnDate = params.get("returnDate") || bookingData.returnDate || bookingData.return_date || "";
  const formDefaultTime = document.querySelector("[data-booking-widget]")?.dataset.defaultTime || "";
  const requestedPickupTime = params.get("pickupTime");
  const requestedReturnTime = params.get("returnTime");
  const savedPickupTime = bookingData.pickupTime || bookingData.pickup_time || "";
  const savedReturnTime = bookingData.returnTime || bookingData.return_time || "";
  const pickupTime = requestedPickupTime || savedPickupTime || formDefaultTime || "9:00 AM";
  const returnTime = requestedReturnTime || savedReturnTime || pickupTime;

  quickBookingReturnTimeCustomized =
    params.get("returnTimeCustomized") === "1"
    || bookingData.returnTimeCustomized === true
    || Boolean(requestedReturnTime && requestedReturnTime !== pickupTime)
    || Boolean(!requestedReturnTime && savedReturnTime && savedReturnTime !== pickupTime);

  const pickupInput = document.getElementById("pickupDate");
  const returnInput = document.getElementById("returnDate");
  const pickupSelect = document.getElementById("pickupTime");
  const returnSelect = document.getElementById("returnTime");

  if (pickupInput && pickupDate) pickupInput.value = pickupDate;
  if (returnInput && returnDate) returnInput.value = returnDate;
  if (pickupSelect && pickupTime) pickupSelect.value = decodeURIComponent(pickupTime).replace("%3A", ":");
  if (returnSelect && returnTime) returnSelect.value = decodeURIComponent(returnTime).replace("%3A", ":");
}

function startBooking(event) {
  event.preventDefault();

  const pickupDate = document.getElementById("pickupDate")?.value;
  const returnDate = document.getElementById("returnDate")?.value;
  const pickupTime = document.getElementById("pickupTime")?.value;
  const returnTime = document.getElementById("returnTime")?.value;

  if (!pickupDate || !returnDate || !pickupTime || !returnTime) {
    alert("Please choose pickup and return date/time.");
    return;
  }

  const pickup = getRentalDateTime(pickupDate, pickupTime);
  const dropoff = getRentalDateTime(returnDate, returnTime);

  if (!pickup || !dropoff || dropoff <= pickup) {
    alert("Please choose a return date after pickup.");
    return;
  }

  if (pickup <= new Date()) {
    alert("Please choose a pickup time later than the current time.");
    normalizeRentalTimeInputs();
    return;
  }

  selectedRentalPeriod = `${formatDate(pickupDate)} ${pickupTime} - ${formatDate(returnDate)} ${returnTime}`;

  const existingVehicle = selectedVehicleName || localStorage.getItem("rentmect_vehicle") || "";

  const bookingData = {
    pickupDate,
    returnDate,
    pickupTime,
    returnTime,
    returnTimeCustomized: quickBookingReturnTimeCustomized,
    selectedVehicle: existingVehicle
  };

  localStorage.setItem("rentmect_period", selectedRentalPeriod);
  localStorage.setItem("rentmect_pending_booking", JSON.stringify(bookingData));

  const selectedPeriod = document.getElementById("selectedPeriod");
  if (selectedPeriod) selectedPeriod.textContent = selectedRentalPeriod;

  window.syncVehicleAvailability?.();
}

function formatDate(value) {
  const date = new Date(`${value}T00:00:00`);
  return date.toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric"
  });
}

function filterCars(filter, button) {
  const cars = document.querySelectorAll(".car-item");
  const buttons = document.querySelectorAll(".filter-btn");

  buttons.forEach((btn) => btn.classList.remove("active"));
  if (button) button.classList.add("active");

  cars.forEach((car) => {
    const brand = car.dataset.brand || "";
    const type = car.dataset.type || "";

    if (filter === "all" || brand.includes(filter) || type.includes(filter)) {
      car.style.display = "block";
    } else {
      car.style.display = "none";
    }
  });
}

function restoreBookingPreview() {
  const savedVehicle = localStorage.getItem("rentmect_vehicle");
  const savedPeriod = localStorage.getItem("rentmect_period");

  const selectedVehicle = document.getElementById("selectedVehicle");
  const selectedPeriod = document.getElementById("selectedPeriod");

  if (savedVehicle && selectedVehicle) selectedVehicle.textContent = savedVehicle;
  if (savedPeriod && selectedPeriod) selectedPeriod.textContent = savedPeriod;
}

function toggleChatbot() {
  const chatbot = document.getElementById("chatbot");
  if (chatbot) chatbot.classList.toggle("open");
}

const RENT_ME_CT_CHATBOT_TOPICS = [
  {
    keywords: ["insurance", "insured", "coverage", "declaration", "policy", "own insurance", "wheelbase insurance"],
    response: "Yes, every renter must have valid insurance before pickup. You can bring your own active auto insurance, review the third-party coverage options on our site, or choose available Wheelbase insurance during checkout. If you opt out of Wheelbase insurance, have your insurance declaration page ready for review."
  },
  {
    keywords: ["deposit", "security deposit", "hold", "refundable", "200", "2000"],
    response: "A security deposit is required and varies by vehicle class, rental risk, damage, cleaning needs, policy violations, and other contract issues. Deposits and post-rental charges may range from $200 to $2,000 depending on the rental."
  },
  {
    keywords: ["drop off", "drop-off", "dropoff", "delivery", "deliver", "pickup service", "pick up service", "transportation", "bring the car", "come to me"],
    response: "Pickup and drop-off services may be offered only when Rent Me CT approves them. Local pickup or return transportation within 15 miles may carry a $30 fee each way. Call or text 860-558-6031 to confirm whether it is available for your rental."
  },
  {
    keywords: ["pickup", "pick up", "return", "address", "location", "where are you", "where located", "hours", "open", "time window"],
    response: "Rent Me CT pickup and return are based at 12 Holmes Circle, Farmington, CT. Pickup and return times are available from 9 AM to midnight unless another arrangement is approved."
  },
  {
    keywords: ["license", "driver license", "driver's license", "drivers license", "documents", "paperwork", "what do i need", "requirements", "required"],
    response: "To rent, you need to be at least 21, have a valid unexpired driver's license, provide proof of active auto insurance, provide billing/contact information, and sign the rental agreement and addendum. A driver's license photo upload may be required."
  },
  {
    keywords: ["age", "old", "21", "under 25", "young driver", "younger"],
    response: "Renters must be at least 21 years old. Renters under 25 may be subject to a young driver fee. Only approved drivers listed on the rental may operate the vehicle."
  },
  {
    keywords: ["miles", "mileage", "extra miles", "unlimited", "per mile", "200 miles"],
    response: "Rentals include 200 miles per day. Extra mileage is billed at $0.35 per mile unless another mileage option is purchased or agreed to."
  },
  {
    keywords: ["late", "late return", "return late", "after return", "4 hours", "miss return"],
    response: "Vehicles must be returned by the scheduled date and time. If a vehicle is not returned within 4 hours of the scheduled return time without approval, the renter may be charged one additional rental day plus a $25 late fee. Recovery, towing, storage, transportation, and administrative fees may also apply."
  },
  {
    keywords: ["damage", "accident", "crash", "collision", "scratch", "dent", "theft", "stolen", "police"],
    response: "Renters are responsible for vehicle damage during the rental period, regardless of fault, including damage, theft, vandalism, loss of use, towing, storage, and administrative fees. Any accident, collision, theft, or damage must be reported to Rent Me CT immediately, and a police report may be required."
  },
  {
    keywords: ["smoke", "smoking", "weed", "cigarette", "vape", "odor", "cleaning", "pet hair", "dirty", "trash"],
    response: "Smoking is not allowed in any vehicle. Vehicles must be returned reasonably clean. Smoke residue, strong odors, stains, trash, pet hair, sand, bodily fluids, or abnormal cleaning needs may lead to cleaning or remediation fees. Smoking remediation may range from $200 to $2,000."
  },
  {
    keywords: ["toll", "tolls", "ticket", "tickets", "parking", "violation", "citation", "ez pass", "e-zpass"],
    response: "Renters are responsible for tolls, parking tickets, traffic violations, and related administrative fees during the rental period. Rent Me CT may transfer liability or charge the renter directly."
  },
  {
    keywords: ["gps", "tracker", "tracking", "telematics", "speed", "90", "disable", "disabled"],
    response: "Vehicles may include GPS and telematics for theft prevention, recovery, speed monitoring, diagnostics, and driving behavior. Speeds over 90 mph are not permitted, and reckless driving may lead to warnings, remote disabling where legally permitted and safe, and reactivation fees."
  },
  {
    keywords: ["fuel", "gas", "refuel", "gas level", "premium", "tank"],
    response: "Vehicles must be returned with the same fuel level and the manufacturer-recommended fuel type. Refueling charges may include the actual fuel cost plus a $20 service fee."
  },
  {
    keywords: ["rideshare", "uber", "lyft", "doordash", "delivery", "tow", "towing", "race", "racing", "illegal", "unauthorized driver"],
    response: "Vehicles may not be used by unauthorized drivers, under the influence of alcohol or drugs, for racing, towing, pushing, unauthorized rideshare or delivery work, illegal activity, or travel outside permitted geographic areas."
  },
  {
    keywords: ["payment", "pay", "card", "checkout", "tax", "fees", "when do i pay"],
    response: "Rental payment is due before pickup. Sales tax and applicable fees are collected at checkout. Renters also authorize rental-related charges such as excess mileage, tolls, tickets, cleaning, smoking, damage, fuel, late return, and administrative fees when applicable."
  },
  {
    keywords: ["bradley", "airport", "bdl", "hartford", "windsor locks", "west hartford", "new britain", "plainville", "bristol", "southington", "service area"],
    response: "Rent Me CT is based in Farmington, CT and serves Farmington, Hartford, West Hartford, New Britain, Bristol, Plainville, Southington, Windsor Locks, Bradley International Airport travelers, and nearby Connecticut areas. We are not located inside Bradley Airport."
  },
  {
    keywords: ["available", "availability", "reserve", "reservation", "book", "booking", "car available", "choose a car"],
    response: "To check availability, choose your pickup and return dates on the fleet page, then select a vehicle. Final availability, renter details, documents, insurance, and payment are confirmed through Wheelbase checkout."
  },
  {
    keywords: ["cars", "vehicles", "fleet", "suv", "sedan", "luxury", "truck", "van", "audi", "bmw", "mercedes", "cadillac", "ford", "dodge", "kia", "buick"],
    response: "Vehicle categories may include sedans, SUVs, luxury vehicles, trucks, compact vehicles, and passenger vans depending on current fleet availability. The fleet can include brands such as Audi, BMW, Mercedes-Benz, Cadillac, Ford, Dodge, Kia, and Buick."
  },
  {
    keywords: ["phone", "call", "text", "contact", "number", "help", "human", "person"],
    response: "For the fastest help, call or text Rent Me CT at 860-558-6031."
  }
];

function normalizeChatText(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[^\w\s$.-]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function getChatbotReply(message) {
  const text = normalizeChatText(message);
  if (!text) return "Ask me about insurance, deposits, mileage, documents, pickup, drop-off, late returns, damage, tolls, vehicle rules, or availability.";

  const scored = RENT_ME_CT_CHATBOT_TOPICS
    .map((topic, index) => {
      const score = topic.keywords.reduce((total, keyword) => (
        text.includes(normalizeChatText(keyword)) ? total + normalizeChatText(keyword).split(" ").length : total
      ), 0);
      return { topic, index, score };
    })
    .filter((item) => item.score > 0)
    .sort((a, b) => b.score - a.score || a.index - b.index);

  if (scored.length) return scored[0].topic.response;

  if (["hi", "hello", "hey"].some((greeting) => text === greeting || text.startsWith(`${greeting} `))) {
    return "Hey! I can help with rental requirements, insurance, deposits, mileage, pickup and return, documents, agreement rules, and availability. What would you like to know?";
  }

  return "I may not have the exact answer to that yet. You can ask me about requirements, insurance, deposits, mileage, pickup/drop-off, late returns, damage, tolls, smoking, vehicle rules, availability, or call/text 860-558-6031 for help.";
}

function sendChatMessage(event) {
  event.preventDefault();

  const input = document.getElementById("chatInput");
  const messages = document.getElementById("chatMessages");

  if (!input || !messages || !input.value.trim()) return;

  const userMessage = document.createElement("div");
  userMessage.className = "user-message";
  userMessage.textContent = input.value.trim();
  messages.appendChild(userMessage);

  const botMessage = document.createElement("div");
  botMessage.className = "bot-message";
  botMessage.textContent = getChatbotReply(userMessage.textContent);
  messages.appendChild(botMessage);

  input.value = "";
  messages.scrollTop = messages.scrollHeight;
}

/* Privacy choices and shared legal navigation.
   The public site currently does not load analytics or advertising pixels. This
   manager keeps that default explicit and gives future non-essential services a
   single consent gate through window.rentmectConsent.allows(category). */
const RENTMECT_CONSENT_KEY = "rentmect_privacy_choices_v1";
const RENTMECT_CONSENT_VERSION = "2026-07-30";

function rentmectDefaultConsent() {
  const globalPrivacyControl = navigator.globalPrivacyControl === true;
  return {
    necessary: true,
    functional: false,
    analytics: false,
    marketing: false,
    globalPrivacyControl,
    version: RENTMECT_CONSENT_VERSION,
    timestamp: null,
  };
}

function readRentmectConsent() {
  const defaults = rentmectDefaultConsent();
  try {
    const stored = JSON.parse(localStorage.getItem(RENTMECT_CONSENT_KEY) || "null");
    if (!stored || stored.version !== RENTMECT_CONSENT_VERSION) return defaults;
    return {
      ...defaults,
      functional: Boolean(stored.functional),
      analytics: defaults.globalPrivacyControl ? false : Boolean(stored.analytics),
      marketing: defaults.globalPrivacyControl ? false : Boolean(stored.marketing),
      timestamp: stored.timestamp || null,
    };
  } catch (_) {
    return defaults;
  }
}

function saveRentmectConsent(next) {
  const globalPrivacyControl = navigator.globalPrivacyControl === true;
  const value = {
    necessary: true,
    functional: Boolean(next.functional),
    analytics: globalPrivacyControl ? false : Boolean(next.analytics),
    marketing: globalPrivacyControl ? false : Boolean(next.marketing),
    globalPrivacyControl,
    version: RENTMECT_CONSENT_VERSION,
    timestamp: new Date().toISOString(),
  };
  try {
    localStorage.setItem(RENTMECT_CONSENT_KEY, JSON.stringify(value));
  } catch (_) {
    // Preferences still apply for this page view if browser storage is blocked.
  }
  window.dispatchEvent(new CustomEvent("rentmect:consent-changed", { detail: value }));
  return value;
}

function ensureRentmectFooterLinks() {
  document.querySelectorAll(".footer-legal").forEach((nav) => {
    const links = [
      ["privacy-policy.html", "Privacy Policy"],
      ["terms.html", "Terms of Service"],
      ["cookie-policy.html", "Cookie Policy"],
      ["accessibility.html", "Accessibility"],
      ["rental-policies.html", "Rental Policies"],
      ["sitemap.html", "Sitemap"],
      ["privacy-choices.html", "Do Not Sell or Share My Personal Information"],
    ];
    links.forEach(([href, label]) => {
      if (nav.querySelector(`a[href="${href}"]`)) return;
      const link = document.createElement("a");
      link.href = href;
      link.textContent = label;
      nav.appendChild(link);
    });
    if (!nav.querySelector("[data-manage-cookie-preferences]")) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "footer-privacy-button";
      button.dataset.manageCookiePreferences = "";
      button.textContent = "Manage Cookie Preferences";
      nav.appendChild(button);
    }
  });
}

function ensureRentmectSkipLink() {
  const main = document.querySelector("main");
  if (!main) return;
  if (!main.id) main.id = "main-content";
  if (document.querySelector(".skip-link")) return;
  const link = document.createElement("a");
  link.className = "skip-link";
  link.href = `#${main.id}`;
  link.textContent = "Skip to main content";
  document.body.prepend(link);
}

function initializeRentmectPrivacyChoices() {
  if (document.getElementById("rentmectConsentBanner")) return;

  ensureRentmectFooterLinks();
  ensureRentmectSkipLink();

  const banner = document.createElement("section");
  banner.id = "rentmectConsentBanner";
  banner.className = "privacy-banner";
  banner.setAttribute("aria-label", "Privacy choices");
  banner.innerHTML = `
    <div>
      <strong>Your privacy choices</strong>
      <p>We use necessary browser storage for booking, security, and sign-in. We do not currently load advertising or analytics pixels. You can accept, reject, or customize any future non-essential storage.</p>
      <a href="cookie-policy.html">Read the Cookie Policy</a>
    </div>
    <div class="privacy-banner-actions">
      <button type="button" data-consent="accept">Accept all</button>
      <button type="button" data-consent="reject">Reject non-essential</button>
      <button type="button" data-consent="customize">Customize</button>
    </div>`;

  const modal = document.createElement("div");
  modal.id = "rentmectConsentModal";
  modal.className = "privacy-modal";
  modal.hidden = true;
  modal.innerHTML = `
    <button type="button" class="privacy-modal-backdrop" data-consent-close aria-label="Close privacy preferences"></button>
    <section class="privacy-modal-panel" role="dialog" aria-modal="true" aria-labelledby="rentmectConsentTitle" tabindex="-1">
      <div class="privacy-modal-header">
        <div>
          <p class="eyebrow">Privacy controls</p>
          <h2 id="rentmectConsentTitle">Manage cookie and storage preferences</h2>
        </div>
        <button type="button" class="privacy-modal-close" data-consent-close aria-label="Close privacy preferences">×</button>
      </div>
      <p>Necessary storage supports requested booking, fraud prevention, portal authentication, and your saved privacy choice. The public website currently has no analytics or advertising pixels.</p>
      <div class="privacy-choice-list">
        <label><span><strong>Necessary</strong><small>Booking handoff, security, sign-in, and consent records. Always on.</small></span><input type="checkbox" checked disabled /></label>
        <label><span><strong>Functional</strong><small>Optional display preferences, such as remembering a dismissed promotion.</small></span><input id="rentmectConsentFunctional" type="checkbox" /></label>
        <label><span><strong>Analytics</strong><small>Audience measurement. No analytics provider is currently active.</small></span><input id="rentmectConsentAnalytics" type="checkbox" /></label>
        <label><span><strong>Marketing</strong><small>Targeted advertising. No advertising pixel is currently active.</small></span><input id="rentmectConsentMarketing" type="checkbox" /></label>
      </div>
      <p id="rentmectGpcNotice" class="privacy-gpc-notice" hidden><strong>Global Privacy Control detected.</strong> Analytics and marketing choices remain off while this browser signal is enabled.</p>
      <div class="privacy-modal-actions">
        <button type="button" data-consent-save>Save choices</button>
        <button type="button" data-consent-modal-reject>Reject non-essential</button>
      </div>
      <p class="privacy-detail-link"><a href="privacy-choices.html">View privacy rights and opt-out information</a></p>
    </section>`;

  document.body.append(banner, modal);

  const panel = modal.querySelector(".privacy-modal-panel");
  const functional = modal.querySelector("#rentmectConsentFunctional");
  const analytics = modal.querySelector("#rentmectConsentAnalytics");
  const marketing = modal.querySelector("#rentmectConsentMarketing");
  const gpcNotice = modal.querySelector("#rentmectGpcNotice");
  let previousFocus = null;

  const syncControls = () => {
    const current = readRentmectConsent();
    functional.checked = current.functional;
    analytics.checked = current.analytics;
    marketing.checked = current.marketing;
    analytics.disabled = current.globalPrivacyControl;
    marketing.disabled = current.globalPrivacyControl;
    gpcNotice.hidden = !current.globalPrivacyControl;
  };

  const closeModal = () => {
    modal.hidden = true;
    document.body.classList.remove("privacy-modal-open");
    if (previousFocus instanceof HTMLElement) previousFocus.focus();
  };

  const openModal = () => {
    previousFocus = document.activeElement;
    syncControls();
    modal.hidden = false;
    document.body.classList.add("privacy-modal-open");
    window.requestAnimationFrame(() => panel.focus());
  };

  const finishChoice = (choice) => {
    saveRentmectConsent(choice);
    banner.hidden = true;
    closeModal();
  };

  banner.querySelector('[data-consent="accept"]').addEventListener("click", () => {
    finishChoice({ functional: true, analytics: true, marketing: true });
  });
  banner.querySelector('[data-consent="reject"]').addEventListener("click", () => {
    finishChoice({ functional: false, analytics: false, marketing: false });
  });
  banner.querySelector('[data-consent="customize"]').addEventListener("click", openModal);
  modal.querySelector("[data-consent-save]").addEventListener("click", () => {
    finishChoice({
      functional: functional.checked,
      analytics: analytics.checked,
      marketing: marketing.checked,
    });
  });
  modal.querySelector("[data-consent-modal-reject]").addEventListener("click", () => {
    finishChoice({ functional: false, analytics: false, marketing: false });
  });
  modal.querySelectorAll("[data-consent-close]").forEach((button) => button.addEventListener("click", closeModal));
  document.querySelectorAll("[data-manage-cookie-preferences]").forEach((button) => button.addEventListener("click", openModal));
  document.addEventListener("keydown", (event) => {
    if (modal.hidden) return;
    if (event.key === "Escape") {
      event.preventDefault();
      closeModal();
      return;
    }
    if (event.key !== "Tab") return;
    const focusable = [...panel.querySelectorAll('button:not([disabled]), a[href], input:not([disabled]), [tabindex]:not([tabindex="-1"])')]
      .filter((element) => element.offsetParent !== null);
    if (!focusable.length) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  });

  banner.hidden = Boolean(readRentmectConsent().timestamp);
  window.rentmectConsent = {
    get: readRentmectConsent,
    allows: (category) => category === "necessary" || Boolean(readRentmectConsent()[category]),
    open: openModal,
  };
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", initializeRentmectPrivacyChoices);
} else {
  initializeRentmectPrivacyChoices();
}
