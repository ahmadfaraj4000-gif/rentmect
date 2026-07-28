import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type ManualBookingPayload = {
  action?: "create_booking" | "create_onboarding_link" | "sms_delivery_status";
  rentalId?: string;
  phone?: string;
  delivery?: "email" | "text" | "both" | "copy";
  onboardingDelivery?: "email" | "text" | "both" | "none";
  paymentCollectionPreference?: "customer_link" | "admin_stripe" | "external" | "later";
  customerMode?: "existing" | "new";
  customerId?: string;
  customerDateOfBirth?: string;
  customerPhone?: string;
  driverInfo?: {
    licenseNumber?: string;
    licenseState?: string;
    insuranceProvider?: string;
    insurancePolicyNumber?: string;
  };
  customer?: {
    fullName?: string;
    email?: string;
    phone?: string;
    dateOfBirth?: string;
    address?: string;
  };
  vehicleId?: string;
  pickupDate?: string;
  returnDate?: string;
  pickupTime?: string;
  returnTime?: string;
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const anonKey = Deno.env.get("SUPABASE_ANON_KEY") || "";
const clientPortalUrl = (Deno.env.get("RENTMECT_CLIENT_PORTAL_URL") || "https://login.rentmect.com").replace(/\/$/, "");
const sendGridApiKey = Deno.env.get("SENDGRID_API_KEY") || "";
const fromEmail = Deno.env.get("SENDGRID_FROM_EMAIL") || "bookings@rentmect.com";
const fromName = Deno.env.get("SENDGRID_FROM_NAME") || "Rent Me CT";
const replyToEmail = Deno.env.get("SENDGRID_REPLY_TO_EMAIL") || "rentmectservices@gmail.com";
const twilioAccountSid = Deno.env.get("TWILIO_ACCOUNT_SID") || "";
const twilioAuthToken = Deno.env.get("TWILIO_AUTH_TOKEN") || "";
const twilioMessagingServiceSid = Deno.env.get("TWILIO_MESSAGING_SERVICE_SID") || "";
const twilioPhoneNumber = Deno.env.get("TWILIO_PHONE_NUMBER") || "";
const adminClient = supabaseUrl && serviceRoleKey
  ? createClient(supabaseUrl, serviceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } })
  : null;

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function validDate(value = "") {
  const match = value.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!match) return false;
  const [, year, month, day] = match.map(Number);
  const parsed = new Date(Date.UTC(year, month - 1, day));
  return parsed.getUTCFullYear() === year && parsed.getUTCMonth() + 1 === month && parsed.getUTCDate() === day;
}

function escapeHtml(value: unknown) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

async function createOnboardingLink(rentalId: string, expectedCustomerId?: string) {
  const { data: rental, error: rentalError } = await adminClient!
    .from("rentals")
    .select("id,user_id,profiles!rentals_user_id_profiles_fkey(email,phone,full_name)")
    .eq("id", rentalId)
    .single();
  if (rentalError || !rental) throw new Error(rentalError?.message || "Rental not found.");
  if (expectedCustomerId && rental.user_id !== expectedCustomerId) throw new Error("Rental customer does not match.");
  const profileRelation = rental.profiles;
  const profile = (Array.isArray(profileRelation) ? profileRelation[0] : profileRelation) as { email?: string; phone?: string; full_name?: string } | null;
  const { data: authCustomer } = await adminClient!.auth.admin.getUserById(rental.user_id);
  const email = String(profile?.email || authCustomer?.user?.email || "").trim().toLowerCase();
  if (!email) throw new Error("The customer does not have an email address.");

  const redirectTo = `${clientPortalUrl}/?booking=${encodeURIComponent(rental.id)}&onboarding=1`;
  const { data, error } = await adminClient!.auth.admin.generateLink({
    type: "magiclink",
    email,
    options: { redirectTo },
  });
  const actionLink = data?.properties?.action_link;
  if (error || !actionLink) throw new Error(error?.message || "Could not generate a secure customer sign-in link.");
  return { rental, profile, email, actionLink };
}

function normalizeUSPhone(value: unknown) {
  const digits = String(value || "").replace(/\D/g, "");
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith("1")) return `+${digits}`;
  return "";
}

async function emailOnboardingLink(params: { email: string; fullName?: string; actionLink: string }) {
  if (!sendGridApiKey) throw new Error("SendGrid delivery is not configured; copy the secure link instead.");
  const firstName = escapeHtml(String(params.fullName || "Customer").trim().split(/\s+/)[0]);
  const link = escapeHtml(params.actionLink);
  const html = `<!doctype html><html><body style="margin:0;background:#f3f5f4;font-family:Arial,sans-serif;color:#17211c"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="padding:24px 12px;background:#f3f5f4"><tr><td align="center"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;border:1px solid #dce3df;border-radius:12px"><tr><td style="padding:20px 26px;background:#0b0e0c;color:#ffffff;font-size:22px;font-weight:800;border-radius:12px 12px 0 0">Rent Me CT</td></tr><tr><td style="padding:30px 26px"><h1 style="margin:0 0 16px;font-size:26px">Complete your booking</h1><p style="margin:0 0 14px;line-height:1.6">Hi ${firstName},</p><p style="margin:0 0 22px;line-height:1.6">Use the secure link below to finish phone and identity verification, upload required documents, sign your rental agreement, and pay.</p><p style="margin:0 0 24px"><a href="${link}" style="display:inline-block;padding:13px 20px;border-radius:7px;background:#17643f;color:#ffffff;text-decoration:none;font-weight:700">Complete booking securely</a></p><p style="margin:0;color:#6e7a74;font-size:13px;line-height:1.5">This link signs you in. Do not forward it. If you did not expect this message, contact Rent Me CT.</p></td></tr></table></td></tr></table></body></html>`;
  const text = `Hi ${params.fullName || "Customer"}, securely complete verification, documents, agreement, and payment here: ${params.actionLink}`;
  const response = await fetch("https://api.sendgrid.com/v3/mail/send", {
    method: "POST",
    headers: { Authorization: `Bearer ${sendGridApiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      personalizations: [{ to: [{ email: params.email, name: params.fullName || undefined }] }],
      from: { email: fromEmail, name: fromName },
      reply_to: { email: replyToEmail, name: fromName },
      subject: "Complete your Rent Me CT booking",
      content: [
        { type: "text/plain", value: text },
        { type: "text/html", value: html },
      ],
      categories: ["rentmect_transactional", "manual_booking_onboarding"],
    }),
  });
  if (!response.ok) throw new Error(`Email provider could not deliver the completion email (${response.status}).`);
}

async function textOnboardingLink(params: { phone?: string; fullName?: string; actionLink: string }) {
  if (!/^AC[a-zA-Z0-9]{32}$/.test(twilioAccountSid)) {
    throw new Error("Twilio messaging is unavailable because the Account SID is missing or invalid.");
  }
  if (twilioAuthToken.length !== 32) {
    throw new Error("Twilio messaging is unavailable because the auth token is missing or invalid.");
  }
  if (twilioMessagingServiceSid && !/^MG[a-zA-Z0-9]{32}$/.test(twilioMessagingServiceSid)) {
    throw new Error("Twilio messaging is unavailable because the Messaging Service SID is invalid.");
  }
  if (!twilioMessagingServiceSid && !/^\+1\d{10}$/.test(twilioPhoneNumber)) {
    throw new Error("Twilio messaging needs a valid Messaging Service SID or US Twilio phone number.");
  }
  const phone = normalizeUSPhone(params.phone);
  if (!phone) throw new Error("The customer needs a valid US mobile number before the secure link can be texted.");
  const firstName = String(params.fullName || "Customer").trim().split(/\s+/)[0];
  const values = new URLSearchParams({
    To: phone,
    Body: `Hi ${firstName}, Rent Me CT created your booking. Securely complete phone and identity verification, documents, agreement, and payment here: ${params.actionLink} Do not forward this sign-in link.`,
  });
  if (twilioMessagingServiceSid) values.set("MessagingServiceSid", twilioMessagingServiceSid);
  else values.set("From", twilioPhoneNumber);
  const response = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${twilioAccountSid}/Messages.json`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${btoa(`${twilioAccountSid}:${twilioAuthToken}`)}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: values,
  });
  const detail = await response.json().catch(() => ({})) as {
    sid?: string;
    status?: string;
    error_code?: number | null;
    error_message?: string | null;
    message?: string;
  };
  if (!response.ok) {
    throw new Error(detail.message || `Twilio could not send the secure link (${response.status}).`);
  }
  if (detail.sid) {
    await new Promise((resolve) => setTimeout(resolve, 1200));
    const statusResponse = await fetch(
      `https://api.twilio.com/2010-04-01/Accounts/${twilioAccountSid}/Messages/${detail.sid}.json`,
      {
        headers: {
          Authorization: `Basic ${btoa(`${twilioAccountSid}:${twilioAuthToken}`)}`,
        },
      },
    );
    const status = await statusResponse.json().catch(() => ({})) as {
      status?: string;
      error_code?: number | null;
      error_message?: string | null;
    };
    if (status.status === "failed" || status.status === "undelivered") {
      const code = status.error_code ? `Twilio ${status.error_code}` : "carrier rejection";
      throw new Error(
        status.error_message || `The carrier did not deliver the text (${code}). Check Twilio messaging compliance.`,
      );
    }
  }
}

async function recentSmsDeliveryStatus(value: unknown) {
  if (!/^AC[a-zA-Z0-9]{32}$/.test(twilioAccountSid) || twilioAuthToken.length !== 32) {
    throw new Error("Twilio messaging credentials are missing or invalid.");
  }
  const phone = normalizeUSPhone(value);
  if (!phone) throw new Error("Enter a valid US mobile number.");
  const query = new URLSearchParams({ To: phone, PageSize: "5" });
  const response = await fetch(
    `https://api.twilio.com/2010-04-01/Accounts/${twilioAccountSid}/Messages.json?${query}`,
    {
      headers: {
        Authorization: `Basic ${btoa(`${twilioAccountSid}:${twilioAuthToken}`)}`,
      },
    },
  );
  const result = await response.json().catch(() => ({})) as {
    messages?: Array<Record<string, unknown>>;
    message?: string;
  };
  if (!response.ok) throw new Error(result.message || `Twilio status lookup failed (${response.status}).`);
  return (result.messages || []).map((message) => ({
    sid: String(message.sid || ""),
    status: String(message.status || ""),
    errorCode: message.error_code || null,
    errorMessage: String(message.error_message || ""),
    dateSent: message.date_sent || null,
  }));
}

async function deliverOnboardingLink(
  link: Awaited<ReturnType<typeof createOnboardingLink>>,
  delivery: "email" | "text" | "both",
) {
  const requested = delivery === "both" ? ["email", "text"] : [delivery];
  const sent: string[] = [];
  const warnings: string[] = [];
  for (const channel of requested) {
    try {
      if (channel === "email") {
        await emailOnboardingLink({ email: link.email, fullName: link.profile?.full_name, actionLink: link.actionLink });
      } else {
        await textOnboardingLink({ phone: link.profile?.phone, fullName: link.profile?.full_name, actionLink: link.actionLink });
      }
      sent.push(channel);
    } catch (error) {
      warnings.push(`${channel}: ${error instanceof Error ? error.message : "delivery failed"}`);
    }
  }
  if (!sent.length) throw new Error(warnings.join(" "));
  return { sent, warnings };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "POST required." }, 405);
  if (!adminClient || !supabaseUrl || !serviceRoleKey || !anonKey) {
    return json({ error: "The admin booking function is missing Supabase secrets." }, 500);
  }

  const authorization = req.headers.get("authorization") || "";
  const jwt = authorization.replace(/^Bearer\s+/i, "");
  if (!jwt) return json({ error: "You must be signed in as an admin." }, 401);

  let createdUserId = "";
  try {
    const { data: authData, error: authError } = await adminClient.auth.getUser(jwt);
    if (authError || !authData.user?.id) return json({ error: "Your admin session is invalid." }, 401);

    const { data: adminProfile } = await adminClient
      .from("profiles")
      .select("role")
      .eq("id", authData.user.id)
      .single();
    if (adminProfile?.role !== "admin") return json({ error: "Only an admin can create a manual booking." }, 403);

    const payload = await req.json() as ManualBookingPayload;
    if (payload.action === "sms_delivery_status") {
      return json({ messages: await recentSmsDeliveryStatus(payload.phone) });
    }
    if (payload.action === "create_onboarding_link") {
      if (!payload.rentalId) return json({ error: "Rental id is required." }, 400);
      const link = await createOnboardingLink(payload.rentalId);
      const delivery = payload.delivery === "both" ? "both" : payload.delivery === "text" ? "text" : payload.delivery === "email" ? "email" : null;
      const deliveryResult = delivery ? await deliverOnboardingLink(link, delivery) : { sent: [], warnings: [] };
      await adminClient.from("rental_audit_events").insert({
        rental_id: link.rental.id,
        user_id: link.rental.user_id,
        actor_id: authData.user.id,
        event_type: delivery ? "manual_onboarding_link_sent" : "manual_onboarding_link_generated",
        event_payload: { source: "admin_portal", channels: deliveryResult.sent, warnings: deliveryResult.warnings },
      });
      return json({ onboardingUrl: link.actionLink, onboardingSent: deliveryResult.sent.length > 0, deliveryChannels: deliveryResult.sent, onboardingWarning: deliveryResult.warnings.join(" ") });
    }
    if (!payload.vehicleId || !payload.pickupDate || !payload.returnDate) {
      return json({ error: "Choose a vehicle, pickup date, and return date." }, 400);
    }

    let customerId = payload.customerId || "";
    let customerCreated = false;
    const driverInfo = {
      drivers_license_number: String(payload.driverInfo?.licenseNumber || "").trim().slice(0, 64) || null,
      drivers_license_state: String(payload.driverInfo?.licenseState || "").trim().toUpperCase().slice(0, 32) || null,
      insurance_provider: String(payload.driverInfo?.insuranceProvider || "").trim().slice(0, 120) || null,
      insurance_policy_number: String(payload.driverInfo?.insurancePolicyNumber || "").trim().slice(0, 120) || null,
    };
    if (payload.customerMode === "new") {
      const fullName = String(payload.customer?.fullName || "").trim();
      const email = String(payload.customer?.email || "").trim().toLowerCase();
      const phone = String(payload.customer?.phone || "").trim();
      const dateOfBirth = String(payload.customer?.dateOfBirth || "").trim();
      const address = String(payload.customer?.address || "").trim();
      if (!fullName || !email || !phone || !validDate(dateOfBirth)) {
        return json({ error: "Enter a valid name, email, phone, and date of birth for the new customer." }, 400);
      }

      const { data: matchingProfile } = await adminClient
        .from("profiles")
        .select("id")
        .ilike("email", email)
        .maybeSingle();
      if (matchingProfile?.id) {
        return json({ error: "A customer with that email already exists. Choose Existing customer instead." }, 409);
      }

      const temporaryPassword = `${crypto.randomUUID()}Aa1!`;
      const { data: created, error: createError } = await adminClient.auth.admin.createUser({
        email,
        password: temporaryPassword,
        email_confirm: true,
        user_metadata: { full_name: fullName, phone, date_of_birth: dateOfBirth },
      });
      if (createError || !created.user) throw new Error(createError?.message || "Could not create the customer account.");
      createdUserId = created.user.id;
      customerId = createdUserId;
      customerCreated = true;

      const { error: profileError } = await adminClient.from("profiles").upsert({
        id: customerId,
        email,
        full_name: fullName,
        phone,
        date_of_birth: dateOfBirth,
        address: address || null,
        ...driverInfo,
      }, { onConflict: "id" });
      if (profileError) throw profileError;
    }

    if (!customerId) return json({ error: "Choose a customer." }, 400);
    if (payload.customerMode !== "new" && payload.customerPhone) {
      const normalizedPhone = normalizeUSPhone(payload.customerPhone);
      if (!normalizedPhone) return json({ error: "Enter a valid 10-digit US mobile number for secure texts." }, 400);
      const { data: existingProfile, error: existingProfileError } = await adminClient
        .from("profiles")
        .select("phone")
        .eq("id", customerId)
        .single();
      if (existingProfileError) throw existingProfileError;
      const phoneChanged = normalizeUSPhone(existingProfile?.phone) !== normalizedPhone;
      const { error: phoneError } = await adminClient
        .from("profiles")
        .update({
          phone: normalizedPhone,
          ...(phoneChanged ? {
            phone_verified: false,
            phone_verified_at: null,
            phone_verification_method: null,
            phone_verification_updated_at: null,
          } : {}),
        })
        .eq("id", customerId);
      if (phoneError) throw phoneError;
    }
    if (payload.customerMode !== "new" && payload.customerDateOfBirth) {
      if (!validDate(payload.customerDateOfBirth)) return json({ error: "Enter a valid customer date of birth." }, 400);
      const { error: dateOfBirthError } = await adminClient
        .from("profiles")
        .update({ date_of_birth: payload.customerDateOfBirth })
        .eq("id", customerId)
        .is("date_of_birth", null);
      if (dateOfBirthError) throw dateOfBirthError;
    }
    if (payload.customerMode !== "new") {
      const suppliedDriverInfo = Object.fromEntries(
        Object.entries(driverInfo).filter(([, value]) => value !== null),
      );
      if (Object.keys(suppliedDriverInfo).length) {
        const { error: driverInfoError } = await adminClient
          .from("profiles")
          .update(suppliedDriverInfo)
          .eq("id", customerId);
        if (driverInfoError) throw driverInfoError;
      }
    }

    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: `Bearer ${jwt}` } },
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const { data: rental, error: rentalError } = await callerClient.rpc("admin_create_manual_rental", {
      p_customer_id: customerId,
      p_vehicle_id: payload.vehicleId,
      p_pickup_date: payload.pickupDate,
      p_return_date: payload.returnDate,
      p_pickup_time: payload.pickupTime || "9:00 AM",
      p_return_time: payload.returnTime || "9:00 AM",
    });
    if (rentalError) throw rentalError;

    const paymentCollectionPreference = payload.paymentCollectionPreference || "customer_link";
    if (!["customer_link", "admin_stripe", "external", "later"].includes(paymentCollectionPreference)) {
      throw new Error("Choose a valid payment collection method.");
    }
    const { data: preferenceRental, error: preferenceError } = await adminClient
      .from("rentals")
      .update({ admin_payment_collection_preference: paymentCollectionPreference })
      .eq("id", rental.id)
      .select("*")
      .single();
    const savedRental = preferenceRental || rental;
    const preferenceWarning = preferenceError
      ? "The booking was created, but its payment-plan preference was not saved. Run the manual booking payment preference migration."
      : "";
    if (preferenceError) console.warn("Manual booking payment preference was not saved", preferenceError);

    let onboardingSent = false;
    let onboardingWarning = preferenceWarning;
    const onboardingDelivery = payload.onboardingDelivery;
    let deliveryChannels: string[] = [];
    if (onboardingDelivery && onboardingDelivery !== "none" && rental?.id) {
      try {
        const link = await createOnboardingLink(rental.id, customerId);
        const delivered = await deliverOnboardingLink(link, onboardingDelivery);
        deliveryChannels = delivered.sent;
        onboardingSent = delivered.sent.length > 0;
        onboardingWarning = [preferenceWarning, ...delivered.warnings].filter(Boolean).join(" ");
      } catch (deliveryError) {
        const deliveryMessage = deliveryError instanceof Error ? deliveryError.message : "The completion email could not be sent.";
        onboardingWarning = [preferenceWarning, deliveryMessage].filter(Boolean).join(" ");
        console.warn("Manual booking created but onboarding delivery failed", deliveryError);
      }
    }
    return json({ rental: savedRental, customerId, customerCreated, onboardingSent, onboardingWarning, deliveryChannels });
  } catch (error) {
    if (createdUserId) {
      await adminClient.auth.admin.deleteUser(createdUserId);
    }
    console.error("admin-manual-booking error", error);
    return json({ error: error instanceof Error ? error.message : "Could not create the booking." }, 400);
  }
});
