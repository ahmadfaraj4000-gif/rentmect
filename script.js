const RENT_ME_CT_ADDRESS = "485 Colt Hwy, Farmington, CT";
const RENTMECT_CLIENT_PORTAL_URL = "http://localhost:5173";

let selectedVehicleName = "";
let selectedRentalPeriod = "";

document.addEventListener("DOMContentLoaded", function () {
  populateTimeSelects();
  setMinDates();
  loadBookingDatesIntoForm();
  restoreBookingPreview();
});

function toggleMenu() {
  const nav = document.getElementById("mainNav");
  if (nav) nav.classList.toggle("open");
}

function populateTimeSelects() {
  const pickup = document.getElementById("pickupTime");
  const dropoff = document.getElementById("returnTime");

  if (!pickup || !dropoff) return;

  const times = [];
  for (let hour = 9; hour <= 21; hour++) {
    const suffix = hour >= 12 ? "PM" : "AM";
    const displayHour = hour > 12 ? hour - 12 : hour;
    times.push(`${displayHour}:00 ${suffix}`);
  }

  [pickup, dropoff].forEach((select) => {
    select.innerHTML = "";
    times.forEach((time) => {
      const option = document.createElement("option");
      option.value = time;
      option.textContent = time;
      select.appendChild(option);
    });
  });

  pickup.value = "9:00 AM";
  dropoff.value = "9:00 AM";
}

function setMinDates() {
  const today = new Date();
  const yyyyMmDd = today.toISOString().split("T")[0];

  const pickup = document.getElementById("pickupDate");
  const dropoff = document.getElementById("returnDate");

  if (pickup) pickup.min = yyyyMmDd;
  if (dropoff) dropoff.min = yyyyMmDd;
}
function loadBookingDatesIntoForm() {
  let bookingData = {};

  const saved = localStorage.getItem("rentmect_pending_booking");

  try {
    bookingData = saved ? JSON.parse(saved) : {};
  } catch {
    bookingData = {};
  }

  const params = new URLSearchParams(window.location.search);

  const pickupDate = params.get("pickupDate") || bookingData.pickupDate || "";
  const returnDate = params.get("returnDate") || bookingData.returnDate || "";
  const pickupTime = params.get("pickupTime") || bookingData.pickupTime || "9:00 AM";
  const returnTime = params.get("returnTime") || bookingData.returnTime || "9:00 AM";

  const pickupInput = document.getElementById("pickupDate");
  const returnInput = document.getElementById("returnDate");
  const pickupSelect = document.getElementById("pickupTime");
  const returnSelect = document.getElementById("returnTime");

  if (pickupInput && pickupDate) pickupInput.value = pickupDate;
  if (returnInput && returnDate) returnInput.value = returnDate;
  if (pickupSelect && pickupTime) pickupSelect.value = pickupTime;
  if (returnSelect && returnTime) returnSelect.value = returnTime;
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

  const pickup = new Date(`${pickupDate}T09:00:00`);
  const dropoff = new Date(`${returnDate}T09:00:00`);
  const diffDays = Math.ceil((dropoff - pickup) / (1000 * 60 * 60 * 24));

  if (diffDays < 2) {
    alert("Minimum rental period is 2 days. Please choose a return date at least 2 days after pickup.");
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

  const params = new URLSearchParams(bookingData);
  window.location.href = `cars.html?${params.toString()}`;
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

function selectCar(vehicleName) {
  selectedVehicleName = vehicleName;
  localStorage.setItem("rentmect_vehicle", vehicleName);

  let existingBooking = {};

  try {
    existingBooking = JSON.parse(localStorage.getItem("rentmect_pending_booking")) || {};
  } catch {
    existingBooking = {};
  }

  const bookingData = {
    ...existingBooking,
    selectedVehicle: vehicleName
  };

  localStorage.setItem("rentmect_pending_booking", JSON.stringify(bookingData));

  const selectedVehicle = document.getElementById("selectedVehicle");
  if (selectedVehicle) selectedVehicle.textContent = vehicleName;

  const checkout = document.getElementById("checkoutPreview");
  if (checkout) checkout.scrollIntoView({ behavior: "smooth" });

  const params = new URLSearchParams(bookingData);
  window.location.href = `${RENTMECT_CLIENT_PORTAL_URL}?${params.toString()}`;
}

function restoreBookingPreview() {
  const savedVehicle = localStorage.getItem("rentmect_vehicle");
  const savedPeriod = localStorage.getItem("rentmect_period");

  const selectedVehicle = document.getElementById("selectedVehicle");
  const selectedPeriod = document.getElementById("selectedPeriod");

  if (savedVehicle && selectedVehicle) selectedVehicle.textContent = savedVehicle;
  if (savedPeriod && selectedPeriod) selectedPeriod.textContent = savedPeriod;
}

function mockCheckout() {
  const vehicle = localStorage.getItem("rentmect_vehicle");
  const savedBooking = localStorage.getItem("rentmect_pending_booking");

  let bookingData = {};

  try {
    bookingData = savedBooking ? JSON.parse(savedBooking) : {};
  } catch {
    bookingData = {};
  }

  if (!vehicle && !bookingData.selectedVehicle) {
    alert("Please choose a vehicle first.");
    return;
  }

  if (!bookingData.pickupDate || !bookingData.returnDate || !bookingData.pickupTime || !bookingData.returnTime) {
    alert("Please choose your pickup and return dates first.");
    return;
  }

  const finalBookingData = {
    ...bookingData,
    selectedVehicle: bookingData.selectedVehicle || vehicle
  };

  localStorage.setItem("rentmect_pending_booking", JSON.stringify(finalBookingData));

  const params = new URLSearchParams(finalBookingData);
  window.location.href = `${RENTMECT_CLIENT_PORTAL_URL}?${params.toString()}`;
}

function submitContact(event) {
  event.preventDefault();
  alert("Message saved for frontend demo. Next phase: this will send to Supabase admin messages.");
  event.target.reset();
}

function toggleChatbot() {
  const chatbot = document.getElementById("chatbot");
  if (chatbot) chatbot.classList.toggle("open");
}

function sendChatMessage(event) {
  event.preventDefault();

  const input = document.getElementById("chatInput");
  const messages = document.getElementById("chatMessages");

  if (!input || !messages) return;

  const text = input.value.trim();
  if (!text) return;

  addMessage(text, "user-message");
  input.value = "";

  const response = getBotResponse(text);
  setTimeout(() => addMessage(response, "bot-message"), 350);
}

function addMessage(text, className) {
  const messages = document.getElementById("chatMessages");
  const div = document.createElement("div");
  div.className = className;
  div.textContent = text;
  messages.appendChild(div);
  messages.scrollTop = messages.scrollHeight;
}

function getBotResponse(message) {
  const msg = message.toLowerCase();

  if (msg.includes("book") || msg.includes("reserve") || msg.includes("rent")) {
    return "To book, choose your pickup and return dates, select a car, create an account, upload your license and insurance, sign the rental agreement, then pay the rental amount, tax, and deposit.";
  }

  if (msg.includes("deposit")) {
    return "Yes, a security deposit is required. The amount depends on the vehicle class and rental risk. Deposits and post-rental charges can cover damage, cleaning, tolls, tickets, late returns, or policy violations.";
  }

  if (msg.includes("license") || msg.includes("driver")) {
    return "You need a valid, unexpired driver’s license. Renters must be at least 21 years old, and renters under 25 may have a young driver fee.";
  }

  if (msg.includes("insurance")) {
    return "You must upload proof of valid auto insurance before pickup. Rent Me CT does not provide primary insurance unless it is specifically provided in writing.";
  }

  if (msg.includes("mileage") || msg.includes("miles")) {
    return "Each rental includes 200 miles per day. Extra mileage is charged at $0.35 per mile unless unlimited mileage is purchased when available.";
  }

  if (msg.includes("airport") || msg.includes("bradley")) {
    return "Rent Me CT is located in Farmington, Connecticut and is convenient for travelers near Bradley International Airport and the greater Hartford area.";
  }

  if (msg.includes("return") || msg.includes("drop off") || msg.includes("bring back")) {
    return `Vehicles return to Rent Me CT at ${RENT_ME_CT_ADDRESS}. In the client portal, we will add a button that opens the address in Maps.`;
  }

  if (msg.includes("smoke") || msg.includes("smoking")) {
    return "Smoking is not allowed in any rental vehicle. Smoke odor, ash, or residue may result in cleaning and remediation fees.";
  }

  if (msg.includes("late") || msg.includes("overdue")) {
    return "Late returns may result in additional rental charges. The client portal will send reminders 1 day before and 6 hours before the rental ends.";
  }

  if (msg.includes("damage") || msg.includes("accident")) {
    return "Report any accident, theft, or damage immediately. Customers are responsible for damage during the rental period, and pickup/return photos may be required.";
  }

  if (msg.includes("hello") || msg.includes("hi") || msg.includes("hey")) {
    return "Hey! Welcome to Rent Me CT. Are you looking for a sedan, SUV, luxury vehicle, or truck?";
  }

  return "I can help with booking, deposits, insurance, license uploads, mileage, pickup, return, late fees, and rental rules. What do you want to know?";
}