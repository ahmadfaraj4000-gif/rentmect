(() => {
  "use strict";

  const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  let pickerCount = 0;

  function parseDate(value) {
    const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(value || ""));
    if (!match) return null;
    const date = new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3])));
    return Number.isNaN(date.getTime()) ? null : date;
  }

  function dateValue(date) {
    return [
      date.getUTCFullYear(),
      String(date.getUTCMonth() + 1).padStart(2, "0"),
      String(date.getUTCDate()).padStart(2, "0"),
    ].join("-");
  }

  function addDays(value, days) {
    const date = parseDate(value);
    if (!date) return "";
    date.setUTCDate(date.getUTCDate() + days);
    return dateValue(date);
  }

  function todayValue() {
    const now = new Date();
    return [
      now.getFullYear(),
      String(now.getMonth() + 1).padStart(2, "0"),
      String(now.getDate()).padStart(2, "0"),
    ].join("-");
  }

  function monthStart(value) {
    const date = parseDate(value) || parseDate(todayValue());
    return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), 1));
  }

  function addMonths(date, months) {
    return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + months, 1));
  }

  function formatDate(value, options = {}) {
    const date = parseDate(value);
    if (!date) return "Choose date";
    return new Intl.DateTimeFormat("en-US", {
      timeZone: "UTC",
      month: options.long ? "long" : "short",
      day: "numeric",
      ...(options.year ? { year: "numeric" } : {}),
    }).format(date);
  }

  function sameMonth(left, right) {
    return left.getUTCFullYear() === right.getUTCFullYear()
      && left.getUTCMonth() === right.getUTCMonth();
  }

  class BookingRangePicker {
    constructor(root) {
      this.root = root;
      this.pickupInput = root.querySelector('[data-booking-date-input="pickup"]');
      this.returnInput = root.querySelector('[data-booking-date-input="return"]');
      this.pickupButton = root.querySelector('[data-booking-date-button="pickup"]');
      this.returnButton = root.querySelector('[data-booking-date-button="return"]');
      this.pickupDisplay = root.querySelector('[data-booking-date-display="pickup"]');
      this.returnDisplay = root.querySelector('[data-booking-date-display="return"]');
      if (!this.pickupInput || !this.returnInput || !this.pickupButton || !this.returnButton) return;

      this.card = root.closest(".availability-card");
      this.hero = root.closest(".hero");
      this.id = `booking-calendar-${++pickerCount}`;
      this.opened = false;
      this.selecting = "pickup";
      this.draftPickup = "";
      this.draftReturn = "";
      this.viewMonth = monthStart(this.pickupInput.value || todayValue());
      this.panel = this.buildPanel();
      root.append(this.panel);
      this.pickupButton.setAttribute("aria-controls", this.id);
      this.returnButton.setAttribute("aria-controls", this.id);

      this.pickupButton.addEventListener("click", () => this.open("pickup"));
      this.returnButton.addEventListener("click", () => this.open("return"));
      this.pickupInput.addEventListener("change", () => window.requestAnimationFrame(() => this.sync()));
      this.returnInput.addEventListener("change", () => window.requestAnimationFrame(() => this.sync()));
      this.panel.addEventListener("click", (event) => this.handlePanelClick(event));
      document.addEventListener("pointerdown", (event) => {
        if (this.opened && !this.root.contains(event.target)) this.close();
      });
      document.addEventListener("keydown", (event) => {
        if (this.opened && event.key === "Escape") {
          this.close();
          (this.selecting === "return" ? this.returnButton : this.pickupButton).focus();
        }
      });
      this.sync();
    }

    buildPanel() {
      const panel = document.createElement("section");
      panel.id = this.id;
      panel.className = "booking-calendar-panel";
      panel.setAttribute("aria-label", "Choose pickup and return dates");
      panel.hidden = true;
      panel.innerHTML = `
        <div class="booking-calendar-toolbar">
          <p class="booking-calendar-instruction" data-calendar-instruction>Select your pickup date.</p>
          <div class="booking-calendar-nav" aria-label="Calendar navigation">
            <button type="button" data-calendar-action="previous" aria-label="Previous month">‹</button>
            <button type="button" data-calendar-action="next" aria-label="Next month">›</button>
          </div>
        </div>
        <div class="booking-calendar-months" data-calendar-months></div>
        <div class="booking-calendar-actions">
          <p class="booking-calendar-selection" data-calendar-selection aria-live="polite"></p>
          <button class="booking-calendar-reset" type="button" data-calendar-action="reset">Reset</button>
          <button class="booking-calendar-apply" type="button" data-calendar-action="apply">Apply dates</button>
        </div>`;
      return panel;
    }

    get minimumPickup() {
      return this.pickupInput.min && this.pickupInput.min > todayValue()
        ? this.pickupInput.min
        : todayValue();
    }

    open(mode) {
      this.syncDraft();
      this.selecting = mode;
      const focusDate = mode === "return" ? this.draftReturn : this.draftPickup;
      this.viewMonth = monthStart(focusDate || this.draftPickup || this.minimumPickup);
      this.opened = true;
      this.panel.hidden = false;
      this.card?.classList.add("booking-calendar-open");
      this.hero?.classList.add("booking-calendar-open");
      this.pickupButton.setAttribute("aria-expanded", "true");
      this.returnButton.setAttribute("aria-expanded", "true");
      this.render();
    }

    close() {
      this.opened = false;
      this.panel.hidden = true;
      this.card?.classList.remove("booking-calendar-open");
      this.hero?.classList.remove("booking-calendar-open");
      this.pickupButton.setAttribute("aria-expanded", "false");
      this.returnButton.setAttribute("aria-expanded", "false");
    }

    syncDraft() {
      this.draftPickup = this.pickupInput.value || this.minimumPickup;
      this.draftReturn = this.returnInput.value || addDays(this.draftPickup, 1);
      if (this.draftReturn <= this.draftPickup) this.draftReturn = addDays(this.draftPickup, 1);
    }

    sync() {
      this.pickupDisplay.textContent = formatDate(this.pickupInput.value, { year: true });
      this.returnDisplay.textContent = formatDate(this.returnInput.value, { year: true });
      this.pickupButton.setAttribute("aria-label", `Pickup date: ${formatDate(this.pickupInput.value, { long: true, year: true })}`);
      this.returnButton.setAttribute("aria-label", `Return date: ${formatDate(this.returnInput.value, { long: true, year: true })}`);
      if (this.opened) {
        this.syncDraft();
        this.render();
      }
    }

    handlePanelClick(event) {
      const day = event.target.closest("[data-calendar-date]");
      if (day && !day.disabled) {
        this.chooseDate(day.dataset.calendarDate);
        return;
      }
      const action = event.target.closest("[data-calendar-action]")?.dataset.calendarAction;
      if (action === "previous") this.viewMonth = addMonths(this.viewMonth, -1);
      if (action === "next") this.viewMonth = addMonths(this.viewMonth, 1);
      if (action === "reset") {
        this.draftPickup = this.minimumPickup;
        this.draftReturn = addDays(this.minimumPickup, 1);
        this.selecting = "pickup";
        this.viewMonth = monthStart(this.minimumPickup);
      }
      if (action === "apply") {
        this.apply();
        return;
      }
      this.render();
    }

    chooseDate(value) {
      if (this.selecting === "pickup") {
        this.draftPickup = value;
        if (!this.draftReturn || this.draftReturn <= value) this.draftReturn = "";
        this.selecting = "return";
      } else if (value <= this.draftPickup) {
        this.draftPickup = value;
        this.draftReturn = "";
        this.selecting = "return";
      } else {
        this.draftReturn = value;
        this.selecting = "complete";
      }
      this.render();
    }

    apply() {
      if (!this.draftPickup || !this.draftReturn || this.draftReturn <= this.draftPickup) return;
      const changes = [
        [this.pickupInput, this.draftPickup],
        [this.returnInput, this.draftReturn],
      ];
      changes.forEach(([input, value]) => {
        if (input.value === value) return;
        input.value = value;
        input.dispatchEvent(new Event("input", { bubbles: true }));
        input.dispatchEvent(new Event("change", { bubbles: true }));
      });
      this.close();
      window.requestAnimationFrame(() => this.sync());
    }

    render() {
      const months = this.panel.querySelector("[data-calendar-months]");
      months.innerHTML = [this.viewMonth, addMonths(this.viewMonth, 1)]
        .map((month) => this.renderMonth(month))
        .join("");

      const instruction = this.panel.querySelector("[data-calendar-instruction]");
      instruction.textContent = this.selecting === "pickup"
        ? "Select your pickup date."
        : this.selecting === "return"
          ? "Now select your return date."
          : "Your rental dates are ready.";

      const selection = this.panel.querySelector("[data-calendar-selection]");
      selection.textContent = this.draftPickup && this.draftReturn
        ? `${formatDate(this.draftPickup, { year: true })} → ${formatDate(this.draftReturn, { year: true })}`
        : this.draftPickup
          ? `Pickup ${formatDate(this.draftPickup, { year: true })}`
          : "Choose both dates";

      const previous = this.panel.querySelector('[data-calendar-action="previous"]');
      previous.disabled = sameMonth(this.viewMonth, monthStart(this.minimumPickup))
        || this.viewMonth < monthStart(this.minimumPickup);
      this.panel.querySelector('[data-calendar-action="apply"]').disabled = !this.draftPickup
        || !this.draftReturn
        || this.draftReturn <= this.draftPickup;
    }

    renderMonth(month) {
      const label = new Intl.DateTimeFormat("en-US", {
        timeZone: "UTC",
        month: "long",
        year: "numeric",
      }).format(month);
      const daysInMonth = new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth() + 1, 0)).getUTCDate();
      const blanks = Array.from({ length: month.getUTCDay() }, () => '<span class="booking-calendar-blank" aria-hidden="true"></span>').join("");
      const days = Array.from({ length: daysInMonth }, (_, index) => {
        const value = dateValue(new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth(), index + 1)));
        const classes = ["booking-calendar-day"];
        if (value === todayValue()) classes.push("today");
        if (value === this.draftPickup) classes.push("range-start");
        if (value === this.draftReturn) classes.push("range-end");
        if (this.draftPickup && this.draftReturn && value > this.draftPickup && value < this.draftReturn) classes.push("in-range");
        const disabled = value < this.minimumPickup;
        const accessibleLabel = formatDate(value, { long: true, year: true });
        return `<button class="${classes.join(" ")}" type="button" data-calendar-date="${value}" aria-label="${accessibleLabel}"${disabled ? " disabled" : ""}>${index + 1}</button>`;
      }).join("");
      return `
        <section class="booking-calendar-month" aria-label="${label}">
          <h3>${label}</h3>
          <div class="booking-calendar-weekdays" aria-hidden="true">${WEEKDAYS.map((day) => `<span>${day}</span>`).join("")}</div>
          <div class="booking-calendar-grid">${blanks}${days}</div>
        </section>`;
    }
  }

  function initializePickers() {
    const pickers = [...document.querySelectorAll("[data-booking-range-picker]")]
      .map((root) => new BookingRangePicker(root))
      .filter((picker) => picker.pickupInput);
    window.syncBookingRangePickers = () => pickers.forEach((picker) => picker.sync());
    window.requestAnimationFrame(window.syncBookingRangePickers);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initializePickers, { once: true });
  } else {
    initializePickers();
  }
})();
