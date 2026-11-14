import { allocatedPaymentMessage } from '../_shared/allocated-payment-message.ts';
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey, x-rentmect-reminder-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type ReminderRow = {
  reminder_id: string;
  reminder_type: string;
  rental_id: string;
  user_id: string | null;
  customer_phone: string;
  customer_name: string | null;
  vehicle_name: string | null;
  return_date: string;
  return_time: string | null;
};

type AdminAlertRow = {
  alert_id: string;
  rental_id: string;
  customer_name: string | null;
  customer_phone: string | null;
  vehicle_name: string | null;
  pickup_date: string | null;
  pickup_time: string | null;
  rental_status: string | null;
};

type ExtensionApprovalSmsRow = {
  extension_request_id: string;
  rental_id: string;
  user_id: string;
  customer_phone: string | null;
  customer_name: string | null;
  vehicle_name: string | null;
  continuation_type: string;
  requested_return_date: string;
  requested_return_time: string | null;
  extension_total_amount: number | null;
  payment_due_at: string | null;
};

type RequestBody = {
  rentalId?: string;
  adminApprovalRentalId?: string;
  customerId?: string;
  paymentReceiptId?: string;
  smsTemplateId?: string;
  chargeId?: string;
  extensionRequestId?: string;
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
  Deno.env.get("SERVICE_ROLE_KEY") ||
  "";
const twilioAccountSid = Deno.env.get("TWILIO_ACCOUNT_SID") || "";
const twilioAuthToken = Deno.env.get("TWILIO_AUTH_TOKEN") || "";
const twilioFromNumber = Deno.env.get("TWILIO_PHONE_NUMBER") || "";
const twilioMessagingServiceSid = Deno.env.get("TWILIO_MESSAGING_SERVICE_SID") || "";
const reminderSecret = Deno.env.get("RENTMECT_REMINDER_SECRET") || "";
const rentmectPhone = Deno.env.get("RENTMECT_PHONE") || "860-558-6031";
const adminPhone = Deno.env.get("RENTMECT_ADMIN_PHONE") || "";
const clientPortalUrl = Deno.env.get("RENTMECT_CLIENT_PORTAL_URL") || "https://login.rentmect.com";

const adminClient = createClient(supabaseUrl, serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function formatReturnDate(date: string, time: string | null) {
  const day = new Intl.DateTimeFormat("en-US", {
    timeZone: "UTC",
    month: "short",
    day: "numeric",
    year: "numeric",
  }).format(new Date(`${date}T12:00:00Z`));

  return `${day} at ${time || "9:00 AM"} ET`;
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : "Unknown reminder error.";
}

function returnReminderBody(reminder: ReminderRow) {
  const customer = reminder.customer_name?.trim().split(/\s+/)[0];
  const greeting = customer ? `Hi ${customer}, ` : "";
  const vehicle = reminder.vehicle_name || "your rental";
  const returnPolicy =
    "Please return the vehicle by the agreed time or contact Rent Me CT to request an extension. Extensions and additional charges require explicit approval.";
  if (reminder.reminder_type === "return_overdue_3h_sms") {
    return `${greeting}Rent Me CT: ${vehicle} is past its scheduled return (${formatReturnDate(reminder.return_date, reminder.return_time)}). No automatic late charge has been created. Call ${rentmectPhone} immediately; additional recovery charges may apply. Reply STOP to unsubscribe or HELP for help.`;
  }
  const timing = reminder.reminder_type === "return_due_3h_sms"
    ? "Final return reminder:"
    : "Day-before return reminder:";
  return `${greeting}Rent Me CT: ${timing} ${vehicle} is due ${formatReturnDate(reminder.return_date, reminder.return_time)}. ${returnPolicy} Call ${rentmectPhone} before the due time if you need help. Reply STOP to unsubscribe or HELP for help.`;
}

function paidRentalAdminAlertBody(alert: AdminAlertRow) {
  const customer = alert.customer_name || alert.customer_phone || "A customer";
  const vehicle = alert.vehicle_name || "a rental";
  const pickup = alert.pickup_date ? formatReturnDate(alert.pickup_date, alert.pickup_time) : "pickup time pending";
  return `Rent Me CT: paid rental needs review. ${customer}; ${vehicle}; pickup ${pickup}.`;
}

async function sendTwilioSms(to: string, body: string) {
  const form = new URLSearchParams({ To: to, Body: body });

  if (twilioMessagingServiceSid) {
    form.set("MessagingServiceSid", twilioMessagingServiceSid);
  } else {
    form.set("From", twilioFromNumber);
  }

  const response = await fetch(
    `https://api.twilio.com/2010-04-01/Accounts/${twilioAccountSid}/Messages.json`,
    {
      method: "POST",
      headers: {
        Authorization: `Basic ${btoa(`${twilioAccountSid}:${twilioAuthToken}`)}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: form,
    },
  );
  const payload = await response.json();

  if (!response.ok) {
    throw new Error(payload?.message || `Twilio rejected SMS with ${response.status}.`);
  }

  return payload.sid as string;
}

async function adminUserId(request: Request) {
  const authorization = request.headers.get("authorization") || "";
  const jwt = authorization.replace(/^Bearer\s+/i, "");
  if (!jwt) return null;

  const { data: userResult } = await adminClient.auth.getUser(jwt);
  if (!userResult.user?.id) return null;

  const { data: profile } = await adminClient
    .from("profiles")
    .select("role")
    .eq("id", userResult.user.id)
    .single();

  return profile?.role === "admin" ? userResult.user.id : null;
}

function renderSms(value: unknown, variables: Record<string, unknown>) {
  return String(value || "").replace(/{{\s*([a-zA-Z0-9_]+)\s*}}/g, (_match, key) => String(variables[key] ?? ""));
}

function compliantCustomerSmsBody(value: unknown) {
  let body = String(value || "").trim();
  if (!body) throw new Error("The rendered SMS cannot be empty.");
  if (!/\bRent Me CT\b/i.test(body)) body = `Rent Me CT: ${body}`;
  if (!/\breply\s+stop\b/i.test(body) || !/\bhelp\b/i.test(body)) {
    body = `${body} Reply STOP to unsubscribe or HELP for help.`;
  }
  if (body.length > 1024) {
    throw new Error("The compliant SMS must be between 20 and 1,024 characters.");
  }
  return body;
}

function readableDate(value: unknown) {
  const raw = String(value || "");
  if (!raw) return "your scheduled date";
  const date = new Date(`${raw}T12:00:00Z`);
  return Number.isNaN(date.getTime()) ? raw : new Intl.DateTimeFormat("en-US", {
    timeZone: "UTC", month: "short", day: "numeric", year: "numeric",
  }).format(date);
}

async function manualTemplateMessage(customerId: string, smsTemplateId: string, rentalId: string, chargeId: string, extensionRequestId: string, createdBy: string, paymentReceiptId = "") {
  const [{ data: profile, error: profileError }, { data: template, error: templateError }] = await Promise.all([
    adminClient.from("profiles").select("id,full_name,phone,phone_verified,sms_transactional_opt_in").eq("id", customerId).single(),
    adminClient.from("sms_templates").select("*").eq("id", smsTemplateId).eq("category", "manual").eq("enabled", true).single(),
  ]);
  if (profileError || !profile) throw new Error(profileError?.message || "Customer not found.");
  if (templateError || !template) throw new Error(templateError?.message || "SMS template is unavailable.");
  if (!profile.phone) throw new Error("This customer does not have a phone number.");
  if (!profile.phone_verified) throw new Error("Customer needs a verified phone number before SMS can be sent.");
  if (!profile.sms_transactional_opt_in) throw new Error("Customer has not opted in to transactional SMS.");

  let rental: Record<string, unknown> | null = null;
  if (rentalId) {
    const result = await adminClient.from("rentals").select("id,user_id,pickup_date,pickup_time,return_date,return_time,vehicles(name)").eq("id", rentalId).eq("user_id", customerId).single();
    if (result.error) throw new Error("The selected rental does not belong to this customer.");
    rental = result.data;
  }
  let charge: Record<string, unknown> | null = null;
  if (chargeId) {
    const result = await adminClient.from("rental_charge_items").select("id,rental_id,user_id,name,description,total_amount,status").eq("id", chargeId).eq("user_id", customerId).single();
    if (result.error || (rentalId && result.data?.rental_id !== rentalId)) throw new Error("The selected charge does not belong to this customer and rental.");
    charge = result.data;
  }
  let extension: Record<string, unknown> | null = null;
  let extensionVehicleName = "";
  if (extensionRequestId) {
    const result = await adminClient.from("rental_extension_requests")
      .select("id,rental_id,user_id,status,request_kind,replacement_vehicle_id,requested_return_date,requested_return_time,extension_total_amount,payment_due_at")
      .eq("id", extensionRequestId)
      .eq("user_id", customerId)
      .single();
    if (
      result.error ||
      !result.data ||
      (rentalId && result.data.rental_id !== rentalId) ||
      result.data.status !== "approved_pending_payment" ||
      (result.data.payment_due_at && new Date(result.data.payment_due_at).getTime() <= Date.now())
    ) throw new Error("The selected approved extension does not belong to this customer and rental.");
    extension = result.data;
    if (extension.replacement_vehicle_id) {
      const vehicleResult = await adminClient.from("vehicles").select("name").eq("id", extension.replacement_vehicle_id).single();
      if (vehicleResult.error) throw new Error("The extension replacement vehicle could not be loaded.");
      extensionVehicleName = String(vehicleResult.data?.name || "");
    }
  }
  const vehicleRelation = rental?.vehicles;
  const vehicle = Array.isArray(vehicleRelation) ? vehicleRelation[0] : vehicleRelation as Record<string, unknown> | null;
  const variables = {
    customer_name: profile.full_name || "Customer",
    customer_first_name: String(profile.full_name || "Customer").trim().split(/\s+/)[0],
    vehicle_name: extensionVehicleName || vehicle?.name || "your rental vehicle",
    pickup_date: readableDate(rental?.pickup_date), pickup_time: rental?.pickup_time || "your scheduled time",
    return_date: readableDate(rental?.return_date), return_time: rental?.return_time || "your scheduled time",
    manage_booking_url: charge || extension ? `${clientPortalUrl}?billing=1` : clientPortalUrl, business_phone: rentmectPhone,
    charge_name: charge?.name || "additional rental charge",
    charge_description: charge?.description || "Please contact Rent Me CT with any questions.",
    charge_total: charge?.total_amount == null ? "$0.00" : new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(Number(charge.total_amount)),
    continuation_type: extension?.request_kind === "switch_car_continuation" ? "vehicle switch" : "rental extension",
    requested_return_date: readableDate(extension?.requested_return_date),
    requested_return_time: extension?.requested_return_time || "the approved return time",
    extension_total: extension?.extension_total_amount == null ? "$0.00" : new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(Number(extension.extension_total_amount)),
    payment_due_at: extension?.payment_due_at ? new Intl.DateTimeFormat("en-US", { timeZone: "America/New_York", month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit", timeZoneName: "short" }).format(new Date(String(extension.payment_due_at))) : "the deadline shown in your portal",
  };
  const collection = await allocatedPaymentMessage(adminClient, paymentReceiptId, rentalId, customerId);
  const renderedBody = compliantCustomerSmsBody(collection?.text || renderSms(template.body, variables));
  try {
    const sid = await sendTwilioSms(profile.phone, renderedBody);
    await adminClient.from("admin_customer_messages").insert({
      user_id: customerId, rental_id: rentalId || null, channel: "sms", sms_template_id: smsTemplateId,
      recipient: profile.phone, rendered_body: renderedBody, status: "sent", provider_message_id: sid,
      created_by: createdBy, sent_at: new Date().toISOString(),
    });
    await adminClient.rpc("record_admin_audit_event", { p_action: "customer.sms.sent", p_entity_type: "profile", p_entity_id: customerId, p_metadata: { template_id: smsTemplateId, rental_id: rentalId || null, extension_request_id: extensionRequestId || null } });
    return { customerId, rentalId: rentalId || null, sid };
  } catch (error) {
    await adminClient.from("admin_customer_messages").insert({
      user_id: customerId, rental_id: rentalId || null, channel: "sms", sms_template_id: smsTemplateId,
      recipient: profile.phone, rendered_body: renderedBody, status: "failed", last_error: errorMessage(error), created_by: createdBy,
    });
    throw error;
  }
}

function isCronRequest(request: Request) {
  const suppliedSecret = request.headers.get("x-rentmect-reminder-secret") || "";
  return Boolean(reminderSecret && suppliedSecret && suppliedSecret === reminderSecret);
}

async function manualReminder(rentalId: string) {
  const { data: rental, error } = await adminClient
    .from("rentals")
    .select("id, user_id, return_date, return_time, vehicles(name), profiles!rentals_user_id_profiles_fkey(full_name, phone, phone_verified, sms_transactional_opt_in)")
    .eq("id", rentalId)
    .single();

  if (error || !rental) throw new Error(error?.message || "Rental not found.");
  const profile = Array.isArray(rental.profiles) ? rental.profiles[0] : rental.profiles;
  const vehicle = Array.isArray(rental.vehicles) ? rental.vehicles[0] : rental.vehicles;

  if (!profile?.phone || !profile.phone_verified || !profile.sms_transactional_opt_in) {
    throw new Error("Customer needs a verified phone and active transactional SMS consent before reminders can be sent.");
  }

  const reminder: ReminderRow = {
    reminder_id: "",
    reminder_type: "manual_return_due_sms",
    rental_id: rental.id,
    user_id: rental.user_id,
    customer_phone: profile.phone,
    customer_name: profile.full_name,
    vehicle_name: vehicle?.name || null,
    return_date: rental.return_date,
    return_time: rental.return_time,
  };

  const sid = await sendTwilioSms(reminder.customer_phone, returnReminderBody(reminder));
  return {
    rentalId,
    sid,
    sentTo: "customer",
  };
}

async function sendClaimedAdminAlerts(rentalId = "") {
  if (!adminPhone) {
    throw new Error("RENTMECT_ADMIN_PHONE is required for admin rental alerts.");
  }

  const args = rentalId ? { p_rental_id: rentalId, p_limit: 1 } : {};
  const { data: alerts, error } = await adminClient.rpc("claim_paid_rental_admin_sms_alerts", args);
  if (error) throw error;

  const results = await Promise.all((alerts as AdminAlertRow[] || []).map(async (alert) => {
    try {
      const sid = await sendTwilioSms(adminPhone, paidRentalAdminAlertBody(alert));
      await adminClient
        .from("rental_admin_sms_alerts")
        .update({ status: "sent", sent_at: new Date().toISOString(), twilio_message_sid: sid, updated_at: new Date().toISOString() })
        .eq("id", alert.alert_id);
      return { rentalId: alert.rental_id, status: "sent", sid };
    } catch (error) {
      await adminClient
        .from("rental_admin_sms_alerts")
        .update({ status: "failed", last_error: errorMessage(error), updated_at: new Date().toISOString() })
        .eq("id", alert.alert_id);
      return { rentalId: alert.rental_id, status: "failed", error: errorMessage(error) };
    }
  }));

  return {
    claimed: alerts?.length || 0,
    sent: results.filter((result) => result.status === "sent").length,
    failed: results.filter((result) => result.status === "failed").length,
    results,
  };
}

function extensionApprovalBody(extension: ExtensionApprovalSmsRow) {
  const firstName = extension.customer_name?.trim().split(/\s+/)[0];
  const greeting = firstName ? `Hi ${firstName}, ` : "";
  const amount = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" })
    .format(Number(extension.extension_total_amount || 0));
  const dueAt = extension.payment_due_at
    ? new Intl.DateTimeFormat("en-US", {
      timeZone: "America/New_York",
      month: "short",
      day: "numeric",
      hour: "numeric",
      minute: "2-digit",
      timeZoneName: "short",
    }).format(new Date(extension.payment_due_at))
    : "the deadline shown in your portal";
  return compliantCustomerSmsBody(
    `${greeting}Rent Me CT: Your ${extension.continuation_type} for ${extension.vehicle_name || "your rental vehicle"} through ${formatReturnDate(extension.requested_return_date, extension.requested_return_time)} was approved. ${amount} is due by ${dueAt}. Pay securely at ${clientPortalUrl}?billing=1.`,
  );
}

async function sendClaimedExtensionApprovals() {
  const { data: claimed, error } = await adminClient.rpc("claim_extension_approval_sms", { p_limit: 20 });
  if (error) throw error;

  const results = [];
  for (const extension of claimed as ExtensionApprovalSmsRow[] || []) {
    try {
      const [{ data: profile, error: profileError }, { data: current, error: extensionError }] = await Promise.all([
        adminClient.from("profiles")
          .select("phone,phone_verified,sms_transactional_opt_in")
          .eq("id", extension.user_id)
          .single(),
        adminClient.from("rental_extension_requests")
          .select("status,payment_status,payment_due_at")
          .eq("id", extension.extension_request_id)
          .single(),
      ]);
      if (profileError || extensionError) {
        throw new Error(profileError?.message || extensionError?.message || "Extension SMS state could not be rechecked.");
      }
      if (
        !profile?.phone ||
        !profile.phone_verified ||
        !profile.sms_transactional_opt_in ||
        current?.status !== "approved_pending_payment" ||
        current?.payment_status !== "pending" ||
        (current?.payment_due_at && new Date(current.payment_due_at).getTime() <= Date.now())
      ) {
        const { error: skipUpdateError } = await adminClient.from("rental_extension_requests").update({
          approval_sms_status: "skipped",
          approval_sms_next_attempt_at: null,
          approval_sms_last_error: "SMS skipped because consent, phone verification, approval, or payment state changed before delivery.",
        }).eq("id", extension.extension_request_id);
        if (skipUpdateError) throw skipUpdateError;
        results.push({ extensionRequestId: extension.extension_request_id, status: "skipped" });
        continue;
      }

      const body = extensionApprovalBody({ ...extension, customer_phone: profile.phone });
      const sid = await sendTwilioSms(profile.phone, body);
      const { error: sentUpdateError } = await adminClient.from("rental_extension_requests").update({
        approval_sms_status: "sent",
        approval_sms_sent_at: new Date().toISOString(),
        approval_sms_next_attempt_at: null,
        approval_sms_last_error: null,
      }).eq("id", extension.extension_request_id);
      if (sentUpdateError) throw sentUpdateError;
      const { error: messageLogError } = await adminClient.from("admin_customer_messages").insert({
        user_id: extension.user_id,
        rental_id: extension.rental_id,
        channel: "sms",
        recipient: profile.phone,
        rendered_body: body,
        status: "sent",
        provider_message_id: sid,
        sent_at: new Date().toISOString(),
      });
      if (messageLogError) console.error("Extension approval SMS delivery log failed", messageLogError);
      results.push({ extensionRequestId: extension.extension_request_id, status: "sent", sid });
    } catch (sendError) {
      const detail = errorMessage(sendError);
      await adminClient.from("rental_extension_requests").update({
        approval_sms_status: "failed",
        approval_sms_next_attempt_at: new Date(Date.now() + 5 * 60_000).toISOString(),
        approval_sms_last_error: detail.slice(0, 1000),
      }).eq("id", extension.extension_request_id);
      results.push({ extensionRequestId: extension.extension_request_id, status: "failed", error: detail });
    }
  }

  return {
    claimed: claimed?.length || 0,
    sent: results.filter((result) => result.status === "sent").length,
    failed: results.filter((result) => result.status === "failed").length,
    skipped: results.filter((result) => result.status === "skipped").length,
    results,
  };
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (!supabaseUrl || !serviceRoleKey || !twilioAccountSid || !twilioAuthToken || (!twilioFromNumber && !twilioMessagingServiceSid)) {
    return json({ error: "Return reminder function is missing Supabase or Twilio secrets." }, 500);
  }

  let body: RequestBody = {};
  try {
    body = await request.json();
  } catch {
    body = {};
  }

  const adminId = await adminUserId(request);
  const adminRequest = Boolean(adminId);
  const cronRequest = isCronRequest(request);
  if (!adminRequest && !cronRequest) {
    return json({ error: "Admin login or reminder cron secret required." }, 401);
  }

  try {
    if (body.customerId || body.smsTemplateId) {
      if (!adminId) return json({ error: "Manual customer messages require an admin login." }, 403);
      if (!body.customerId || !body.smsTemplateId) return json({ error: "Customer and SMS template are required." }, 400);
      return json({ sent: 1, manual: await manualTemplateMessage(body.customerId, body.smsTemplateId, body.rentalId || "", body.chargeId || "", body.extensionRequestId || "", adminId, body.paymentReceiptId || "") });
    }
    if (body.rentalId) {
      if (!adminRequest) return json({ error: "Manual reminders require an admin login." }, 403);
      return json({ sent: 1, manual: await manualReminder(body.rentalId) });
    }

    if (body.adminApprovalRentalId) {
      if (!adminRequest) return json({ error: "Manual admin alerts require an admin login." }, 403);
      return json({ adminAlerts: await sendClaimedAdminAlerts(body.adminApprovalRentalId) });
    }

    const { data: reminders, error } = await adminClient.rpc("claim_due_rental_return_sms_reminders");
    if (error) throw error;

    const results = await Promise.all((reminders as ReminderRow[] || []).map(async (reminder) => {
      try {
        const { data: currentConsent, error: consentError } = await adminClient
          .from("profiles")
          .select("sms_transactional_opt_in")
          .eq("id", reminder.user_id)
          .single();
        if (consentError || !currentConsent?.sms_transactional_opt_in) {
          throw new Error("Customer transactional SMS consent is not active.");
        }
        const sid = await sendTwilioSms(reminder.customer_phone, returnReminderBody(reminder));
        await adminClient
          .from("rental_return_reminders")
          .update({ status: "sent", sent_at: new Date().toISOString(), twilio_message_sid: sid, updated_at: new Date().toISOString() })
          .eq("id", reminder.reminder_id);
        return { rentalId: reminder.rental_id, status: "sent", sid };
      } catch (error) {
        await adminClient
          .from("rental_return_reminders")
          .update({ status: "failed", last_error: errorMessage(error), updated_at: new Date().toISOString() })
          .eq("id", reminder.reminder_id);
        return { rentalId: reminder.rental_id, status: "failed", error: errorMessage(error) };
      }
    }));

    const [adminAlerts, extensionApprovals] = await Promise.all([
      sendClaimedAdminAlerts(),
      sendClaimedExtensionApprovals(),
    ]);

    return json({
      claimed: reminders?.length || 0,
      sent: results.filter((result) => result.status === "sent").length,
      failed: results.filter((result) => result.status === "failed").length,
      results,
      adminAlerts,
      extensionApprovals,
    });
  } catch (error) {
    return json({ error: errorMessage(error) }, 500);
  }
});
