import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey, x-rentmect-notification-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type NotificationEvent = {
  event_id: string;
  event_type: "reservation_started" | "reservation_stalled" | "new_booking" | "document_pending_review" | "return_due_today" | "maintenance_due" | "maintenance_due_soon" | "maintenance_override" | "extension_requested" | "extension_approved" | "emergency_exception_created" | "rental_payment_received" | "extension_payment_received" | "rental_overdue" | "vehicle_price_changed" | "rental_return_initiated" | "customer_message_received" | "vehicle_report_submitted" | "toll_needs_review" | "toll_sync_failed" | "customer_charge_failed" | "refund_failed" | "deposit_release_failed" | "rental_cancelled" | "rental_ready_for_pickup" | "identity_verification_failed" | "extension_payment_failed" | "rental_payment_failed" | "chargeback_created" | "stripe_reconciliation_required";
  source_id: string;
  rental_id: string | null;
  attempts: number;
  metadata?: Record<string, unknown>;
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const pushoverAppToken = Deno.env.get("PUSHOVER_APP_TOKEN") || "";
const pushoverUserKey = Deno.env.get("PUSHOVER_USER_KEY") || "";
const adminPortalUrl = Deno.env.get("RENTMECT_ADMIN_PORTAL_URL") || "";

const adminClient = createClient(supabaseUrl, serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : "Unknown notification error.";
}

function readableDate(date: string | null, time: string | null) {
  if (!date) return "time pending";
  const formatted = new Intl.DateTimeFormat("en-US", {
    timeZone: "UTC",
    month: "short",
    day: "numeric",
    year: "numeric",
  }).format(new Date(`${date}T12:00:00Z`));
  return `${formatted}${time ? ` at ${time} ET` : ""}`;
}

function adminDestination(params: Record<string, string>) {
  if (!adminPortalUrl) return "";
  try {
    const url = new URL(adminPortalUrl);
    Object.entries(params).forEach(([key, value]) => url.searchParams.set(key, value));
    return url.toString();
  } catch {
    return adminPortalUrl;
  }
}

async function sendPushover(
  title: string,
  message: string,
  priority = "0",
  destinationParams: Record<string, string> = {},
  destinationTitle = "Open Rent Me CT Admin",
) {
  const form = new URLSearchParams({
    token: pushoverAppToken,
    user: pushoverUserKey,
    title,
    message,
    priority,
  });

  if (adminPortalUrl) {
    form.set("url", adminDestination(destinationParams));
    form.set("url_title", destinationTitle);
  }

  const response = await fetch("https://api.pushover.net/1/messages.json", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: form,
  });
  const payload = await response.json().catch(() => ({}));

  if (!response.ok || payload?.status !== 1) {
    const detail = Array.isArray(payload?.errors)
      ? payload.errors.join(" ")
      : `Pushover returned HTTP ${response.status}.`;
    throw new Error(detail);
  }

  return String(payload.request || "");
}

async function rentalDetails(rentalId: string) {
  const { data: rental, error } = await adminClient
    .from("rentals")
    .select("id, user_id, vehicle_id, pickup_date, pickup_time, return_date, return_time, rental_total, status, merchant_id, merchant_reservation_number, merchants(name)")
    .eq("id", rentalId)
    .maybeSingle();
  if (error) throw new Error(error.message);
  if (!rental) throw new Error("Stale notification: rental no longer exists.");

  const [profileResult, vehicleResult] = await Promise.all([
    adminClient.from("profiles").select("full_name, phone").eq("id", rental.user_id).maybeSingle(),
    adminClient.from("vehicles").select("name").eq("id", rental.vehicle_id).maybeSingle(),
  ]);

  return {
    rental,
    customer: profileResult.data?.full_name || profileResult.data?.phone || "Customer",
    customerPhone: profileResult.data?.phone || "",
    vehicle: vehicleResult.data?.name || "vehicle pending",
  };
}

async function pendingReservationDetails(pendingBookingId: string) {
  const { data: booking, error } = await adminClient
    .from("pending_bookings")
    .select("id, user_id, vehicle_id, selected_vehicle_name, pickup_date, pickup_time, return_date, return_time, status, source, expires_at, customer_email, customer_phone")
    .eq("id", pendingBookingId)
    .maybeSingle();
  if (error) throw new Error(error.message);
  if (!booking) throw new Error("Stale notification: pending reservation no longer exists.");

  const [profileResult, vehicleResult] = await Promise.all([
    booking.user_id
      ? adminClient.from("profiles").select("full_name, email, phone").eq("id", booking.user_id).maybeSingle()
      : Promise.resolve({ data: null }),
    booking.vehicle_id
      ? adminClient.from("vehicles").select("name").eq("id", booking.vehicle_id).maybeSingle()
      : Promise.resolve({ data: null }),
  ]);
  const contact = profileResult.data?.phone || booking.customer_phone ||
    profileResult.data?.email || booking.customer_email || "contact not available yet";
  return {
    booking,
    customer: profileResult.data?.full_name || booking.customer_email || "A customer",
    contact,
    vehicle: vehicleResult.data?.name || booking.selected_vehicle_name || "vehicle not selected yet",
  };
}

async function deliver(event: NotificationEvent) {
  if (event.metadata?.notification_test === true) {
    if (event.event_type === "rental_payment_received") {
      return await sendPushover(
        "[TEST] PAID RENTAL — DOCUMENT REVIEW REQUIRED",
        "Test Customer (860-555-0100) paid for Test Vehicle. Review the uploaded driver license and insurance before pickup.",
        "0",
        { tab: "documents" },
        "Review Uploaded Documents",
      );
    }
    if (event.event_type === "extension_requested") {
      return await sendPushover(
        "[TEST] EXTENSION REQUEST — REVIEW REQUIRED",
        "Test Customer (860-555-0100) requested a rental extension. Review the request; approval stays locked until the customer uploads new extension insurance and an admin approves it.",
        "0",
        { tab: "queue" },
        "Review Extension Request",
      );
    }
    if (event.event_type === "document_pending_review") {
      return await sendPushover(
        "[TEST] DOCUMENT UPLOADED — REVIEW REQUIRED",
        "Test Customer (860-555-0100) uploaded a rental document. Open Documents now to approve or reject it.",
        "0",
        { tab: "documents" },
        "Review Uploaded Document",
      );
    }
  }

  if (event.metadata?.deployment_test === true) {
    return await sendPushover(
      "Rent Me CT Pushover deployment test",
      "Production database queue, Edge Function worker, and Pushover delivery are connected.",
      "0",
      { tab: "queue" },
    );
  }

  if (event.event_type === "stripe_reconciliation_required") {
    const { data: issue, error } = await adminClient
      .from("stripe_reconciliation_issues")
      .select("id, issue_type, target_type, rental_id, amount, currency, status, error_message, payment_intent_id, refund_id")
      .eq("id", event.source_id)
      .single();
    if (error || !issue) throw new Error(error?.message || "Stripe reconciliation issue not found.");
    const reference = issue.refund_id || issue.payment_intent_id || issue.id;
    const amount = Number(issue.amount || 0);
    const amountText = amount > 0 ? `$${amount.toFixed(2)} ` : "";
    return await sendPushover(
      "STRIPE RECONCILIATION REQUIRED",
      `${amountText}${String(issue.issue_type || "payment issue").replaceAll("_", " ")} is ${issue.status}. ${issue.error_message || "Open Payments immediately."} Reference …${String(reference).slice(-8)}.`,
      "1",
      issue.rental_id
        ? { tab: "payments", rental: issue.rental_id }
        : { tab: "payments" },
      "Open Payment Reconciliation",
    );
  }

  if (event.event_type === "emergency_exception_created") {
    const { data: exception, error } = await adminClient
      .from("rental_emergency_exceptions")
      .select("id, rental_id, exception_scopes, reason, expires_at")
      .eq("id", event.source_id)
      .single();
    if (error || !exception) throw new Error(error?.message || "Emergency exception not found.");
    const { customer, vehicle } = await rentalDetails(exception.rental_id);
    return await sendPushover(
      "EMERGENCY RENTAL EXCEPTION",
      `${customer} was released with ${vehicle} while ${exception.exception_scopes.join(", ")} remained incomplete. Reason: ${exception.reason}. Expires ${new Date(exception.expires_at).toLocaleString("en-US", { timeZone: "America/New_York" })} ET.`,
      "1",
    );
  }

  if (event.event_type === "reservation_started" || event.event_type === "reservation_stalled") {
    const { booking, customer, contact, vehicle } = await pendingReservationDetails(event.source_id);
    const pending = String(booking.status || "pending").toLowerCase() === "pending" &&
      new Date(booking.expires_at).getTime() > Date.now();
    if (event.event_type === "reservation_stalled" && !pending) {
      return "skipped-resolved-reservation";
    }
    const expires = new Date(booking.expires_at).toLocaleString("en-US", {
      timeZone: "America/New_York",
      month: "short",
      day: "numeric",
      hour: "numeric",
      minute: "2-digit",
    });
    return await sendPushover(
      event.event_type === "reservation_stalled"
        ? "RESERVATION STILL INCOMPLETE"
        : "Reservation started",
      `${customer} (${contact}) ${event.event_type === "reservation_stalled" ? "is still working on" : "started"} ${vehicle}. Pickup ${readableDate(booking.pickup_date, booking.pickup_time)}; return ${readableDate(booking.return_date, booking.return_time)}. Hold expires ${expires} ET.`,
      event.event_type === "reservation_stalled" ? "1" : "0",
      { tab: "queue" },
      "Open Reservation Queue",
    );
  }

  if (event.event_type === "new_booking") {
    const merchantTest = event.metadata?.notification_test === true && event.metadata?.merchant_test === true;
    const { rental, customer, vehicle } = merchantTest ? {
      rental: { id: "TEST-ONLY", merchant_id: "TEST-ONLY", merchant_reservation_number: "RM-TEST-0001", merchants: { name: "CarCraft" }, rental_total: 0, pickup_date: null, pickup_time: null, return_date: null, return_time: null },
      customer: "TEST ONLY — no real reservation or payment. Synthetic Test Customer",
      vehicle: "Booking Flow Test Vehicle",
    } : await rentalDetails(event.rental_id || event.source_id);
    const total = Number(rental.rental_total || 0);
    const totalText = Number.isFinite(total) && total > 0 ? ` Total $${total.toFixed(2)}.` : "";
    const requestId = await sendPushover(
      `${merchantTest ? "[TEST] " : ""}${rental.merchant_id ? "MERCHANT RENTAL — NEW RESERVATION" : "New Rent Me CT booking"}`,
      `${rental.merchant_id ? `Merchant: ${(Array.isArray(rental.merchants) ? rental.merchants[0] : rental.merchants)?.name || "Partner"}. Reservation ${rental.merchant_reservation_number || rental.id}. ` : ""}${customer} booked ${vehicle}. Pickup ${readableDate(rental.pickup_date, rental.pickup_time)}; return ${readableDate(rental.return_date, rental.return_time)}.${totalText}`,
      "0",
      merchantTest ? { tab: "rentals" } : { tab: "rentals", rental: rental.id },
    );
    return requestId;
  }

  if (event.event_type === "return_due_today") {
    const { rental, customer, vehicle } = await rentalDetails(event.rental_id || event.source_id);
    return await sendPushover(
      "Rental return due today",
      `${customer} is due to return ${vehicle} ${readableDate(rental.return_date, rental.return_time)}.`,
      "1",
      { tab: "rentals", rental: rental.id },
    );
  }

  if (event.event_type === "rental_overdue") {
    const { rental, customer, vehicle } = await rentalDetails(event.rental_id || event.source_id);
    const { data: nextRentals, error: nextRentalError } = await adminClient
      .from("rentals")
      .select("id, pickup_date, pickup_time, status")
      .eq("vehicle_id", rental.vehicle_id)
      .neq("id", rental.id)
      .not("status", "in", "(completed,cancelled)")
      .gte("pickup_date", rental.return_date)
      .order("pickup_date", { ascending: true })
      .order("pickup_time", { ascending: true })
      .limit(1);
    if (nextRentalError) throw new Error(nextRentalError.message);

    const nextRental = nextRentals?.[0];
    const nextBookingWarning = nextRental
      ? ` NEXT BOOKING AT RISK: ${readableDate(nextRental.pickup_date, nextRental.pickup_time)}.`
      : "";

    return await sendPushover(
      "LATE RETURN — VEHICLE HARD-LOCKED",
      `${customer}'s ${vehicle} rental is past its scheduled return (${readableDate(rental.return_date, rental.return_time)}). The vehicle cannot be booked until physical return and admin inspection. No automatic late charge has been created.${nextBookingWarning}`,
      "1",
      { tab: "rentals", rental: rental.id },
    );
  }

  if (event.event_type === "vehicle_price_changed") {
    const { data: vehicle, error } = await adminClient
      .from("vehicles")
      .select("id, name, daily_rate, security_deposit, included_miles_per_day, extra_mile_rate")
      .eq("id", event.source_id)
      .single();
    if (error || !vehicle) throw new Error(error?.message || "Vehicle not found.");
    const changes = [
      event.metadata?.old_daily_rate !== event.metadata?.new_daily_rate
        ? `daily rate $${Number(event.metadata?.old_daily_rate || 0).toFixed(2)} → $${Number(event.metadata?.new_daily_rate || 0).toFixed(2)}`
        : "",
      event.metadata?.old_security_deposit !== event.metadata?.new_security_deposit
        ? `deposit $${Number(event.metadata?.old_security_deposit || 0).toFixed(2)} → $${Number(event.metadata?.new_security_deposit || 0).toFixed(2)}`
        : "",
      event.metadata?.old_included_miles_per_day !== event.metadata?.new_included_miles_per_day
        ? `included miles ${event.metadata?.old_included_miles_per_day ?? "unset"} → ${event.metadata?.new_included_miles_per_day ?? "unset"}`
        : "",
      event.metadata?.old_extra_mile_rate !== event.metadata?.new_extra_mile_rate
        ? `extra-mile rate $${Number(event.metadata?.old_extra_mile_rate || 0).toFixed(2)} → $${Number(event.metadata?.new_extra_mile_rate || 0).toFixed(2)}`
        : "",
    ].filter(Boolean);
    return await sendPushover(
      "Fleet price changed",
      `${vehicle.name || "A fleet vehicle"}: ${changes.join("; ") || "pricing configuration changed"}.`,
      "0",
      { tab: "vehicles" },
    );
  }

  if ([
    "rental_return_initiated",
    "rental_cancelled",
    "rental_ready_for_pickup",
    "rental_payment_failed",
    "deposit_release_failed",
    "identity_verification_failed",
    "chargeback_created",
  ].includes(event.event_type)) {
    const { rental, customer, vehicle } = await rentalDetails(event.rental_id || event.source_id);
    const content: Record<string, { title: string; message: string; priority: string }> = {
      rental_return_initiated: {
        title: "RETURN REPORTED — INSPECTION REQUIRED",
        message: `${customer} reported ${vehicle} returned. Inspect mileage, fuel, and condition before releasing the vehicle or deposit.`,
        priority: "1",
      },
      rental_cancelled: {
        title: "Rental cancelled",
        message: `${customer}'s ${vehicle} rental was cancelled. Review payment/refund obligations and the released schedule.`,
        priority: "1",
      },
      rental_ready_for_pickup: {
        title: "Rental ready for pickup action",
        message: `${customer}'s ${vehicle} rental is ready. Confirm all release checks and enter starting mileage at pickup.`,
        priority: "0",
      },
      rental_payment_failed: {
        title: "RENTAL PAYMENT FAILED",
        message: `${customer}'s payment for ${vehicle} failed. Review the booking and contact the customer.`,
        priority: "1",
      },
      deposit_release_failed: {
        title: "DEPOSIT REFUND FAILED",
        message: `${customer}'s deposit return for ${vehicle} failed. Error: ${String(event.metadata?.error || "Open the rental for details")}.`,
        priority: "1",
      },
      identity_verification_failed: {
        title: "Stripe Identity needs admin attention",
        message: `${customer}'s Identity verification for ${vehicle} is ${String(event.metadata?.identity_status || "blocked")}. Error: ${String(event.metadata?.error_code || "not provided")}.`,
        priority: "1",
      },
      chargeback_created: {
        title: "STRIPE CHARGEBACK — IMMEDIATE ACTION",
        message: `${customer}'s ${vehicle} payment was disputed for $${Number(event.metadata?.amount || 0).toFixed(2)}. Reason: ${String(event.metadata?.reason || "unspecified")}.`,
        priority: "1",
      },
    };
    const selected = content[event.event_type];
    return await sendPushover(
      selected.title,
      selected.message,
      selected.priority,
      { tab: "rentals", rental: rental.id },
    );
  }

  if (event.event_type === "customer_message_received") {
    const { data: message, error } = await adminClient
      .from("rental_messages")
      .select("id, rental_id, user_id, message")
      .eq("id", event.source_id)
      .single();
    if (error || !message) throw new Error(error?.message || "Customer message not found.");
    if (message.rental_id) {
      const { rental, customer, vehicle } = await rentalDetails(message.rental_id);
      return await sendPushover(
        "Customer message needs a reply",
        `${customer} messaged about ${vehicle}: ${String(message.message || "").slice(0, 240)}`,
        "1",
        { tab: "emails", rental: rental.id },
      );
    }
    const { data: profile } = await adminClient
      .from("profiles")
      .select("full_name, email, phone")
      .eq("id", message.user_id)
      .maybeSingle();
    return await sendPushover(
      "Customer message needs a reply",
      `${profile?.full_name || profile?.email || profile?.phone || "A customer"}: ${String(message.message || "").slice(0, 240)}`,
      "1",
      { tab: "emails" },
    );
  }

  if (event.event_type === "vehicle_report_submitted") {
    const { data: report, error } = await adminClient
      .from("vehicle_reports")
      .select("id, rental_id, vehicle_id, report_type, issue_type, description")
      .eq("id", event.source_id)
      .single();
    if (error || !report) throw new Error(error?.message || "Vehicle report not found.");
    const details = report.rental_id
      ? await rentalDetails(report.rental_id)
      : null;
    return await sendPushover(
      "VEHICLE REPORT NEEDS REVIEW",
      `${details?.customer || "A customer/admin"} reported ${String(report.issue_type || report.report_type || "a vehicle issue")} for ${details?.vehicle || "a fleet vehicle"}: ${String(report.description || "").slice(0, 300)}`,
      "1",
      report.rental_id ? { tab: "rentals", rental: report.rental_id } : { tab: "vehicles" },
    );
  }

  if (event.event_type === "toll_needs_review") {
    const { data: toll, error } = await adminClient
      .from("tollspot_transactions")
      .select("id, occurred_at, total_amount, license_plate, review_reason")
      .eq("id", event.source_id)
      .single();
    if (error || !toll) throw new Error(error?.message || "Toll transaction not found.");
    return await sendPushover(
      "TollSpot transaction needs matching",
      `$${Number(toll.total_amount || 0).toFixed(2)} toll${toll.license_plate ? ` for ${toll.license_plate}` : ""} could not be assigned automatically. ${toll.review_reason || "Review required."}`,
      "1",
      { tab: "tolls" },
    );
  }

  if (event.event_type === "toll_sync_failed") {
    const { data: run, error } = await adminClient
      .from("tollspot_sync_runs")
      .select("id, action, error_code, error_message")
      .eq("id", event.source_id)
      .single();
    if (error || !run) throw new Error(error?.message || "TollSpot sync run not found.");
    return await sendPushover(
      "TOLLSPOT SYNC FAILED",
      `${run.action || "Toll synchronization"} failed: ${run.error_message || run.error_code || "Open Toll Operations for details."}`,
      "1",
      { tab: "tolls" },
    );
  }

  if (event.event_type === "customer_charge_failed") {
    const { data: charge, error } = await adminClient
      .from("rental_charge_items")
      .select("id, rental_id, name, total_amount, last_admin_charge_error")
      .eq("id", event.source_id)
      .single();
    if (error || !charge) throw new Error(error?.message || "Rental charge not found.");
    const { rental, customer, vehicle } = await rentalDetails(charge.rental_id);
    return await sendPushover(
      "CUSTOMER CHARGE FAILED",
      `${customer}'s $${Number(charge.total_amount || 0).toFixed(2)} ${charge.name || "charge"} for ${vehicle} failed: ${charge.last_admin_charge_error || "Stripe declined the payment."}`,
      "1",
      { tab: "rentals", rental: rental.id },
    );
  }

  if (event.event_type === "refund_failed") {
    const { data: refund, error } = await adminClient
      .from("rental_payment_refunds")
      .select("id, rental_id, amount, failure_reason")
      .eq("id", event.source_id)
      .single();
    if (error || !refund) throw new Error(error?.message || "Rental refund not found.");
    const { rental, customer, vehicle } = await rentalDetails(refund.rental_id);
    return await sendPushover(
      "STRIPE REFUND FAILED",
      `${customer}'s $${Number(refund.amount || 0).toFixed(2)} refund for ${vehicle} failed: ${refund.failure_reason || "Open the rental for details."}`,
      "1",
      { tab: "rentals", rental: rental.id },
    );
  }

  if (event.event_type === "maintenance_due" || event.event_type === "maintenance_due_soon") {
    const { data: schedule } = await adminClient
      .from("vehicle_maintenance_schedules")
      .select("id, vehicle_id, label, service_type, next_due_mileage, next_due_at, vehicles(name,current_mileage)")
      .eq("id", event.source_id)
      .maybeSingle();
    const vehicleId = String(schedule?.vehicle_id || event.metadata?.vehicle_id || event.source_id);
    const { data: vehicle, error } = await adminClient
      .from("vehicles")
      .select("id, name, current_mileage, next_maintenance_mileage")
      .eq("id", vehicleId)
      .single();
    if (error || !vehicle) throw new Error(error?.message || "Vehicle not found.");
    const currentMileage = Number(vehicle.current_mileage || 0).toLocaleString("en-US");
    const dueMileageValue = schedule?.next_due_mileage ?? vehicle.next_maintenance_mileage;
    const dueMileage = dueMileageValue == null ? "" : Number(dueMileageValue).toLocaleString("en-US");
    const dueDate = schedule?.next_due_at
      ? new Date(`${schedule.next_due_at}T12:00:00Z`).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" })
      : "";
    const service = schedule?.label || "Required maintenance";
    const dueTarget = [dueMileage ? `${dueMileage} miles` : "", dueDate].filter(Boolean).join(" / ");
    return await sendPushover(
      event.event_type === "maintenance_due" ? "VEHICLE AUTO-LOCKED FOR MAINTENANCE" : "Vehicle maintenance due soon",
      event.event_type === "maintenance_due"
        ? `${vehicle.name || "A fleet vehicle"} was automatically marked Maintenance. ${service} is due${dueTarget ? ` at ${dueTarget}` : ""}; current mileage ${currentMileage}. Complete service or create an audited override.`
        : `${vehicle.name || "A fleet vehicle"} needs ${service} soon${dueTarget ? ` at ${dueTarget}` : ""}; current mileage ${currentMileage}.`,
      event.event_type === "maintenance_due" ? "1" : "0",
    );
  }

  if (event.event_type === "maintenance_override") {
    const { data: vehicle, error } = await adminClient
      .from("vehicles")
      .select("id, name, maintenance_override_until, maintenance_override_reason")
      .eq("id", event.source_id)
      .single();
    if (error || !vehicle) throw new Error(error?.message || "Vehicle not found.");
    const until = vehicle.maintenance_override_until
      ? new Date(vehicle.maintenance_override_until).toLocaleString("en-US", { timeZone: "America/New_York" })
      : "the configured expiration";
    return await sendPushover(
      "Maintenance lock overridden",
      `${vehicle.name || "A fleet vehicle"} was returned to service until ${until} ET. Reason: ${vehicle.maintenance_override_reason || event.metadata?.reason || "Admin override"}.`,
      "1",
    );
  }

  if (["extension_requested", "extension_approved", "extension_payment_received", "extension_payment_failed"].includes(event.event_type)) {
    const { data: extension, error } = await adminClient
      .from("rental_extension_requests")
      .select("id, rental_id, request_kind, requested_return_date, requested_return_time, extension_total_amount")
      .eq("id", event.source_id)
      .maybeSingle();
    if (error) throw new Error(error.message);
    if (!extension) throw new Error("Stale notification: extension request no longer exists.");
    const { customer, customerPhone, vehicle } = await rentalDetails(extension.rental_id);
    const customerLabel = `${customer}${customerPhone && customerPhone !== customer ? ` (${customerPhone})` : ""}`;
    if (event.event_type === "extension_requested") {
      return await sendPushover(
        "EXTENSION REQUEST — REVIEW REQUIRED",
        `${customerLabel} requested ${extension.request_kind === "switch_car_continuation" ? "a vehicle switch through" : `more time with ${vehicle} through`} ${readableDate(extension.requested_return_date, extension.requested_return_time)}. Review the request; approval stays locked until new extension insurance is uploaded and approved.`,
        "1",
        { tab: "queue", rental: extension.rental_id },
        "Review Extension Request",
      );
    }
    if (event.event_type === "extension_payment_received") {
      return await sendPushover(
        "Extension payment received",
        `${customer}'s ${vehicle} extension payment was received and the approved continuation is active.`,
        "0",
        { tab: "rentals", rental: extension.rental_id },
      );
    }
    if (event.event_type === "extension_payment_failed") {
      return await sendPushover(
        "EXTENSION PAYMENT FAILED",
        `${customer}'s ${vehicle} extension payment failed. Contact the customer; the extension is not active.`,
        "1",
        { tab: "queue", rental: extension.rental_id },
      );
    }
    return await sendPushover(
      "Extension approved — payment pending",
      `${customer}'s ${vehicle} extension was approved. $${Number(extension.extension_total_amount || 0).toFixed(2)} must be paid before it activates.`,
      "0",
      { tab: "rentals", rental: extension.rental_id },
    );
  }

  if (event.event_type === "rental_payment_received") {
    const { rental, customer, customerPhone, vehicle } = await rentalDetails(event.rental_id || event.source_id);
    const customerLabel = `${customer}${customerPhone && customerPhone !== customer ? ` (${customerPhone})` : ""}`;
    return await sendPushover(
      rental.merchant_id ? "PAID MERCHANT RENTAL — REVIEW REQUIRED" : "PAID RENTAL — DOCUMENT REVIEW REQUIRED",
      `${rental.merchant_id ? `Merchant: ${(Array.isArray(rental.merchants) ? rental.merchants[0] : rental.merchants)?.name || "Partner"}. Reservation ${rental.merchant_reservation_number || rental.id}. ` : ""}${customerLabel} paid for ${vehicle}, pickup ${readableDate(rental.pickup_date, rental.pickup_time)}. Review the uploaded driver license and insurance before pickup.`,
      "1",
      { tab: "documents", rental: rental.id },
      "Review Uploaded Documents",
    );
  }

  const { data: document, error } = await adminClient
    .from("rental_documents")
    .select("id, rental_id, user_id, document_type, status")
    .eq("id", event.source_id)
    .maybeSingle();
  if (error) throw new Error(error.message);
  if (!document) throw new Error("Stale notification: document no longer exists.");

  const { customer, customerPhone, vehicle } = await rentalDetails(document.rental_id || event.rental_id || "");
  const customerLabel = `${customer}${customerPhone && customerPhone !== customer ? ` (${customerPhone})` : ""}`;
  const documentName = document.document_type === "license" ? "driver license" : "insurance document";
  return await sendPushover(
    "DOCUMENT UPLOADED — REVIEW REQUIRED",
    `${customerLabel} uploaded a ${documentName} for ${vehicle}. Open Documents now to approve or reject it.`,
    "1",
    { tab: "documents", rental: document.rental_id || "" },
    "Review Uploaded Document",
  );
}

async function markSent(eventId: string, requestId: string) {
  const { error } = await adminClient
    .from("admin_notification_events")
    .update({
      status: "sent",
      sent_at: new Date().toISOString(),
      last_error: null,
      provider_request_id: requestId || null,
      updated_at: new Date().toISOString(),
    })
    .eq("id", eventId);
  if (error) throw error;
}

async function markFailed(event: NotificationEvent, message: string) {
  const delayMinutes = Math.min(60, Math.max(1, 2 ** Math.max(0, event.attempts - 1)));
  const { error } = await adminClient
    .from("admin_notification_events")
    .update({
      status: "failed",
      last_error: message.slice(0, 1000),
      next_attempt_at: new Date(Date.now() + delayMinutes * 60_000).toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq("id", event.event_id);
  if (error) console.error("Could not record notification failure", event.event_id, error.message);
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "POST required." }, 405);

  if (!supabaseUrl || !serviceRoleKey || !pushoverAppToken || !pushoverUserKey) {
    return json({ error: "Notification function secrets are incomplete." }, 500);
  }

  const authorization = request.headers.get("Authorization") || "";
  const calledWithServiceRole = authorization === `Bearer ${serviceRoleKey}`;
  if (!calledWithServiceRole) {
    const workerSecret = request.headers.get("x-rentmect-notification-secret") || "";
    const { data: secretIsValid, error: secretError } = await adminClient.rpc(
      "verify_admin_notification_worker_secret",
      { p_secret: workerSecret },
    );
    if (secretError || secretIsValid !== true) {
      return json({ error: "Unauthorized notification worker request." }, 401);
    }
  }

  const { data, error } = await adminClient.rpc("claim_admin_notification_events", { p_limit: 20 });
  if (error) return json({ error: error.message }, 500);

  const events = (data || []) as NotificationEvent[];
  const results = [];
  for (const event of events) {
    try {
      const requestId = await deliver(event);
      await markSent(event.event_id, requestId);
      results.push({ eventId: event.event_id, status: "sent" });
    } catch (error) {
      const message = errorMessage(error);
      if (message.startsWith("Stale notification:")) {
        await markSent(event.event_id, "skipped-stale");
        results.push({ eventId: event.event_id, status: "skipped", reason: message });
      } else {
        await markFailed(event, message);
        results.push({ eventId: event.event_id, status: "failed", error: message });
      }
    }
  }

  return json({
    claimed: events.length,
    sent: results.filter((result) => result.status === "sent").length,
    failed: results.filter((result) => result.status === "failed").length,
    results,
  });
});
