(() => {
  "use strict";

  const SUPABASE_URL = "https://gqmiktepthaafupwdmcl.supabase.co";
  const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdxbWlrdGVwdGhhYWZ1cHdkbWNsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc1ODgxNzgsImV4cCI6MjA5MzE2NDE3OH0.dDM6SSAwd03FLWcdOc8OemcFmZ7yOxKsuPq3qpmqoWI";
  const TEST_VEHICLE_ID = "00000000-0000-4000-8000-000000000015";
  const FALLBACK_IMAGE = "assets/Benz-CLS-AMG-550-224.webp";
  const PORTAL_URL = /^(localhost|127\.0\.0\.1)$/i.test(window.location.hostname)
    ? `${window.location.protocol}//${window.location.hostname}:5173/`
    : "https://login.rentmect.com/";
  const VEHICLE_GALLERY_JPG_IMAGES = new Set([
    "001-2", "002-1", "002-2", "100-3", "148-1", "157-2",
    "191-1", "191-2", "210-1", "210-2", "225-2", "321-1",
    "451-2", "474-1", "649-2", "656-1", "656-2", "656-3",
  ]);
  const FEATURE_PRIORITY = [
    "Apple CarPlay",
    "Blind spot warning",
    "Lane keeping assist",
    "Backup camera",
    "Android Auto",
    "Adaptive cruise control",
    "Automatic emergency braking",
    "Forward collision warning",
    "Parking sensors",
    "Rear cross-traffic alert",
    "Heated seats",
    "Sunroof",
    "Bluetooth",
    "GPS",
    "Keyless entry",
    "USB charger",
    "USB input",
    "AUX input",
  ];
  const TIME_OPTIONS = Array.from({ length: 30 }, (_, index) => {
    const minutes = 9 * 60 + index * 30;
    const hour = Math.floor(minutes / 60);
    const minute = minutes % 60;
    const period = hour >= 12 && hour < 24 ? "PM" : "AM";
    const displayHour = hour % 12 || 12;
    return `${displayHour}:${String(minute).padStart(2, "0")} ${period}`;
  });
  const RENT_ME_CT_TIME_ZONE = "America/New_York";
  const RENTAL_OPENING_MINUTES = 9 * 60;
  const RENTAL_LAST_SLOT_MINUTES = 23 * 60 + 30;
  const RENTAL_DEFAULT_NOTICE_MINUTES = 3 * 60;
  const RENTAL_SLOT_MINUTES = 30;

  const url = new URL(window.location.href);
  const requestedPickupDate = validDateParam(url.searchParams.get("pickupDate"));
  const requestedPickupTime = validTimeParam(url.searchParams.get("pickupTime"));
  const requestedPickupTimeCustomized =
    url.searchParams.get("pickupTimeCustomized") === "1"
    || url.searchParams.get("pickupTimeCustomized") === "true";
  const requestedReturnTime = validTimeParam(url.searchParams.get("returnTime"));
  const requestedReturnTimeCustomized =
    url.searchParams.get("returnTimeCustomized") === "1"
    || url.searchParams.get("returnTimeCustomized") === "true";
  const initialPickupTime = requestedPickupTimeCustomized && requestedPickupTime ? requestedPickupTime : "9:00 AM";
  const state = {
    trip: {
      pickupDate: requestedPickupDate || dateInput(0),
      returnDate: validDateParam(url.searchParams.get("returnDate")) || dateInput(1),
      pickupTime: initialPickupTime,
      returnTime: requestedReturnTimeCustomized && requestedReturnTime ? requestedReturnTime : initialPickupTime,
    },
    policy: {
      minimumRentalDays: 1,
      minimumRentalHours: 24,
      advanceNoticeMinutes: 0,
      serverNow: new Date().toISOString(),
    },
    quote: null,
    quoteLoading: false,
    quoteRequest: 0,
    vehicles: [],
    availability: new Map(),
    selectedId: "",
    filter: "all",
    search: "",
    availableOnly: false,
    pricingDays: 1,
    checking: false,
    loading: true,
    starting: false,
    galleryIndex: 0,
    availabilityRequest: 0,
  };

  const REQUIRED_ELEMENT_IDS = [
    "cars2FleetView", "cars2DetailView", "cars2PickupDate", "cars2ReturnDate",
    "cars2PickupTime", "cars2ReturnTime", "cars2DetailPickupDate",
    "cars2DetailReturnDate", "cars2DetailPickupTime", "cars2DetailReturnTime",
    "cars2Search", "cars2AvailableOnly", "cars2Filters", "cars2RentalLength", "cars2Status",
    "cars2Error", "cars2Grid", "cars2PreviewHeader", "cars2HeaderBack", "cars2FeaturedImage",
    "cars2FeaturedFrame", "cars2GalleryPrevious", "cars2GalleryNext", "cars2GalleryCounter",
    "cars2Thumbnails", "cars2VehicleName", "cars2VehicleMeta",
    "cars2VehicleDescription", "cars2Features", "cars2DailyRate",
    "cars2DetailAvailability", "cars2RentalDays", "cars2RentalSubtotal",
    "cars2QuoteStatus", "cars2TaxAmount",
    "cars2SecurityDeposit", "cars2TotalDueToday", "cars2Under25Quote",
    "cars2Under25Rental", "cars2Under25Tax", "cars2Under25Deposit", "cars2Under25Total",
    "cars2BookVehicle", "cars2AvailabilityForm", "cars2CheckAvailability", "cars2TripSummary",
    "cars2DetailError", "cars2InsuranceModal",
    "cars2InsuranceContinue", "cars2InsuranceReview",
  ];
  const elements = {};
  let availabilityTimer = 0;
  let cardSwipeStartX = null;
  let detailSwipeStartX = null;
  let insuranceModalTrigger = null;
  let initialTripNormalized = false;
  let returnTimeCustomized =
    requestedReturnTimeCustomized
    && Boolean(requestedReturnTime && requestedReturnTime !== state.trip.pickupTime);

  document.addEventListener("DOMContentLoaded", () => {
    initialize().catch((error) => renderFatalLoadFailure(error));
  });

  async function initialize() {
    cacheElements();
    populateTimeOptions();
    const bookingPolicyRequest = loadBookingPolicy();
    const vehicleRequest = fetchPublishedVehicles()
      .then((vehicles) => ({ vehicles, error: null }))
      .catch((error) => ({ vehicles: [], error }));
    const abandonRequest = abandonReturnedCheckout();
    await bookingPolicyRequest;
    normalizeInitialTrip();
    syncTripFields();
    bindEvents();
    await abandonRequest;
    await loadVehicles(vehicleRequest);
  }

  function cacheElements() {
    REQUIRED_ELEMENT_IDS.forEach((id) => { elements[id] = document.getElementById(id); });
    const missing = REQUIRED_ELEMENT_IDS.filter((id) => !elements[id]);
    if (missing.length) throw new Error(`Cars-2 document contract is incomplete: ${missing.join(", ")}`);
  }

  function renderFatalLoadFailure(error) {
    console.error("Cars-2 could not initialize.", error);
    const main = document.querySelector("main");
    if (!main) return;
    main.innerHTML = `
      <section class="section" style="max-width: 760px; margin: 48px auto; text-align: center;">
        <p class="eyebrow">Live availability</p>
        <h1>We could not load the vehicles.</h1>
        <p>Please refresh this page. If it still does not load, call or text <a href="tel:+18605586031">860-558-6031</a>.</p>
        <p><button class="btn-primary" type="button" onclick="window.location.reload()">Refresh vehicles</button></p>
      </section>`;
  }

  async function loadBookingPolicy() {
    try {
      const response = await apiFetch("/rest/v1/rpc/get_public_booking_policy", {
        method: "POST",
        body: "{}",
      });
      const payload = await response.json();
      const policy = Array.isArray(payload) ? payload[0] : payload;
      if (policy) {
        state.policy = {
          minimumRentalDays: Math.max(1, Number(policy.minimum_rental_days) || 1),
          minimumRentalHours: Math.max(24, Number(policy.minimum_rental_hours) || 24),
          advanceNoticeMinutes: Math.max(0, Number(policy.advance_notice_minutes) || 0),
          serverNow: policy.server_now || new Date().toISOString(),
        };
      }
    } catch (error) {
      console.warn("Booking policy could not load; database validation remains active.", error);
    }
  }

  function bindEvents() {
    ["cars2PickupDate", "cars2ReturnDate", "cars2PickupTime", "cars2ReturnTime"].forEach((id) => {
      elements[id].addEventListener("change", () => updateTripFromField(id));
    });
    ["cars2DetailPickupDate", "cars2DetailReturnDate", "cars2DetailPickupTime", "cars2DetailReturnTime"].forEach((id) => {
      elements[id].addEventListener("change", () => updateTripFromField(id));
    });
    elements.cars2AvailabilityForm.addEventListener("submit", runAvailabilityCheck);
    elements.cars2Search.addEventListener("input", (event) => {
      state.search = event.target.value.trim().toLowerCase();
      renderVehicles();
    });
    elements.cars2RentalLength.addEventListener("change", (event) => {
      state.pricingDays = Math.max(1, Number(event.target.value) || 1);
      renderVehicles();
    });
    elements.cars2AvailableOnly.addEventListener("click", () => {
      state.availableOnly = !state.availableOnly;
      elements.cars2AvailableOnly.classList.toggle("active", state.availableOnly);
      elements.cars2AvailableOnly.setAttribute("aria-pressed", String(state.availableOnly));
      renderVehicles();
    });
    elements.cars2Filters.addEventListener("click", (event) => {
      const button = event.target.closest("[data-filter]");
      if (!button) return;
      state.filter = button.dataset.filter;
      elements.cars2Filters.querySelectorAll("[data-filter]").forEach((item) => {
        const active = item === button;
        item.classList.toggle("active", active);
        item.setAttribute("aria-pressed", String(active));
      });
      renderVehicles();
    });
    elements.cars2Grid.addEventListener("click", (event) => {
      const galleryButton = event.target.closest("[data-gallery-direction]");
      if (galleryButton) {
        slideCardImage(galleryButton.closest(".cars2-vehicle-card"), Number(galleryButton.dataset.galleryDirection));
        return;
      }
      const button = event.target.closest("[data-vehicle-id]");
      if (button && !button.disabled) showVehicle(button.dataset.vehicleId);
    });
    elements.cars2Grid.addEventListener("touchstart", (event) => {
      if (event.touches.length !== 1 || !event.target.closest(".cars2-card-image")) return;
      cardSwipeStartX = event.touches[0].clientX;
    }, { passive: true });
    elements.cars2Grid.addEventListener("touchend", (event) => {
      const card = event.target.closest(".cars2-vehicle-card");
      if (cardSwipeStartX === null || !card || !event.changedTouches.length) return;
      const distance = event.changedTouches[0].clientX - cardSwipeStartX;
      cardSwipeStartX = null;
      if (Math.abs(distance) >= 42) slideCardImage(card, distance > 0 ? -1 : 1);
    }, { passive: true });
    elements.cars2HeaderBack.addEventListener("click", showFleet);
    elements.cars2GalleryPrevious.addEventListener("click", () => showDetailImage(state.galleryIndex - 1));
    elements.cars2GalleryNext.addEventListener("click", () => showDetailImage(state.galleryIndex + 1));
    elements.cars2FeaturedFrame.addEventListener("touchstart", (event) => {
      if (event.touches.length === 1) detailSwipeStartX = event.touches[0].clientX;
    }, { passive: true });
    elements.cars2FeaturedFrame.addEventListener("touchend", (event) => {
      if (detailSwipeStartX === null || !event.changedTouches.length) return;
      const distance = event.changedTouches[0].clientX - detailSwipeStartX;
      detailSwipeStartX = null;
      if (Math.abs(distance) >= 42) showDetailImage(state.galleryIndex + (distance > 0 ? -1 : 1));
    }, { passive: true });
    elements.cars2BookVehicle.addEventListener("click", openInsuranceReminder);
    elements.cars2InsuranceContinue.addEventListener("click", () => {
      closeInsuranceReminder(false);
      startBooking();
    });
    elements.cars2InsuranceReview.addEventListener("click", reviewInsuranceOptions);
    elements.cars2InsuranceModal.querySelectorAll("[data-insurance-close]").forEach((button) => {
      button.addEventListener("click", () => closeInsuranceReminder());
    });
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && !elements.cars2InsuranceModal.hidden) closeInsuranceReminder();
    });
    window.addEventListener("popstate", applyUrlState);
    window.addEventListener("pageshow", () => {
      if (!new URL(window.location.href).searchParams.has("abandonBooking")) return;
      abandonReturnedCheckout().then(() => checkAvailability());
    });
  }

  function openInsuranceReminder() {
    if (elements.cars2BookVehicle.disabled || state.starting || !selectedVehicle()) return;
    insuranceModalTrigger = document.activeElement;
    elements.cars2InsuranceModal.hidden = false;
    document.body.classList.add("cars2-modal-open");
    window.requestAnimationFrame(() => elements.cars2InsuranceContinue.focus());
  }

  function closeInsuranceReminder(restoreFocus = true) {
    elements.cars2InsuranceModal.hidden = true;
    document.body.classList.remove("cars2-modal-open");
    if (restoreFocus && insuranceModalTrigger instanceof HTMLElement) insuranceModalTrigger.focus();
  }

  function reviewInsuranceOptions() {
    closeInsuranceReminder(false);
    showFleet();
    window.requestAnimationFrame(() => {
      document.getElementById("insuranceOptions")?.scrollIntoView({ block: "start" });
    });
  }

  async function fetchPublishedVehicles() {
    const query = new URLSearchParams({
      select: "*",
      published: "eq.true",
      id: `neq.${TEST_VEHICLE_ID}`,
      order: "daily_rate.asc.nullslast",
    });
    let lastError = null;

    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        const response = await apiFetch(`/rest/v1/vehicles?${query}`, { method: "GET" });
        const vehicles = await response.json();
        return Array.isArray(vehicles)
          ? vehicles.filter((vehicle) => vehicle?.id && vehicle.id !== TEST_VEHICLE_ID)
          : [];
      } catch (error) {
        lastError = error;
        if (attempt === 0) await new Promise((resolve) => window.setTimeout(resolve, 500));
      }
    }

    throw lastError || new Error("The fleet request failed.");
  }

  async function loadVehicles(pendingRequest = null) {
    setStatus("Loading live fleet…");
    hideError(elements.cars2Error);
    try {
      const result = pendingRequest
        ? await pendingRequest
        : { vehicles: await fetchPublishedVehicles(), error: null };
      if (result.error) throw result.error;
      state.vehicles = result.vehicles;
      state.loading = false;
      renderFilters();
      const requestedVehicle = url.searchParams.get("vehicle");
      if (requestedVehicle && state.vehicles.some((vehicle) => vehicle.id === requestedVehicle)) {
        state.selectedId = requestedVehicle;
      }
      await checkAvailability();
      if (state.selectedId) renderDetail();
    } catch (error) {
      state.loading = false;
      elements.cars2Grid.setAttribute("aria-busy", "false");
      setStatus("");
      showError(elements.cars2Error, friendlyError(error, "The fleet could not load. Refresh the page to try again."));
    }
  }

  function renderFilters() {
    const brands = [...new Set(state.vehicles.map((vehicle) => String(vehicle.brand || "").trim()).filter(Boolean))]
      .sort((a, b) => a.localeCompare(b));
    const filters = [
      ["all", "All Cars"],
      ...brands.map((brand) => [brand.toLowerCase(), brand]),
      ["suv", "SUV"],
      ["sedan", "Sedan"],
      ["truck", "Truck"],
      ["van", "Van"],
      ["luxury", "Luxury"],
    ];
    const seen = new Set();
    elements.cars2Filters.innerHTML = filters
      .filter(([value]) => !seen.has(value) && seen.add(value))
      .map(([value, label]) => `<button type="button" data-filter="${escapeHtml(value)}" class="${value === state.filter ? "active" : ""}" aria-pressed="${value === state.filter}">${escapeHtml(label)}</button>`)
      .join("");
  }

  function renderVehicles() {
    if (state.loading) return;
    const visible = state.vehicles.filter((vehicle) => {
      const result = state.availability.get(vehicle.id);
      const terms = [vehicle.name, vehicle.brand, vehicle.model, vehicle.vehicle_type].join(" ").toLowerCase();
      const type = String(vehicle.vehicle_type || "").toLowerCase();
      const brand = String(vehicle.brand || "").toLowerCase();
      const filterMatches = state.filter === "all" || brand === state.filter || type.includes(state.filter);
      return filterMatches && terms.includes(state.search) && (!state.availableOnly || result?.available === true);
    });

    elements.cars2Grid.innerHTML = visible.map((vehicle) => vehicleCard(vehicle)).join("");
    if (!visible.length) {
      elements.cars2Grid.innerHTML = '<p class="cars2-empty">No vehicles match these filters and dates. Try changing a filter or rental date.</p>';
    }
    elements.cars2Grid.setAttribute("aria-busy", String(state.checking));
    setStatus(state.checking ? "Checking live availability…" : `${visible.length} vehicle${visible.length === 1 ? "" : "s"} shown`);
  }

  function vehicleCard(vehicle) {
    const result = state.availability.get(vehicle.id);
    const available = result?.available === true;
    const checking = state.checking;
    const status = checking ? "Checking…" : available ? "Available" : "Unavailable";
    const statusClass = checking ? "checking" : available ? "available" : "unavailable";
    const statusLabel = checking
      ? "Checking availability"
      : available
        ? "Available"
        : result?.reason
          ? `Unavailable: ${result.reason}`
          : "Unavailable";
    const pricingDays = Math.max(1, Number(state.pricingDays) || 1);
    const displayedPrice = Number(vehicle.daily_rate || 0) * pricingDays;
    const images = vehicleImages(vehicle);
    const highlights = vehicleHighlights(vehicle);
    return `
      <article class="cars2-vehicle-card" data-gallery-vehicle-id="${escapeHtml(vehicle.id)}" data-gallery-index="0">
        <div class="cars2-card-image">
          <img data-card-image src="${escapeHtml(images[0])}" alt="${escapeHtml(vehicle.name || "Rent Me CT vehicle")} photo 1 of ${images.length}" loading="lazy" decoding="async" onerror="this.onerror=null;this.src='${FALLBACK_IMAGE}'" />
          <button class="cars2-card-gallery-arrow previous" type="button" data-gallery-direction="-1" aria-label="Show previous photo of ${escapeHtml(vehicle.name || "vehicle")}">
            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 18 9 12l6-6"/></svg>
          </button>
          <button class="cars2-card-gallery-arrow next" type="button" data-gallery-direction="1" aria-label="Show next photo of ${escapeHtml(vehicle.name || "vehicle")}">
            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="m9 18 6-6-6-6"/></svg>
          </button>
          <span class="cars2-card-gallery-counter" aria-live="polite">1 / ${images.length}</span>
        </div>
        <div class="cars2-card-body">
          <span class="cars2-card-status ${statusClass}" aria-label="${escapeHtml(statusLabel)}" title="${escapeHtml(statusLabel)}">${escapeHtml(status)}</span>
          <h2>${escapeHtml(vehicle.name || "Rent Me CT vehicle")}</h2>
          <p class="cars2-card-meta">${escapeHtml(vehicleCardMeta(vehicle))}</p>
          <ul>
            ${highlights.map((feature) => `<li>${escapeHtml(feature)}</li>`).join("")}
          </ul>
          <p class="cars2-card-price"><strong>${money(displayedPrice)}</strong><span>/ ${pricingDays} ${pricingDays === 1 ? "day" : "days"}</span></p>
          <button class="cars2-card-button" type="button" data-vehicle-id="${escapeHtml(vehicle.id)}" ${checking || !available ? "disabled" : ""}>
            ${checking ? "Checking dates…" : available ? "View & book" : "Unavailable"}
          </button>
        </div>
      </article>`;
  }

  function showVehicle(vehicleId, push = true) {
    const vehicle = state.vehicles.find((item) => item.id === vehicleId);
    if (!vehicle) return;
    state.selectedId = vehicleId;
    elements.cars2PreviewHeader.hidden = false;
    elements.cars2HeaderBack.hidden = false;
    if (push) {
      const nextUrl = new URL(window.location.href);
      nextUrl.searchParams.set("vehicle", vehicleId);
      syncTripToUrl(nextUrl);
      history.pushState({}, "", nextUrl);
    }
    renderDetail();
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  function showFleet(push = true) {
    state.selectedId = "";
    elements.cars2PreviewHeader.hidden = true;
    elements.cars2HeaderBack.hidden = true;
    elements.cars2DetailView.hidden = true;
    elements.cars2FleetView.hidden = false;
    if (push) {
      const nextUrl = new URL(window.location.href);
      nextUrl.searchParams.delete("vehicle");
      syncTripToUrl(nextUrl);
      history.pushState({}, "", nextUrl);
    }
    renderVehicles();
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  function renderDetail() {
    const vehicle = selectedVehicle();
    if (!vehicle) return showFleet(false);
    elements.cars2PreviewHeader.hidden = false;
    elements.cars2HeaderBack.hidden = false;
    const images = vehicleImages(vehicle);
    elements.cars2FleetView.hidden = true;
    elements.cars2DetailView.hidden = false;
    elements.cars2VehicleName.textContent = vehicle.name || "Rent Me CT vehicle";
    elements.cars2VehicleMeta.textContent = vehicleFeatures(vehicle).join(" • ");
    elements.cars2VehicleDescription.textContent = vehicle.description || "A clean, reliable Rent Me CT vehicle maintained for your trip.";
    elements.cars2DailyRate.textContent = money(vehicle.daily_rate);
    state.galleryIndex = 0;
    elements.cars2Thumbnails.innerHTML = images.map((image, index) => `
      <button type="button" class="${index === 0 ? "active" : ""}" data-image-index="${index}" aria-label="Show ${escapeHtml(vehicle.name || "vehicle")} photo ${index + 1}">
        <img src="${escapeHtml(image)}" alt="" loading="lazy" decoding="async" onerror="this.closest('button').hidden=true" />
      </button>`).join("");
    elements.cars2Thumbnails.querySelectorAll("[data-image-index]").forEach((button) => {
      button.addEventListener("click", () => {
        showDetailImage(Number(button.dataset.imageIndex));
      });
    });
    showDetailImage(0);
    const features = vehicleFeatures(vehicle);
    elements.cars2Features.innerHTML = features
      .map((feature) => `<span role="listitem">${escapeHtml(feature)}</span>`)
      .join("");
    syncTripFields();
    renderDetailAvailability();
    if (state.quote?.vehicle_id !== vehicle.id) refreshSelectedQuote(vehicle.id);
  }

  function renderDetailAvailability() {
    const vehicle = selectedVehicle();
    if (!vehicle) return;
    const result = state.availability.get(vehicle.id);
    const available = result?.available === true;
    const unavailableReason = String(result?.reason || "").trim();
    const unavailableDetail = unavailableReason.replace(/^unavailable(?:\s*[:—-]\s*|\s+)/i, "").trim();
    const message = state.checking
      ? "Checking calendar…"
      : available
        ? "Available for these dates"
        : unavailableDetail
          ? `Unavailable — ${unavailableDetail}`
          : "Unavailable for these dates";
    elements.cars2DetailAvailability.textContent = message;
    elements.cars2DetailAvailability.className = `cars2-availability ${state.checking ? "" : available ? "available" : "unavailable"}`;
    const selectedQuote = state.quote?.vehicle_id === vehicle.id ? state.quote : null;
    const quoteReady = Boolean(selectedQuote?.valid && !state.quoteLoading);
    const days = selectedQuote?.valid ? Number(selectedQuote.billable_days || 0) : rentalDays();
    elements.cars2RentalDays.textContent = `${days} rental day${days === 1 ? "" : "s"}`;
    elements.cars2QuoteStatus.textContent = state.quoteLoading ? "Calculating…" : quoteReady ? "Price confirmed" : "Price unavailable";
    elements.cars2QuoteStatus.classList.toggle("ready", quoteReady);
    elements.cars2RentalSubtotal.textContent = quoteReady ? money(selectedQuote.base_rental_total) : "—";
    elements.cars2TaxAmount.textContent = quoteReady ? money(selectedQuote.tax_amount) : "—";
    elements.cars2SecurityDeposit.textContent = quoteReady ? money(selectedQuote.security_deposit) : "—";
    elements.cars2TotalDueToday.textContent = quoteReady ? money(selectedQuote.total_due_today) : "—";
    elements.cars2Under25Quote.hidden = !quoteReady;
    if (quoteReady) {
      elements.cars2Under25Rental.textContent = money(selectedQuote.under_25_rental_total);
      elements.cars2Under25Tax.textContent = money(selectedQuote.under_25_tax_amount);
      elements.cars2Under25Deposit.textContent = money(selectedQuote.under_25_security_deposit);
      elements.cars2Under25Total.textContent = money(selectedQuote.under_25_total_due_today);
    }
    elements.cars2BookVehicle.disabled = state.checking || state.starting || !available || !quoteReady;
    elements.cars2BookVehicle.textContent = state.starting
      ? "Starting secure checkout…"
        : state.checking
        ? "Checking dates…"
        : available
          ? quoteReady ? "Start checkout" : "Calculating full price…"
          : "Unavailable";
  }

  async function refreshSelectedQuote(vehicleId) {
    if (!vehicleId || !validTrip()) return;
    const requestId = ++state.quoteRequest;
    state.quoteLoading = true;
    renderDetailAvailability();
    try {
      const quote = await fetchBookingQuote(vehicleId);
      if (requestId !== state.quoteRequest || state.selectedId !== vehicleId) return;
      state.quote = quote;
      if (!quote?.valid) showError(elements.cars2DetailError, quote?.error || "The complete price could not be calculated.");
    } catch (error) {
      if (requestId !== state.quoteRequest || state.selectedId !== vehicleId) return;
      showError(elements.cars2DetailError, friendlyError(error, "The complete price could not be calculated. Please retry."));
    } finally {
      if (requestId === state.quoteRequest) {
        state.quoteLoading = false;
        renderDetailAvailability();
      }
    }
  }

  function updateTripFromField(id) {
    const mapping = {
      cars2PickupDate: "pickupDate",
      cars2ReturnDate: "returnDate",
      cars2PickupTime: "pickupTime",
      cars2ReturnTime: "returnTime",
      cars2DetailPickupDate: "pickupDate",
      cars2DetailReturnDate: "returnDate",
      cars2DetailPickupTime: "pickupTime",
      cars2DetailReturnTime: "returnTime",
    };
    const key = mapping[id];
    state.trip[key] = elements[id].value;
    if (key === "returnTime") returnTimeCustomized = true;
    if (key === "pickupTime" && !returnTimeCustomized) {
      state.trip.returnTime = state.trip.pickupTime;
    }
    state.quote = null;
    state.quoteRequest += 1;
    state.quoteLoading = Boolean(state.selectedId);
    if (key === "pickupDate" && state.trip.returnDate <= state.trip.pickupDate) {
      state.trip.returnDate = addDays(state.trip.pickupDate, 1);
    }
    normalizeInitialTrip();
    syncTripFields();
    const nextUrl = new URL(window.location.href);
    syncTripToUrl(nextUrl);
    history.replaceState({}, "", nextUrl);
    scheduleAvailabilityCheck();
  }

  function scheduleAvailabilityCheck() {
    window.clearTimeout(availabilityTimer);
    availabilityTimer = window.setTimeout(checkAvailability, 180);
  }

  async function runAvailabilityCheck(event) {
    event?.preventDefault();
    elements.cars2CheckAvailability.disabled = true;
    elements.cars2CheckAvailability.textContent = "Checking…";
    try {
      await checkAvailability();
    } finally {
      elements.cars2CheckAvailability.disabled = false;
      elements.cars2CheckAvailability.textContent = "Check Availability";
    }
  }

  async function checkAvailability() {
    if (!validTrip()) {
      state.availability.clear();
      state.checking = false;
      renderVehicles();
      renderDetailAvailability();
      showError(elements.cars2DetailError, `Choose valid pickup and return times. Rentals require at least ${state.policy.minimumRentalHours} hours.`);
      return false;
    }
    const requestId = ++state.availabilityRequest;
    const quoteRequestId = ++state.quoteRequest;
    state.checking = true;
    state.quoteLoading = Boolean(state.selectedId);
    hideError(elements.cars2Error);
    hideError(elements.cars2DetailError);
    renderVehicles();
    renderDetailAvailability();
    try {
      const quote = await fetchBookingQuote();
      state.quote = quote;
      renderTripSummary();
      if (!quote?.valid) {
        state.availability.clear();
        state.checking = false;
        if (quoteRequestId === state.quoteRequest) state.quoteLoading = false;
        renderVehicles();
        renderDetailAvailability();
        if (state.selectedId) {
          showError(elements.cars2DetailError, quote?.error || "The selected rental times are not allowed.");
        } else {
          hideError(elements.cars2Error);
        }
        return false;
      }
      const response = await apiFetch("/rest/v1/rpc/get_admin_calendar_fleet_availability", {
        method: "POST",
        body: JSON.stringify({
          p_pickup_date: state.trip.pickupDate,
          p_pickup_time: state.trip.pickupTime,
          p_return_date: state.trip.returnDate,
          p_return_time: state.trip.returnTime,
        }),
      });
      const data = await response.json();
      if (requestId !== state.availabilityRequest) return false;
      state.availability = new Map((Array.isArray(data) ? data : []).map((item) => [item.vehicle_id, item]));
      if (state.selectedId) {
        const selectedQuote = await fetchBookingQuote(state.selectedId);
        if (requestId !== state.availabilityRequest) return false;
        if (quoteRequestId === state.quoteRequest) state.quote = selectedQuote;
      }
      state.checking = false;
      if (quoteRequestId === state.quoteRequest) state.quoteLoading = false;
      renderVehicles();
      renderDetailAvailability();
      return true;
    } catch (error) {
      if (requestId !== state.availabilityRequest) return false;
      state.availability.clear();
      state.checking = false;
      if (quoteRequestId === state.quoteRequest) state.quoteLoading = false;
      renderVehicles();
      renderDetailAvailability();
      const message = friendlyError(error, "Live availability could not be verified. Please try again.");
      showError(state.selectedId ? elements.cars2DetailError : elements.cars2Error, message);
      return false;
    }
  }

  async function fetchBookingQuote(vehicleId = null) {
    const response = await apiFetch("/rest/v1/rpc/get_booking_quote", {
      method: "POST",
      body: JSON.stringify({
        p_vehicle_id: vehicleId,
        p_pickup_date: state.trip.pickupDate,
        p_pickup_time: state.trip.pickupTime,
        p_return_date: state.trip.returnDate,
        p_return_time: state.trip.returnTime,
      }),
    });
    return response.json();
  }

  async function startBooking() {
    const vehicle = selectedVehicle();
    if (!vehicle || state.starting || !validTrip()) return;
    state.starting = true;
    hideError(elements.cars2DetailError);
    renderDetailAvailability();
    try {
      const fresh = await checkAvailability();
      const available = state.availability.get(vehicle.id)?.available === true;
      if (!fresh || !available) throw new Error("NO_LONGER_AVAILABLE");
      const finalQuote = await fetchBookingQuote(vehicle.id);
      if (!finalQuote?.valid) throw new Error(finalQuote?.error || "BOOKING_POLICY_REJECTED");
      state.quote = finalQuote;
      const response = await apiFetch("/rest/v1/rpc/create_website_pending_booking_with_token", {
        method: "POST",
        body: JSON.stringify({
          p_pickup_date: state.trip.pickupDate,
          p_return_date: state.trip.returnDate,
          p_pickup_time: state.trip.pickupTime,
          p_return_time: state.trip.returnTime,
          p_vehicle_id: vehicle.id,
          p_selected_vehicle_name: vehicle.name,
        }),
      });
      const bookingPayload = await response.json();
      const checkout = Array.isArray(bookingPayload) ? bookingPayload[0] : bookingPayload;
      const bookingId = checkout?.booking_id || "";
      const abandonToken = checkout?.abandon_token || "";
      if (!isUuid(bookingId) || !isUuid(abandonToken)) throw new Error("INVALID_BOOKING");
      const returnUrl = new URL(window.location.href);
      syncTripToUrl(returnUrl);
      returnUrl.searchParams.set("abandonBooking", bookingId);
      returnUrl.searchParams.set("abandonToken", abandonToken);
      history.replaceState({}, "", returnUrl);
      const portalUrl = new URL(PORTAL_URL);
      portalUrl.searchParams.set("booking", bookingId);
      portalUrl.searchParams.set("preview", "1");
      portalUrl.searchParams.set("source", "cars2");
      portalUrl.searchParams.set("holdExpires", new Date(Date.now() + 25 * 60000).toISOString());
      portalUrl.searchParams.set("abandonToken", abandonToken);
      const promo = sanitizePromo(url.searchParams.get("promo"));
      if (promo) portalUrl.searchParams.set("promo", promo);
      window.location.assign(portalUrl.toString());
    } catch (error) {
      state.starting = false;
      renderDetailAvailability();
      const message = error?.message === "NO_LONGER_AVAILABLE"
        ? "That vehicle was just taken for these dates. Choose another vehicle or change the dates."
        : friendlyError(error, "The secure checkout hold could not be created. Please retry.");
      showError(elements.cars2DetailError, message);
    }
  }

  async function abandonReturnedCheckout() {
    const checkoutUrl = new URL(window.location.href);
    const bookingId = checkoutUrl.searchParams.get("abandonBooking") || "";
    const abandonToken = checkoutUrl.searchParams.get("abandonToken") || "";
    if (!isUuid(bookingId) || !isUuid(abandonToken)) return;
    try {
      await apiFetch("/rest/v1/rpc/abandon_website_checkout", {
        method: "POST",
        body: JSON.stringify({
          p_booking_id: bookingId,
          p_abandon_token: abandonToken,
          p_rental_id: null,
        }),
      });
      const cleanUrl = new URL(window.location.href);
      cleanUrl.searchParams.delete("abandonBooking");
      cleanUrl.searchParams.delete("abandonToken");
      history.replaceState({}, "", cleanUrl);
    } catch (error) {
      showError(
        elements.cars2Error,
        friendlyError(error, "Your previous checkout is still being released. Refresh this page before choosing another vehicle."),
      );
    }
  }

  async function apiFetch(path, options = {}) {
    const controller = new AbortController();
    const timeout = window.setTimeout(() => controller.abort(new DOMException("Request deadline exceeded", "TimeoutError")), 9000);
    const suppliedSignal = options.signal;
    const abortFromCaller = () => controller.abort(suppliedSignal?.reason);
    suppliedSignal?.addEventListener("abort", abortFromCaller, { once: true });
    let response;
    try {
      response = await fetch(`${SUPABASE_URL}${path}`, {
        cache: "no-store",
        ...options,
        signal: controller.signal,
        headers: {
          apikey: SUPABASE_ANON_KEY,
          Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
          "Content-Type": "application/json",
          ...(options.headers || {}),
        },
      });
    } catch (error) {
      if (controller.signal.aborted && !suppliedSignal?.aborted) {
        throw new Error("Request timed out. Please retry this section.");
      }
      throw error;
    } finally {
      window.clearTimeout(timeout);
      suppliedSignal?.removeEventListener("abort", abortFromCaller);
    }
    if (!response.ok) {
      let detail = "";
      try {
        const payload = await response.json();
        detail = payload.message || payload.hint || payload.details || "";
      } catch {
        detail = "";
      }
      throw new Error(detail || `Request failed (${response.status})`);
    }
    return response;
  }

  function populateTimeOptions() {
    ["cars2PickupTime", "cars2ReturnTime", "cars2DetailPickupTime", "cars2DetailReturnTime"].forEach((id) => {
      elements[id].innerHTML = TIME_OPTIONS.map((time) => `<option value="${time}">${time}</option>`).join("");
    });
  }

  function syncTripFields() {
    const today = dateInput(0);
    const values = {
      cars2PickupDate: state.trip.pickupDate,
      cars2ReturnDate: state.trip.returnDate,
      cars2PickupTime: state.trip.pickupTime,
      cars2ReturnTime: state.trip.returnTime,
      cars2DetailPickupDate: state.trip.pickupDate,
      cars2DetailReturnDate: state.trip.returnDate,
      cars2DetailPickupTime: state.trip.pickupTime,
      cars2DetailReturnTime: state.trip.returnTime,
    };
    Object.entries(values).forEach(([id, value]) => {
      elements[id].value = value;
    });
    elements.cars2PickupDate.min = today;
    elements.cars2DetailPickupDate.min = today;
    elements.cars2ReturnDate.min = state.trip.pickupDate;
    elements.cars2DetailReturnDate.min = state.trip.pickupDate;
    renderTripSummary();
    window.syncBookingRangePickers?.();
  }

  function renderTripSummary() {
    if (!elements.cars2TripSummary) return;
    elements.cars2TripSummary.hidden = true;
    elements.cars2TripSummary.textContent = "";
    elements.cars2TripSummary.classList.remove("valid", "error");
    if (state.quote?.valid === false) {
      elements.cars2TripSummary.textContent = state.quote.error || `Rentals require at least ${state.policy.minimumRentalHours} hours.`;
      elements.cars2TripSummary.hidden = false;
      elements.cars2TripSummary.classList.add("error");
      return;
    }
  }

  function normalizeInitialTrip() {
    const today = dateInput(0);
    const earliestSlot = earliestPickupSlot();
    if (!validDateParam(state.trip.pickupDate) || state.trip.pickupDate < today) state.trip.pickupDate = earliestSlot.date;
    if (!initialTripNormalized && !(requestedPickupTime && requestedPickupTimeCustomized)) {
      if (!requestedPickupDate || state.trip.pickupDate < earliestSlot.date) state.trip.pickupDate = earliestSlot.date;
      state.trip.pickupTime = earliestSlot.time;
    }
    if (!validTimeParam(state.trip.pickupTime)) state.trip.pickupTime = "9:00 AM";
    if (!validTimeParam(state.trip.returnTime)) state.trip.returnTime = "9:00 AM";
    if (!validDateParam(state.trip.returnDate) || rentalMinutes() < state.policy.minimumRentalHours * 60) {
      state.trip.returnDate = addDays(state.trip.pickupDate, state.policy.minimumRentalDays);
      state.trip.returnTime = state.trip.pickupTime;
      returnTimeCustomized = false;
    }
    if (!returnTimeCustomized) state.trip.returnTime = state.trip.pickupTime;
    initialTripNormalized = true;
  }

  function validTrip() {
    if (!validDateParam(state.trip.pickupDate) || !validDateParam(state.trip.returnDate)) return false;
    if (state.trip.pickupDate < dateInput(0)) return false;
    if (!validTimeParam(state.trip.pickupTime) || !validTimeParam(state.trip.returnTime)) return false;
    return rentalMinutes() > 0;
  }

  function applyUrlState() {
    const current = new URL(window.location.href);
    const vehicleId = current.searchParams.get("vehicle") || "";
    if (vehicleId && state.vehicles.some((vehicle) => vehicle.id === vehicleId)) showVehicle(vehicleId, false);
    else showFleet(false);
  }

  function syncTripToUrl(targetUrl) {
    Object.entries(state.trip).forEach(([key, value]) => targetUrl.searchParams.set(key, value));
    targetUrl.searchParams.set("returnTimeCustomized", returnTimeCustomized ? "1" : "0");
  }

  function selectedVehicle() {
    return state.vehicles.find((vehicle) => vehicle.id === state.selectedId);
  }

  function fleetNumber(vehicle) {
    return String(vehicle?.name || "").match(/#([a-z0-9]+)/i)?.[1]?.toUpperCase() || "";
  }

  function builtInGalleryImages(vehicle) {
    const fleet = fleetNumber(vehicle);
    if (!fleet) return [];
    const highResolutionImages = window.RENTMECT_FLEET_GALLERY_IMAGES?.[fleet];
    if (Array.isArray(highResolutionImages) && highResolutionImages.length >= 4) {
      return highResolutionImages.slice(0, 4);
    }
    return Array.from({ length: 4 }, (_, index) => {
      const imageKey = `${fleet}-${index + 1}`;
      const extension = VEHICLE_GALLERY_JPG_IMAGES.has(imageKey) ? "jpg" : "webp";
      return `assets/fleet-2/${imageKey}.${extension}`;
    });
  }

  function vehicleImages(vehicle) {
    const uploaded = list(vehicle?.image_urls);
    if (uploaded.length) return [...new Set(uploaded)].slice(0, 20);
    const normalized = String(vehicle?.name || "")
      .replace(/Mercedes[- ]Benz/i, "Mercedes-Benz")
      .replace(/[^a-zA-Z0-9]+/g, "-")
      .replace(/^-|-$/g, "");
    const primary = uploaded[0] || (normalized ? `assets/${normalized}.webp` : FALLBACK_IMAGE);
    const builtIn = builtInGalleryImages(vehicle);
    const images = builtIn.length ? [primary, ...builtIn] : [primary, ...uploaded.slice(1)];
    return [...new Set(images.filter(Boolean))].slice(0, 5);
  }

  function vehicleFeatures(vehicle) {
    return [...new Set(list(vehicle?.features).map((feature) => String(feature).trim()).filter(Boolean))];
  }

  function vehicleHighlights(vehicle) {
    const saved = vehicleFeatures(vehicle);
    const priority = new Map(FEATURE_PRIORITY.map((feature, index) => [feature.toLowerCase(), index]));
    return saved
      .map((feature, index) => ({
        feature,
        index,
        rank: priority.get(feature.toLowerCase()) ?? FEATURE_PRIORITY.length + index,
      }))
      .sort((left, right) => left.rank - right.rank || left.index - right.index)
      .slice(0, 3)
      .map(({ feature }) => feature);
  }

  function vehicleCardMeta(vehicle) {
    return [vehicle?.vehicle_type, vehicle?.brand, vehicle?.model]
      .map((value) => String(value || "").trim())
      .filter((value, index, values) => value && values.findIndex((item) => item.toLowerCase() === value.toLowerCase()) === index)
      .join(" • ") || "Rent Me CT vehicle";
  }

  function slideCardImage(card, direction) {
    if (!card) return;
    const vehicle = state.vehicles.find((item) => item.id === card.dataset.galleryVehicleId);
    if (!vehicle) return;
    const images = vehicleImages(vehicle);
    const current = Number(card.dataset.galleryIndex || 0);
    const index = (current + direction + images.length) % images.length;
    card.dataset.galleryIndex = String(index);
    const image = card.querySelector("[data-card-image]");
    const counter = card.querySelector(".cars2-card-gallery-counter");
    if (image) {
      image.src = images[index];
      image.alt = `${vehicle.name || "Rent Me CT vehicle"} photo ${index + 1} of ${images.length}`;
    }
    if (counter) counter.textContent = `${index + 1} / ${images.length}`;
  }

  function showDetailImage(requestedIndex) {
    const vehicle = selectedVehicle();
    if (!vehicle) return;
    const images = vehicleImages(vehicle);
    const index = (requestedIndex + images.length) % images.length;
    state.galleryIndex = index;
    elements.cars2FeaturedImage.src = images[index];
    elements.cars2FeaturedImage.alt = `${vehicle.name || "Rent Me CT vehicle"} photo ${index + 1} of ${images.length}`;
    elements.cars2FeaturedImage.onerror = () => {
      elements.cars2FeaturedImage.onerror = null;
      elements.cars2FeaturedImage.src = FALLBACK_IMAGE;
    };
    elements.cars2GalleryCounter.textContent = `${index + 1} / ${images.length}`;
    elements.cars2Thumbnails.querySelectorAll("[data-image-index]").forEach((button) => {
      const active = Number(button.dataset.imageIndex) === index;
      button.classList.toggle("active", active);
      button.setAttribute("aria-current", active ? "true" : "false");
    });
  }

  function list(value) {
    if (Array.isArray(value)) return value.filter(Boolean);
    if (!value) return [];
    try {
      const parsed = JSON.parse(value);
      if (Array.isArray(parsed)) return parsed.filter(Boolean);
    } catch {
      // Legacy newline and comma-separated values are normalized below.
    }
    return String(value).split(/\r?\n|,/).map((item) => item.trim()).filter(Boolean);
  }

  function dateInput(offsetDays = 0) {
    const eastern = easternDateTimeParts(new Date());
    return addDays(eastern.date, offsetDays);
  }

  function addDays(dateValue, days) {
    const date = new Date(`${dateValue}T12:00:00`);
    date.setDate(date.getDate() + days);
    return [
      date.getFullYear(),
      String(date.getMonth() + 1).padStart(2, "0"),
      String(date.getDate()).padStart(2, "0"),
    ].join("-");
  }

  function validDateParam(value) {
    return /^\d{4}-\d{2}-\d{2}$/.test(String(value || "")) ? String(value) : "";
  }

  function validTimeParam(value) {
    return TIME_OPTIONS.includes(String(value || "")) ? String(value) : "";
  }

  function rentalMinutes() {
    const start = tripDateTime(state.trip.pickupDate, state.trip.pickupTime);
    const end = tripDateTime(state.trip.returnDate, state.trip.returnTime);
    if (!start || !end) return 0;
    return Math.max(0, Math.floor((end - start) / 60000));
  }

  function rentalDays() {
    const minutes = rentalMinutes();
    return minutes > 0 ? Math.ceil(minutes / 1440) : 0;
  }

  function tripDateTime(dateValue, timeValue) {
    if (!validDateParam(dateValue) || !validTimeParam(timeValue)) return null;
    const match = timeValue.match(/^(\d{1,2}):(\d{2}) (AM|PM)$/);
    if (!match) return null;
    let hour = Number(match[1]) % 12;
    if (match[3] === "PM") hour += 12;
    const [year, month, day] = dateValue.split("-").map(Number);
    const targetWallClock = Date.UTC(year, month - 1, day, hour, Number(match[2]), 0);
    let instant = targetWallClock;
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const eastern = Object.fromEntries(new Intl.DateTimeFormat("en-US", {
        timeZone: "America/New_York",
        year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
      }).formatToParts(new Date(instant)).filter((part) => part.type !== "literal").map((part) => [part.type, part.value]));
      const observedWallClock = Date.UTC(Number(eastern.year), Number(eastern.month) - 1, Number(eastern.day), Number(eastern.hour), Number(eastern.minute), Number(eastern.second));
      instant += targetWallClock - observedWallClock;
    }
    const parsed = new Date(instant);
    return Number.isFinite(parsed.getTime()) ? parsed : null;
  }

  function earliestPickupSlot() {
    const eastern = easternDateTimeParts(new Date(state.policy.serverNow));
    let date = eastern.date;
    const requestedNotice = Math.max(0, Number(state.policy.advanceNoticeMinutes) || 0);
    const standardTarget = eastern.minutes < RENTAL_OPENING_MINUTES
      ? RENTAL_OPENING_MINUTES
      : eastern.minutes + RENTAL_DEFAULT_NOTICE_MINUTES;
    const targetMinutes = Math.max(standardTarget, eastern.minutes + requestedNotice);
    const roundedMinutes = Math.ceil(targetMinutes / RENTAL_SLOT_MINUTES) * RENTAL_SLOT_MINUTES;
    if (roundedMinutes > RENTAL_LAST_SLOT_MINUTES) {
      date = addDays(date, 1);
      return { date, time: minutesToTime(RENTAL_OPENING_MINUTES) };
    }
    return { date, time: minutesToTime(roundedMinutes) };
  }

  function easternDateTimeParts(value) {
    const parts = Object.fromEntries(new Intl.DateTimeFormat("en-US", {
      timeZone: RENT_ME_CT_TIME_ZONE,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23",
    }).formatToParts(value).filter((part) => part.type !== "literal").map((part) => [part.type, part.value]));
    return {
      date: `${parts.year}-${parts.month}-${parts.day}`,
      minutes: Number(parts.hour) * 60 + Number(parts.minute),
    };
  }

  function minutesToTime(minutes) {
    return TIME_OPTIONS.find((option) => timeToMinutes(option) === minutes) || TIME_OPTIONS[0];
  }

  function timeToMinutes(value) {
    const match = String(value).match(/^(\d{1,2}):(\d{2}) (AM|PM)$/);
    if (!match) return 0;
    let hour = Number(match[1]) % 12;
    if (match[3] === "PM") hour += 12;
    return hour * 60 + Number(match[2]);
  }

  function formatMinutes(minutes) {
    const value = Math.max(0, Number(minutes) || 0);
    if (value % 1440 === 0) return `${value / 1440} day${value === 1440 ? "" : "s"}`;
    if (value % 60 === 0) return `${value / 60} hour${value === 60 ? "" : "s"}`;
    return `${Math.floor(value / 60)}h ${value % 60}m`;
  }

  function money(value) {
    return Number(value || 0).toLocaleString("en-US", { style: "currency", currency: "USD" });
  }

  function sanitizePromo(value) {
    return String(value || "").trim().toUpperCase().replace(/[^A-Z0-9-]/g, "").slice(0, 24);
  }

  function isUuid(value) {
    return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(value || ""));
  }

  function setStatus(message) {
    elements.cars2Status.textContent = message;
    elements.cars2Status.hidden = !message;
  }

  function showError(element, message) {
    if (!element) return;
    element.textContent = message;
    element.hidden = false;
  }

  function hideError(element) {
    if (!element) return;
    element.textContent = "";
    element.hidden = true;
  }

  function friendlyError(error, fallback) {
    const message = String(error?.message || "");
    return /failed to fetch|network|load failed|connection|timeout/i.test(message)
      ? "The connection was interrupted. Check your internet connection and try again."
      : fallback;
  }

  function escapeHtml(value) {
    return String(value ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#039;");
  }
})();
