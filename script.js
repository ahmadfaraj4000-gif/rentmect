const RENT_ME_CT_ADDRESS = "12 Holmes Circle, Farmington, CT";

let selectedVehicleName = "";
let selectedRentalPeriod = "";
let lastRentalTimeNotice = "";

document.addEventListener("DOMContentLoaded", function () {
  setupWeekendPromotion();
  populateTimeSelects();
  setMinDates();
  loadBookingDatesIntoForm();
  normalizeRentalDateInputs();
  normalizeRentalTimeInputs({ notify: true });
  restoreBookingPreview();
  setupContactModal();
  window.syncVehicleAvailability?.();
});

const WEEKEND_PROMO_END = new Date("2026-07-21T00:00:00-04:00");
const WEEKEND_PROMO_SEEN_KEY = "rentmect_weekend071726_seen";
let weekendPromoTimer = null;
let weekendPromoBannerObserver = null;
let weekendPromoBannerResizeHandler = null;

function setupWeekendPromotion() {
  const promoModal = document.getElementById("weekendPromoModal");
  const countdowns = [...document.querySelectorAll("[data-promo-countdown]")];
  const promoSurfaces = [...document.querySelectorAll("[data-promo-surface]")];
  const promotionIsActive = Date.now() < WEEKEND_PROMO_END.getTime();

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

  if (!promoModal || hasSeenWeekendPromotion()) return;

  markWeekendPromotionSeen();
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

function hasSeenWeekendPromotion() {
  try {
    return localStorage.getItem(WEEKEND_PROMO_SEEN_KEY) === "true";
  } catch {
    return false;
  }
}

function markWeekendPromotionSeen() {
  try {
    localStorage.setItem(WEEKEND_PROMO_SEEN_KEY, "true");
  } catch {
    // The promotion still works when storage is unavailable.
  }
}

function openWeekendPromoModal() {
  const modal = document.getElementById("weekendPromoModal");
  if (!modal || Date.now() >= WEEKEND_PROMO_END.getTime()) return;

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
  const remaining = WEEKEND_PROMO_END.getTime() - Date.now();

  if (remaining <= 0) {
    window.clearInterval(weekendPromoTimer);
    document.querySelectorAll("[data-promo-surface]").forEach((surface) => surface.hidden = true);
    teardownWeekendPromoBannerLayout();
    closeWeekendPromoModal();
    document.getElementById("weekendPromoModal")?.remove();
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
  const code = button.dataset.promoCopy || "WEEKEND071726";
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
  if (nav) nav.classList.toggle("open");
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

  document.querySelectorAll('nav a[href^="tel:"], .site-footer a[href^="tel:"], a[data-contact-modal]').forEach((link) => {
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
  for (let hour = 9; hour <= 21; hour++) {
    const suffix = hour >= 12 ? "PM" : "AM";
    const displayHour = hour > 12 ? hour - 12 : hour;
    times.push(`${displayHour}:00 ${suffix}`);
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
  if (!noticeKey || lastRentalTimeNotice === noticeKey) return;

  lastRentalTimeNotice = noticeKey;
  alert(message);
}

function normalizeRentalTimeInputs(options = {}) {
  const shouldNotify = Boolean(options.notify);
  const pickupDate = document.getElementById("pickupDate");
  const returnDate = document.getElementById("returnDate");
  const pickupTime = document.getElementById("pickupTime");
  const returnTime = document.getElementById("returnTime");

  if (!pickupDate || !returnDate || !pickupTime || !returnTime) return;

  const today = getLocalDateInputValue();
  if (pickupDate.value === today) {
    const nextTime = getFirstFutureRentalTime(today);

    if (!nextTime) {
      const nextPickupDate = getNextDateInputValue(today);
      pickupDate.value = getNextDateInputValue(today);
      returnDate.min = getNextDateInputValue(pickupDate.value);
      if (returnDate.value < returnDate.min) returnDate.value = returnDate.min;
      pickupTime.value = "9:00 AM";
      if (shouldNotify) {
        notifyRentalTimeAdjusted(
          "Pickup is closed for today. Please choose a pickup time starting tomorrow.",
          `closed-${nextPickupDate}`
        );
      }
    } else {
      const selectedPickup = getRentalDateTime(today, pickupTime.value);
      if (!selectedPickup || selectedPickup <= new Date()) {
        pickupTime.value = nextTime;
        if (shouldNotify) {
          notifyRentalTimeAdjusted(
            `That pickup time has passed, so we moved pickup to ${nextTime}.`,
            `time-${today}-${nextTime}`
          );
        }
      }
    }
  }

  if (!returnTime.value) returnTime.value = "9:00 AM";
  window.syncVehicleAvailability?.();
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

  document.getElementById("pickupTime")?.addEventListener("change", () => normalizeRentalTimeInputs({ notify: true }));
  document.getElementById("returnTime")?.addEventListener("change", () => normalizeRentalTimeInputs({ notify: true }));

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
  const pickupTime = params.get("pickupTime") || bookingData.pickupTime || bookingData.pickup_time || "9:00 AM";
  const returnTime = params.get("returnTime") || bookingData.returnTime || bookingData.return_time || "9:00 AM";

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
    response: "Pickup and drop-off services may be offered only when Rent Me CT approves them. Local pickup or return transportation within 15 miles may carry a $30 fee each way. Call or text 959-261-0721 to confirm whether it is available for your rental."
  },
  {
    keywords: ["pickup", "pick up", "return", "address", "location", "where are you", "where located", "hours", "open", "time window"],
    response: "Rent Me CT pickup and return are based at 12 Holmes Circle, Farmington, CT. Pickup and return times are available from 9 AM to 9 PM unless another arrangement is approved."
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
    response: "For the fastest help, call or text Rent Me CT at 959-261-0721."
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

  return "I may not have the exact answer to that yet. You can ask me about requirements, insurance, deposits, mileage, pickup/drop-off, late returns, damage, tolls, smoking, vehicle rules, availability, or call/text 959-261-0721 for help.";
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
