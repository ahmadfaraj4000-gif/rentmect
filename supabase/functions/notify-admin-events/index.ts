import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type NotificationEvent = {
  event_id: string;
  event_type: "new_booking" | "document_pending_review" | "return_due_today" | "maintenance_due" | "maintenance_due_soon" | "maintenance_override" | "extension_requested" | "extension_approved" | "emergency_exception_created" | "rental_overdue";
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

async function sendPushover(title: string, message: string, priority = "0") {
  const form = new URLSearchParams({
    token: pushoverAppToken,
    user: pushoverUserKey,
    title,
    message,
    priority,
  });

  if (adminPortalUrl) {
    form.set("url", adminPortalUrl);
    form.set("url_title", "Open Rent Me CT Admin");
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
    .select("id, user_id, vehicle_id, pickup_date, pickup_time, return_date, return_time, rental_total, status")
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
    vehicle: vehicleResult.data?.name || "vehicle pending",
  };
}

async function deliver(event: NotificationEvent) {
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

  if (event.event_type === "new_booking") {
    const { rental, customer, vehicle } = await rentalDetails(event.rental_id || event.source_id);
    const total = Number(rental.rental_total || 0);
    const totalText = Number.isFinite(total) && total > 0 ? ` Total $${total.toFixed(2)}.` : "";
    const requestId = await sendPushover(
      "New Rent Me CT booking",
      `${customer} booked ${vehicle}. Pickup ${readableDate(rental.pickup_date, rental.pickup_time)}; return ${readableDate(rental.return_date, rental.return_time)}.${totalText}`,
    );
    return requestId;
  }

  if (event.event_type === "return_due_today") {
    const { rental, customer, vehicle } = await rentalDetails(event.rental_id || event.source_id);
    return await sendPushover(
      "Rental return due today",
      `${customer} is due to return ${vehicle} ${readableDate(rental.return_date, rental.return_time)}.`,
      "1",
    );
  }

  if (event.event_type === "rental_overdue") {
    const { rental, customer, vehicle } = await rentalDetails(event.rental_id || event.source_id);
    const { data: nextRentals, error } = await adminClient
      .from("rentals")
      .select("id, pickup_date, pickup_time, status")
      .eq("vehicle_id", rental.vehicle_id)
      .neq("id", rental.id)
      .not("status", "in", "(completed,cancelled)")
      .gte("pickup_date", rental.return_date)
      .order("pickup_date", { ascending: true })
      .order("pickup_time", { ascending: true })
      .limit(1);
    if (error) throw new Error(error.message);

    const nextRental = nextRentals?.[0];
    const nextBookingWarning = nextRental
      ? ` NEXT BOOKING AT RISK: ${readableDate(nextRental.pickup_date, nextRental.pickup_time)}.`
      : "";
    return await sendPushover(
      "LATE RETURN — VEHICLE HARD-LOCKED",
      `${customer}'s ${vehicle} rental is more than 3 hours past its scheduled return (${readableDate(rental.return_date, rental.return_time)}). The vehicle cannot be booked until physical return and admin inspection. A pending late-return charge is ready under Charge customer.${nextBookingWarning}`,
      "1",
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

  if (event.event_type === "extension_requested" || event.event_type === "extension_approved") {
    const { data: extension, error } = await adminClient
      .from("rental_extension_requests")
      .select("id, rental_id, request_kind, requested_return_date, requested_return_time, extension_total_amount")
      .eq("id", event.source_id)
      .single();
    if (error || !extension) throw new Error(error?.message || "Extension request not found.");
    const { customer, vehicle } = await rentalDetails(extension.rental_id);
    if (event.event_type === "extension_requested") {
      return await sendPushover(
        "Rental extension needs approval",
        `${customer} requested ${extension.request_kind === "switch_car_continuation" ? "a vehicle switch through" : `more time with ${vehicle} through`} ${readableDate(extension.requested_return_date, extension.requested_return_time)}. Open the admin portal to approve or decline.`,
        "1",
      );
    }
    return await sendPushover(
      "Extension approved — payment pending",
      `${customer}'s ${vehicle} extension was approved. $${Number(extension.extension_total_amount || 0).toFixed(2)} must be paid before it activates.`,
    );
  }

  const { data: document, error } = await adminClient
    .from("rental_documents")
    .select("id, rental_id, user_id, document_type, status")
    .eq("id", event.source_id)
    .single();
  if (error || !document) throw new Error(error?.message || "Document record not found.");

  const { customer, vehicle } = await rentalDetails(document.rental_id || event.rental_id || "");
  const documentName = document.document_type === "license" ? "driver license" : "insurance document";
  return await sendPushover(
    "Rental document needs review",
    `${customer} uploaded a ${documentName} for ${vehicle}. Open the admin portal to approve or reject it.`,
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
