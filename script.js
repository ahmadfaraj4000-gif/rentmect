const RENT_ME_CT_ADDRESS = "485 Colt Hwy, Farmington, CT";

let selectedVehicleName = "";
let selectedRentalPeriod = "";
let lastRentalTimeNotice = "";

document.addEventListener("DOMContentLoaded", function () {
  populateTimeSelects();
  setMinDates();
  loadBookingDatesIntoForm();
  normalizeRentalDateInputs();
  normalizeRentalTimeInputs({ notify: true });
  restoreBookingPreview();
  window.syncVehicleAvailability?.();
});

function toggleMenu() {
  const nav = document.getElementById("mainNav");
  if (nav) nav.classList.toggle("open");
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
  const defaultReturn = getNextDateInputValue(today);

  pickup.min = today;
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
  botMessage.textContent = "Thanks for reaching out. For the fastest help, call or text Rent Me CT at 959-261-0721.";
  messages.appendChild(botMessage);

  input.value = "";
  messages.scrollTop = messages.scrollHeight;
}
