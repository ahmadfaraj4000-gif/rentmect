import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import Stripe from "npm:stripe@19.2.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey, stripe-signature, x-rentmect-deposit-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type CheckoutPayload = {
  action?: "create_checkout" | "admin_create_checkout" | "admin_charge_saved_card" | "admin_apply_manual_discount" | "release_deposit" | "release_due_deposits" | "create_identity_verification" | "get_identity_verification";
  targetType?: "rental" | "extension" | "charge";
  rentalId?: string;
  extensionRequestId?: string;
  chargeId?: string;
  successUrl?: string;
  cancelUrl?: string;
  reason?: string;
  returnUrl?: string;
  discountMode?: "fixed" | "percentage" | "remove";
  discountValue?: number;
  idempotencyKey?: string;
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const stripeSecretKey = Deno.env.get("STRIPE_SECRET_KEY") || "";
const stripeWebhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET") || "";
const depositReleaseSecret = Deno.env.get("RENTMECT_DEPOSIT_RELEASE_SECRET") || "";
const siteUrl = Deno.env.get("RENTMECT_CLIENT_PORTAL_URL") || Deno.env.get("SITE_URL") || "";
const livePaymentsEnabled = Deno.env.get("RENTMECT_LIVE_PAYMENTS_ENABLED") === "true";
const BOOKING_FLOW_TEST_VEHICLE_ID = "00000000-0000-4000-8000-000000000015";

const adminClient = supabaseUrl && serviceRoleKey
  ? createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    })
  : null;

const stripe = stripeSecretKey
  ? new Stripe(stripeSecretKey, { httpClient: Stripe.createFetchHttpClient() })
  : null;

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function cents(amount: number) {
  return Math.round(Number(amount || 0) * 100);
}

function moneyDescription(amountCents: number) {
  return `$${(amountCents / 100).toFixed(2)}`;
}

class HttpError extends Error {
  status: number;

  constructor(message: string, status: number) {
    super(message);
    this.status = status;
  }
}

function assertPaymentCreationEnabled() {
  if (stripeSecretKey.startsWith("sk_live_") && !livePaymentsEnabled) {
    throw new HttpError(
      "Live payments are paused until production acceptance testing is complete.",
      503,
    );
  }
}

function fallbackPortalUrl(req: Request) {
  if (siteUrl) return siteUrl;
  const requestOrigin = req.headers.get("origin") || "";
  if (
    stripeSecretKey.startsWith("sk_test_") &&
    /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/i.test(requestOrigin)
  ) {
    return requestOrigin;
  }
  return "http://localhost:5173";
}

function checkoutUrls(req: Request, payload: CheckoutPayload) {
  const baseUrl = fallbackPortalUrl(req).replace(/\/$/, "");
  const allowedOrigin = new URL(baseUrl).origin;
  const safeUrl = (requested: string | undefined, fallbackPath: string) => {
    if (!requested) return `${baseUrl}${fallbackPath}`;
    try {
      const candidate = new URL(requested);
      return candidate.origin === allowedOrigin ? candidate.toString() : `${baseUrl}${fallbackPath}`;
    } catch {
      return `${baseUrl}${fallbackPath}`;
    }
  };
  return {
    successUrl: safeUrl(payload.successUrl, "/?payment=stripe_success"),
    cancelUrl: safeUrl(payload.cancelUrl, "/?payment=stripe_cancelled"),
  };
}

async function reusableCheckout(
  storedSessionId: string | null | undefined,
  targetType: "rental" | "extension" | "charge",
  targetId: string,
  expectedAmountCents?: number,
) {
  if (storedSessionId) {
    try {
      const existing = await stripe!.checkout.sessions.retrieve(storedSessionId);
      if (
        existing.status === "open" &&
        expectedAmountCents !== undefined &&
        Number(existing.amount_total || 0) !== expectedAmountCents
      ) {
        await stripe!.checkout.sessions.expire(existing.id);
      } else if (existing.status === "open" && existing.url) {
        return {
          url: existing.url,
          sessionId: existing.id,
          idempotencyKey: `${targetType}-${targetId}-existing`,
        };
      }
      if (existing.status === "complete" || existing.payment_status === "paid") {
        throw new Error("Payment was completed and is still being confirmed. Refresh in a moment.");
      }
    } catch (error) {
      if ((error as { code?: string })?.code !== "resource_missing") throw error;
    }
  }
  return {
    url: null,
    sessionId: null,
    idempotencyKey: storedSessionId
      ? `${targetType}-${targetId}-after-${storedSessionId}`
      : `${targetType}-${targetId}-initial`,
  };
}

function identityReturnUrl(req: Request, requestedUrl?: string) {
  const baseUrl = fallbackPortalUrl(req).replace(/\/$/, "");
  const configuredOrigin = new URL(baseUrl).origin;
  if (requestedUrl) {
    try {
      const candidate = new URL(requestedUrl);
      if (candidate.origin === configuredOrigin) return candidate.toString();
    } catch {
      // Fall back to the configured portal URL below.
    }
  }
  return `${baseUrl}/?identity=return`;
}

async function getUser(req: Request) {
  const authorization = req.headers.get("authorization") || "";
  const jwt = authorization.replace(/^Bearer\s+/i, "");
  if (!jwt) return null;

  if (!adminClient) throw new Error("Supabase service client is not configured.");

  const { data, error } = await adminClient.auth.getUser(jwt);
  if (error) throw error;
  return data.user || null;
}

async function requireAdmin(req: Request) {
  const user = await getUser(req);
  if (!user?.id) throw new Error("You must be signed in as an admin.");
  const { data: profile, error } = await adminClient!
    .from("profiles")
    .select("id, email, role")
    .eq("id", user.id)
    .single();
  if (error || profile?.role !== "admin") throw new Error("Admin access is required.");
  return { user, profile };
}

async function applyAdminManualDiscount(req: Request, payload: CheckoutPayload) {
  const admin = await requireAdmin(req);
  if (!payload.rentalId) throw new HttpError("Rental id is required.", 400);
  if (!payload.discountMode || !["fixed", "percentage", "remove"].includes(payload.discountMode)) {
    throw new HttpError("Choose a valid discount mode.", 400);
  }
  if (!payload.idempotencyKey) throw new HttpError("Idempotency key is required.", 400);

  const { data, error } = await adminClient!.rpc("admin_apply_manual_rental_discount", {
    p_rental_id: payload.rentalId,
    p_mode: payload.discountMode,
    p_value: Number(payload.discountValue || 0),
    p_reason: String(payload.reason || ""),
    p_idempotency_key: payload.idempotencyKey,
    p_actor_id: admin.user.id,
  });
  if (error || !data) throw new HttpError(error?.message || "The discount could not be applied.", 400);

  const checkoutSessionId = String(data.checkout_session_id || "");
  let checkoutExpired = false;
  let checkoutWarning = "";
  if (checkoutSessionId) {
    try {
      const checkout = await stripe!.checkout.sessions.retrieve(checkoutSessionId);
      if (checkout.status === "open") {
        await stripe!.checkout.sessions.expire(checkout.id);
        checkoutExpired = true;
      }
      if (checkout.status !== "complete" && checkout.payment_status !== "paid") {
        await adminClient!.from("rentals").update({ stripe_checkout_session_id: null }).eq("id", payload.rentalId).eq("stripe_checkout_session_id", checkoutSessionId);
      }
    } catch (checkoutError) {
      if ((checkoutError as { code?: string })?.code === "resource_missing") {
        await adminClient!.from("rentals").update({ stripe_checkout_session_id: null }).eq("id", payload.rentalId).eq("stripe_checkout_session_id", checkoutSessionId);
      } else {
        checkoutWarning = "The reservation was repriced, but its earlier Stripe link could not be expired automatically. Create a new payment link before sending checkout.";
      }
    }
  }

  return { ...data, checkoutExpired, checkoutWarning };
}

async function writeDepositAudit(params: {
  actorUserId?: string | null;
  actorEmail?: string | null;
  action: string;
  rentalId: string;
  metadata?: Record<string, unknown>;
}) {
  if (!adminClient) return;
  const { error } = await adminClient.from("admin_audit_logs").insert({
    actor_user_id: params.actorUserId || null,
    actor_email: params.actorEmail || (params.actorUserId ? null : "system"),
    actor_role: params.actorUserId ? "admin" : "system",
    action: params.action,
    entity_type: "security_deposit",
    entity_id: params.rentalId,
    metadata: params.metadata || {},
  });
  if (error) console.warn("Could not write deposit audit log", error.message);
}

async function writeIdentityAudit(action: string, userId: string, sessionId: string, status: string) {
  if (!adminClient) return;
  const { error } = await adminClient.from("admin_audit_logs").insert({
    actor_user_id: null,
    actor_email: "system",
    actor_role: "system",
    action,
    entity_type: "identity_verification",
    entity_id: userId,
    metadata: { verification_session_id: sessionId, status },
  });
  if (error) console.warn("Could not write identity audit log", error.message);
}

async function updateIdentityState(userId: string, session: Stripe.Identity.VerificationSession) {
  const updates: Record<string, unknown> = {
    stripe_identity_verification_session_id: session.id,
    identity_verification_status: session.status,
    identity_verification_updated_at: new Date().toISOString(),
    identity_verification_livemode: session.livemode,
    identity_verification_error_code: session.last_error?.code || null,
  };
  if (session.status === "verified") updates.identity_verified_at = new Date().toISOString();
  const { error } = await adminClient!.from("profiles").update(updates).eq("id", userId);
  if (error) throw error;

  if (session.status === "verified") {
    const { data: rentals } = await adminClient!
      .from("rentals")
      .select("id")
      .eq("user_id", userId)
      .in("status", ["documents_needed", "document_review", "approved"]);
    for (const rental of rentals || []) {
      const { error: syncError } = await adminClient!.rpc("sync_rental_ready_for_pickup_global", { p_rental_id: rental.id });
      if (syncError) console.warn("Could not sync rental after identity verification", rental.id, syncError.message);
    }
  }
}

async function handleIdentityVerification(req: Request, payload: CheckoutPayload, createIfNeeded: boolean) {
  const user = await getUser(req);
  if (!user?.id) throw new Error("You must be signed in to verify your identity.");
  if (createIfNeeded) assertPaymentCreationEnabled();
  const { data: profile, error } = await adminClient!
    .from("profiles")
    .select("id, stripe_identity_verification_session_id, identity_verification_status")
    .eq("id", user.id)
    .single();
  if (error || !profile) throw new Error(error?.message || "Customer profile not found.");

  let session: Stripe.Identity.VerificationSession | null = null;
  if (profile.stripe_identity_verification_session_id) {
    session = await stripe!.identity.verificationSessions.retrieve(profile.stripe_identity_verification_session_id);
    await updateIdentityState(user.id, session);
    if (session.status === "verified" || session.status === "processing") {
      return { status: session.status, verified: session.status === "verified" };
    }
    if (session.status === "requires_input" && session.url) {
      return { status: session.status, verified: false, url: session.url };
    }
  }

  if (!createIfNeeded) {
    return { status: session?.status || profile.identity_verification_status || "unverified", verified: false };
  }

  session = await stripe!.identity.verificationSessions.create({
    type: "document",
    client_reference_id: user.id,
    return_url: identityReturnUrl(req, payload.returnUrl),
    options: { document: { require_matching_selfie: true } },
    metadata: { user_id: user.id, purpose: "renter_identity" },
  }, { idempotencyKey: `rentmect-identity-${user.id}-${Date.now()}` });
  await updateIdentityState(user.id, session);
  await writeIdentityAudit("identity_verification.started", user.id, session.id, session.status);
  return { status: session.status, verified: false, url: session.url };
}

async function updateRefundState(rentalId: string, refund: Stripe.Refund, fallbackAmount: number) {
  const succeeded = refund.status === "succeeded";
  const failed = refund.status === "failed" || refund.status === "canceled";
  const updates: Record<string, unknown> = {
    deposit_refund_id: refund.id,
    deposit_release_attempted_at: new Date().toISOString(),
    deposit_release_due_at: null,
    deposit_release_error: failed ? refund.failure_reason || `Stripe refund ${refund.status}.` : null,
    deposit_release_reason: "Stripe partial refund of the captured security-deposit amount.",
  };
  if (succeeded) {
    updates.deposit_status = "released";
    updates.deposit_released_at = new Date().toISOString();
    updates.deposit_released_amount = Number(refund.amount || fallbackAmount) / 100;
  } else if (failed) {
    updates.deposit_status = "held";
  } else {
    updates.deposit_status = "release_pending";
  }
  const { error } = await adminClient!.from("rentals").update(updates).eq("id", rentalId);
  if (error) throw error;
}

async function refreshDepositAllocationSummary(rentalId: string) {
  const { data: allocations, error } = await adminClient!
    .from("rental_deposit_allocations")
    .select("amount_held, amount_released, status, refund_id")
    .eq("holder_rental_id", rentalId);
  if (error) throw error;
  if (!allocations?.length) return null;
  const pending = allocations.some((item) => item.status === "release_pending");
  const failed = allocations.some((item) => item.status === "failed");
  const unreleased = allocations.reduce((sum, item) =>
    sum + Math.max(0, Number(item.amount_held || 0) - Number(item.amount_released || 0)), 0);
  const released = allocations.reduce((sum, item) => sum + Number(item.amount_released || 0), 0);
  const allReleased = unreleased <= 0.005;
  const { data: rental } = await adminClient!
    .from("rentals")
    .select("deposit_decrease_refund_due")
    .eq("id", rentalId)
    .single();
  const status = allReleased ? "released"
    : pending ? "release_pending"
      : Number(rental?.deposit_decrease_refund_due || 0) > 0 ? "adjustment_refund_due"
        : failed ? "held" : "held";
  const updates: Record<string, unknown> = {
    deposit_status: status,
    deposit_held_amount: unreleased,
    deposit_released_amount: released,
    deposit_refund_id: allocations.find((item) => item.refund_id)?.refund_id || null,
    deposit_release_due_at: null,
    deposit_released_at: allReleased ? new Date().toISOString() : null,
    deposit_release_error: failed ? "One or more deposit refund allocations failed." : null,
  };
  if (allReleased) updates.deposit_decrease_refund_due = 0;
  const { error: rentalError } = await adminClient!.from("rentals").update(updates).eq("id", rentalId);
  if (rentalError) throw rentalError;
  return { status, unreleased, released };
}

async function updateAllocationRefundState(
  rentalId: string,
  allocationId: string,
  refund: Stripe.Refund,
  fallbackAmount: number,
) {
  const succeeded = refund.status === "succeeded";
  const failed = refund.status === "failed" || refund.status === "canceled";
  const { error } = await adminClient!
    .from("rental_deposit_allocations")
    .update({
      refund_id: refund.id,
      status: succeeded ? "released" : failed ? "failed" : "release_pending",
      amount_released: succeeded ? Number(refund.amount || fallbackAmount) / 100 : 0,
      last_error: failed ? refund.failure_reason || `Stripe refund ${refund.status}.` : null,
      updated_at: new Date().toISOString(),
    })
    .eq("id", allocationId)
    .eq("holder_rental_id", rentalId);
  if (error) throw error;
  return await refreshDepositAllocationSummary(rentalId);
}

async function releaseSecurityDeposit(
  rentalId: string,
  source: "manual" | "automatic",
  actor?: { userId?: string | null; email?: string | null; reason?: string | null },
) {
  const { data: rental, error } = await adminClient!
    .from("rentals")
    .select("id, status, payment_provider, stripe_payment_intent_id, security_deposit, deposit_status, deposit_refund_id, deposit_release_due_at, deposit_decrease_refund_due")
    .eq("id", rentalId)
    .single();
  if (error || !rental) throw new Error(error?.message || "Rental not found.");
  if (String(rental.status || "").toLowerCase() !== "completed") {
    throw new Error("The security deposit can be released only after the rental is completed.");
  }
  if (["released", "release_pending"].includes(String(rental.deposit_status || "").toLowerCase())) {
    return { rentalId, refundId: rental.deposit_refund_id, status: rental.deposit_status, duplicate: true };
  }
  if (!["held", "adjustment_refund_due"].includes(String(rental.deposit_status || "").toLowerCase())) {
    throw new Error("This rental does not have a held security deposit.");
  }

  if (source === "automatic") {
    const { data: automationSettings, error: automationError } = await adminClient!
      .from("billing_automation_settings")
      .select("automatic_deposit_release_enabled")
      .eq("id", true)
      .maybeSingle();
    if (automationError || automationSettings?.automatic_deposit_release_enabled !== true) {
      throw new Error("Automatic deposit release is disabled in Billing Automation settings.");
    }
  }

  const { data: unpaidCharges, error: unpaidChargesError } = await adminClient!
    .from("rental_charge_items")
    .select("id, total_amount, status")
    .eq("rental_id", rental.id)
    .eq("included_in_initial_payment", false)
    .in("status", ["pending", "checkout_open", "failed"]);
  if (unpaidChargesError) throw unpaidChargesError;
  const unpaidTotal = (unpaidCharges || []).reduce(
    (sum, charge) => sum + Number(charge.total_amount || 0),
    0,
  );
  if (unpaidTotal > 0.005) {
    throw new Error(
      `Collect or waive the outstanding rental charges (${moneyDescription(cents(unpaidTotal))}) before returning the deposit.`,
    );
  }

  await adminClient!.rpc("ensure_rental_deposit_allocation", { p_rental_id: rental.id });
  const { data: allocations, error: allocationError } = await adminClient!
    .from("rental_deposit_allocations")
    .select("id, payment_provider, stripe_payment_intent_id, amount_held, amount_released, status")
    .eq("holder_rental_id", rental.id)
    .in("status", ["held", "refund_due_inspection", "failed"]);
  if (allocationError) throw allocationError;
  const refundable = (allocations || []).filter((item) =>
    item.payment_provider === "stripe" &&
    item.stripe_payment_intent_id &&
    Number(item.amount_held || 0) > Number(item.amount_released || 0)
  );
  const localHeld = (allocations || []).some((item) =>
    item.payment_provider !== "stripe" &&
    Number(item.amount_held || 0) > Number(item.amount_released || 0)
  );
  if (!refundable.length) {
    if (localHeld) throw new Error("This deposit was received outside Stripe and must be returned outside Stripe.");
    throw new Error("This rental has no refundable Stripe deposit allocation.");
  }

  await adminClient!.from("rentals").update({
    deposit_release_attempted_at: new Date().toISOString(),
    deposit_release_error: null,
  }).eq("id", rental.id);

  try {
    const refunds = [];
    for (const allocation of refundable) {
      const refundAmount = cents(Number(allocation.amount_held || 0) - Number(allocation.amount_released || 0));
      const refund = await stripe!.refunds.create({
        payment_intent: allocation.stripe_payment_intent_id,
        amount: refundAmount,
        metadata: {
          rental_id: rental.id,
          deposit_allocation_id: allocation.id,
          refund_type: "security_deposit",
          release_source: source,
        },
      }, { idempotencyKey: `rentmect-security-deposit-allocation-${allocation.id}` });
      await updateAllocationRefundState(rental.id, allocation.id, refund, refundAmount);
      refunds.push({ id: refund.id, status: refund.status, amount: refundAmount });
    }
    const summary = await refreshDepositAllocationSummary(rental.id);
    await writeDepositAudit({
      actorUserId: actor?.userId,
      actorEmail: actor?.email,
      action: source === "manual" ? "security_deposit.manual_release_requested" : "security_deposit.automatic_release_requested",
      rentalId: rental.id,
      metadata: { refunds, amount: refunds.reduce((sum, item) => sum + item.amount, 0) / 100, reason: actor?.reason || null },
    });
    return {
      rentalId: rental.id,
      refundId: refunds[0]?.id,
      refundIds: refunds.map((item) => item.id),
      status: summary?.status || refunds[0]?.status,
      amount: refunds.reduce((sum, item) => sum + item.amount, 0),
    };
  } catch (refundError) {
    const message = refundError instanceof Error ? refundError.message : "Stripe refund failed.";
    await adminClient!.from("rentals").update({
      deposit_release_attempted_at: new Date().toISOString(),
      deposit_release_error: message,
      deposit_release_due_at: null,
    }).eq("id", rental.id);
    await writeDepositAudit({
      actorUserId: actor?.userId,
      actorEmail: actor?.email,
      action: "security_deposit.release_failed",
      rentalId: rental.id,
      metadata: { source, error: message },
    });
    throw refundError;
  }
}

async function syncPendingDepositRefunds() {
  const { data: allocations, error } = await adminClient!
    .from("rental_deposit_allocations")
    .select("id, holder_rental_id, refund_id, amount_held")
    .eq("status", "release_pending")
    .not("refund_id", "is", null)
    .limit(100);
  if (error) throw error;
  const results = [];
  for (const allocation of allocations || []) {
    try {
      const refund = await stripe!.refunds.retrieve(allocation.refund_id);
      await updateAllocationRefundState(allocation.holder_rental_id, allocation.id, refund, cents(Number(allocation.amount_held || 0)));
      results.push({ rentalId: allocation.holder_rental_id, status: refund.status });
    } catch (syncError) {
      results.push({ rentalId: allocation.holder_rental_id, status: "sync_failed", error: syncError instanceof Error ? syncError.message : "Unknown error" });
    }
  }
  return results;
}

async function releaseDueSecurityDeposits() {
  const pending = await syncPendingDepositRefunds();
  const { data: rentals, error } = await adminClient!
    .from("rentals")
    .select("id")
    .in("deposit_status", ["held", "adjustment_refund_due"])
    .lte("deposit_release_due_at", new Date().toISOString())
    .not("deposit_release_due_at", "is", null)
    .limit(100);
  if (error) throw error;
  const released = [];
  for (const rental of rentals || []) {
    try {
      released.push(await releaseSecurityDeposit(rental.id, "automatic"));
    } catch (releaseError) {
      released.push({ rentalId: rental.id, status: "failed", error: releaseError instanceof Error ? releaseError.message : "Unknown error" });
    }
  }
  return { pending, released };
}

async function createRentalCheckout(req: Request, payload: CheckoutPayload, userId: string, adminAssisted = false) {
  assertPaymentCreationEnabled();
  if (!payload.rentalId) throw new Error("Rental id is required.");

  const { data: rental, error } = await adminClient
    .from("rentals")
    .select("id, user_id, vehicle_id, status, payment_status, rental_total, pre_discount_rental_total, discount_code, discount_amount, manual_discount_amount, manual_discount_type, manual_discount_value, service_fee_total, tax_amount, security_deposit, agreement_signed, checkout_expires_at, payment_due_at, stripe_checkout_session_id, vehicles(name, security_deposit)")
    .eq("id", payload.rentalId)
    .single();

  if (error || !rental) throw new Error(error?.message || "Rental not found.");
  if (rental.user_id !== userId) throw new Error("This rental does not belong to the signed-in customer.");
  if (String(rental.payment_status || "").toLowerCase() === "paid") {
    throw new Error("This rental is already paid.");
  }
  if (String(rental.status || "").toLowerCase() === "cancelled") {
    throw new Error("Cancelled rentals cannot be paid.");
  }
  if (
    (rental.payment_due_at || rental.checkout_expires_at) &&
    new Date(rental.payment_due_at || rental.checkout_expires_at).getTime() <= Date.now()
  ) {
    throw new Error("This reservation's payment deadline has expired. Please start a new booking or contact Rent Me CT.");
  }
  if (rental.vehicle_id === BOOKING_FLOW_TEST_VEHICLE_ID && !stripeSecretKey.startsWith("sk_test_")) {
    throw new Error("Booking Flow Test Vehicle checkout is restricted to Stripe test mode.");
  }

  const { data: renterProfile, error: profileError } = await adminClient
    .from("profiles")
    .select("date_of_birth, phone_verified, identity_verification_status")
    .eq("id", userId)
    .single();
  if (profileError || !renterProfile?.date_of_birth) {
    throw new Error("Add a valid date of birth to your profile before payment.");
  }
  if (!adminAssisted && !renterProfile.phone_verified) {
    throw new Error("Verify your phone number before payment.");
  }
  if (!adminAssisted && String(renterProfile.identity_verification_status || "").toLowerCase() !== "verified") {
    throw new Error("Complete Stripe Identity verification before payment.");
  }
  if (!adminAssisted && !rental.agreement_signed) {
    throw new Error("Sign the rental agreement before payment.");
  }

  const { data: requiredDocuments, error: documentsError } = await adminClient
    .from("rental_documents")
    .select("document_type, rental_id, status")
    .eq("user_id", userId);
  if (documentsError) throw new Error(documentsError.message);

  const hasLicense = (requiredDocuments || []).some((document) =>
    document.document_type === "license" && String(document.status || "").toLowerCase() !== "rejected"
  );
  const hasInsurance = (requiredDocuments || []).some((document) =>
    document.document_type === "insurance" &&
    document.rental_id === rental.id &&
    String(document.status || "").toLowerCase() !== "rejected"
  );
  if (!adminAssisted && (!hasLicense || !hasInsurance)) {
    throw new Error("Upload your driver license and insurance paperwork before payment.");
  }

  const vehicle = Array.isArray(rental.vehicles) ? rental.vehicles[0] : rental.vehicles;
  // Rental pricing is calculated and snapshotted by the database when the
  // rental is created. Stripe must charge those exact stored terms.
  const securityDeposit = Number(rental.security_deposit || 0);

  const amountCents = cents(
    Number(rental.rental_total || 0) +
    Number(rental.service_fee_total || 0) +
    Number(rental.tax_amount || 0) +
    securityDeposit,
  );
  if (amountCents < 50) throw new Error("Payment amount is too small for Stripe Checkout.");
  const priorRentalCheckout = await reusableCheckout(
    rental.stripe_checkout_session_id,
    "rental",
    rental.id,
    amountCents,
  );
  if (priorRentalCheckout.url) return { url: priorRentalCheckout.url, sessionId: priorRentalCheckout.sessionId };

  const { successUrl, cancelUrl } = checkoutUrls(req, payload);
  const metadata = {
    target_type: "rental",
    rental_id: rental.id,
    user_id: userId,
    discount_code: rental.discount_code || "",
    discount_amount: String(Number(rental.discount_amount || 0)),
    manual_discount_amount: String(Number(rental.manual_discount_amount || 0)),
    manual_discount_type: rental.manual_discount_type || "",
    manual_discount_value: String(Number(rental.manual_discount_value || 0)),
  };

  const session = await stripe!.checkout.sessions.create({
    mode: "payment",
    customer_creation: "always",
    success_url: successUrl,
    cancel_url: cancelUrl,
    client_reference_id: rental.id,
    metadata,
    payment_intent_data: {
      metadata,
      setup_future_usage: "off_session",
      description: `Rent Me CT rental ${rental.id}`,
    },
    line_items: [{
      quantity: 1,
      price_data: {
        currency: "usd",
        unit_amount: amountCents,
        product_data: {
          name: `Rent Me CT - ${vehicle?.name || "Vehicle rental"}`,
          description: rental.discount_code || Number(rental.manual_discount_amount || 0) > 0
            ? `Rental with reservation savings, CT tax, and refundable security deposit: ${moneyDescription(amountCents)}`
            : `Rental, CT tax, and refundable security deposit: ${moneyDescription(amountCents)}`,
        },
      },
    }],
  }, { idempotencyKey: priorRentalCheckout.idempotencyKey });

  await adminClient
    .from("rentals")
    .update({
      security_deposit: securityDeposit,
      payment_provider: "stripe",
      stripe_checkout_session_id: session.id,
      payment_amount_cents: amountCents,
      payment_currency: "usd",
    })
    .eq("id", rental.id);

  return { url: session.url, sessionId: session.id };
}

async function createRentalChargeCheckout(req: Request, payload: CheckoutPayload, userId: string) {
  assertPaymentCreationEnabled();
  if (!payload.chargeId) throw new Error("Rental charge id is required.");
  const { data: charge, error } = await adminClient!
    .from("rental_charge_items")
    .select("id, rental_id, user_id, name, description, total_amount, included_in_initial_payment, status, stripe_checkout_session_id")
    .eq("id", payload.chargeId)
    .single();
  if (error || !charge) throw new Error(error?.message || "Rental charge not found.");
  if (charge.user_id !== userId) throw new Error("This charge does not belong to the signed-in customer.");
  if (charge.included_in_initial_payment) throw new Error("This fee is included in the original booking payment.");
  if (charge.status === "paid") throw new Error("This charge is already paid.");
  if (charge.status === "waived") throw new Error("This charge was waived.");
  const priorChargeCheckout = await reusableCheckout(charge.stripe_checkout_session_id, "charge", charge.id);
  if (priorChargeCheckout.url) return { url: priorChargeCheckout.url, sessionId: priorChargeCheckout.sessionId };
  const amountCents = cents(Number(charge.total_amount || 0));
  if (amountCents < 50) throw new Error("Charge amount is too small for Stripe Checkout.");
  const { successUrl, cancelUrl } = checkoutUrls(req, payload);
  const metadata = {
    target_type: "charge",
    charge_id: charge.id,
    rental_id: charge.rental_id,
    user_id: userId,
  };
  const session = await stripe!.checkout.sessions.create({
    mode: "payment",
    customer_creation: "always",
    success_url: successUrl,
    cancel_url: cancelUrl,
    client_reference_id: charge.id,
    metadata,
    payment_intent_data: { metadata, setup_future_usage: "off_session" },
    line_items: [{
      quantity: 1,
      price_data: {
        currency: "usd",
        unit_amount: amountCents,
        product_data: {
          name: `Rent Me CT - ${charge.name}`,
          description: charge.description || "Additional rental charge",
        },
      },
    }],
  }, { idempotencyKey: priorChargeCheckout.idempotencyKey });
  const { error: updateError } = await adminClient!
    .from("rental_charge_items")
    .update({
      status: "checkout_open",
      payment_provider: "stripe",
      stripe_checkout_session_id: session.id,
      payment_amount_cents: amountCents,
      payment_currency: "usd",
      updated_at: new Date().toISOString(),
    })
    .eq("id", charge.id);
  if (updateError) throw updateError;
  return { url: session.url, sessionId: session.id };
}

async function createExtensionCheckout(req: Request, payload: CheckoutPayload, userId: string) {
  assertPaymentCreationEnabled();
  if (!payload.extensionRequestId) throw new Error("Extension request id is required.");

  const { data: request, error } = await adminClient
    .from("rental_extension_requests")
    .select("id, rental_id, user_id, request_kind, status, payment_status, payment_due_at, extension_total_amount, existing_deposit_held, replacement_deposit_required, deposit_carried_amount, deposit_increase_amount, deposit_decrease_amount, requested_return_date, requested_return_time, stripe_checkout_session_id, rentals(vehicles(name))")
    .eq("id", payload.extensionRequestId)
    .single();

  if (error || !request) throw new Error(error?.message || "Extension request not found.");
  if (request.user_id !== userId) throw new Error("This extension does not belong to the signed-in customer.");
  if (request.status !== "approved_pending_payment" || request.payment_status !== "pending") {
    throw new Error("Only approved unpaid extensions can be paid.");
  }
  if (request.payment_due_at && new Date(request.payment_due_at).getTime() <= Date.now()) {
    throw new Error("This extension payment window expired. Submit a new request.");
  }
  const priorExtensionCheckout = await reusableCheckout(request.stripe_checkout_session_id, "extension", request.id);
  if (priorExtensionCheckout.url) return { url: priorExtensionCheckout.url, sessionId: priorExtensionCheckout.sessionId };

  const amountCents = cents(Number(request.extension_total_amount || 0));
  if (amountCents < 50) throw new Error("Payment amount is too small for Stripe Checkout.");

  const rental = Array.isArray(request.rentals) ? request.rentals[0] : request.rentals;
  const vehicle = Array.isArray(rental?.vehicles) ? rental.vehicles[0] : rental?.vehicles;
  const { successUrl, cancelUrl } = checkoutUrls(req, payload);
  const metadata = {
    target_type: "extension",
    extension_request_id: request.id,
    rental_id: request.rental_id,
    user_id: userId,
  };

  const session = await stripe!.checkout.sessions.create({
    mode: "payment",
    success_url: successUrl,
    cancel_url: cancelUrl,
    client_reference_id: request.id,
    metadata,
    payment_intent_data: {
      metadata,
      setup_future_usage: "off_session",
      description: `Rent Me CT extension ${request.id}`,
    },
    line_items: [{
      quantity: 1,
      price_data: {
        currency: "usd",
        unit_amount: amountCents,
        product_data: {
          name: `Rent Me CT - ${request.request_kind === "switch_car_continuation" ? "Vehicle switch" : "Rental extension"}`,
          description: request.request_kind === "switch_car_continuation"
            ? `${vehicle?.name || "Vehicle"} through ${request.requested_return_date}; ${moneyDescription(cents(Number(request.deposit_carried_amount || 0)))} deposit carried, ${moneyDescription(cents(Number(request.deposit_increase_amount || 0)))} additional deposit`
            : `${vehicle?.name || "Vehicle"} through ${request.requested_return_date} ${request.requested_return_time || ""}`.trim(),
        },
      },
    }],
  }, { idempotencyKey: priorExtensionCheckout.idempotencyKey });

  await adminClient
    .from("rental_extension_requests")
    .update({
      payment_provider: "stripe",
      stripe_checkout_session_id: session.id,
      payment_amount_cents: amountCents,
      payment_currency: "usd",
    })
    .eq("id", request.id);

  return { url: session.url, sessionId: session.id };
}

async function recordAdminSavedCardCharge(
  charge: Record<string, unknown>,
  paymentIntent: Stripe.PaymentIntent,
  admin: { user: { id: string; email?: string | null }; profile: { email?: string | null } },
) {
  const amountCents = cents(Number(charge.total_amount || 0));
  const { data, error } = await adminClient!.rpc("record_stripe_rental_charge_payment", {
    p_charge_id: charge.id,
    p_checkout_session_id: `off_session:${paymentIntent.id}`,
    p_payment_intent_id: paymentIntent.id,
    p_amount_total: amountCents,
    p_currency: paymentIntent.currency || "usd",
  });
  if (error) throw error;

  await adminClient!.from("rental_audit_events").insert({
    rental_id: charge.rental_id,
    user_id: charge.user_id,
    actor_id: admin.user.id,
    event_type: "admin_saved_card_charge_succeeded",
    event_payload: {
      charge_id: charge.id,
      payment_intent_id: paymentIntent.id,
      amount_total: amountCents,
      currency: paymentIntent.currency || "usd",
    },
  });
  await adminClient!.from("admin_audit_logs").insert({
    actor_user_id: admin.user.id,
    actor_email: admin.profile.email || admin.user.email || null,
    actor_role: "admin",
    action: "rental_charge.saved_card_succeeded",
    entity_type: "rental_charge",
    entity_id: charge.id,
    metadata: {
      rental_id: charge.rental_id,
      payment_intent_id: paymentIntent.id,
      amount_total: amountCents,
    },
  });
  return data;
}

async function chargeSavedCard(req: Request, payload: CheckoutPayload) {
  if (!payload.chargeId) throw new Error("Rental charge id is required.");
  const admin = await requireAdmin(req);
  assertPaymentCreationEnabled();
  const { data: charge, error: chargeError } = await adminClient!
    .from("rental_charge_items")
    .select("id, rental_id, user_id, name, total_amount, included_in_initial_payment, status, stripe_customer_id, stripe_checkout_session_id, stripe_payment_intent_id, admin_charge_attempts")
    .eq("id", payload.chargeId)
    .single();
  if (chargeError || !charge) throw new Error(chargeError?.message || "Rental charge not found.");
  if (charge.included_in_initial_payment) throw new Error("This fee is included in the original booking payment.");
  if (charge.status === "paid") return { status: "paid", charge };
  if (charge.status === "waived") throw new Error("A waived charge cannot be collected.");

  // Recover safely if Stripe succeeded but the prior request stopped before the
  // database ledger was updated.
  if (charge.stripe_payment_intent_id) {
    const existingIntent = await stripe!.paymentIntents.retrieve(charge.stripe_payment_intent_id);
    if (existingIntent.status === "succeeded") {
      const recorded = await recordAdminSavedCardCharge(charge, existingIntent, admin);
      return { status: "succeeded", charge: recorded, paymentIntentId: existingIntent.id, recovered: true };
    }
    if (["processing", "requires_capture"].includes(existingIntent.status)) {
      return { status: "processing", paymentIntentId: existingIntent.id };
    }
  }

  // Close any customer Checkout session before attempting the saved card, so
  // the same charge cannot be paid through both paths.
  if (charge.stripe_checkout_session_id?.startsWith("cs_")) {
    const checkout = await stripe!.checkout.sessions.retrieve(charge.stripe_checkout_session_id);
    if (checkout.payment_status === "paid" || checkout.status === "complete") {
      return { status: "processing", reason: "The customer Checkout payment is already being confirmed." };
    }
    if (checkout.status === "open") await stripe!.checkout.sessions.expire(checkout.id);
  }

  const { data: rental, error: rentalError } = await adminClient!
    .from("rentals")
    .select("id, user_id, stripe_customer_id, stripe_payment_intent_id")
    .eq("id", charge.rental_id)
    .single();
  if (rentalError || !rental) throw new Error(rentalError?.message || "Rental not found.");

  let stripeCustomerId = rental.stripe_customer_id || charge.stripe_customer_id || "";
  let sourcePaymentIntentId = rental.stripe_payment_intent_id || "";
  if (!stripeCustomerId) {
    const { data: priorRentals } = await adminClient!
      .from("rentals")
      .select("id, user_id, stripe_customer_id, stripe_payment_intent_id")
      .eq("user_id", charge.user_id)
      .eq("payment_provider", "stripe")
      .not("stripe_customer_id", "is", null)
      .order("paid_at", { ascending: false })
      .limit(1);
    if (priorRentals?.[0]) {
      stripeCustomerId = priorRentals[0].stripe_customer_id || "";
      sourcePaymentIntentId = priorRentals[0].stripe_payment_intent_id || "";
    }
  }
  if (!stripeCustomerId) {
    const { data: priorCharges } = await adminClient!
      .from("rental_charge_items")
      .select("stripe_customer_id, stripe_payment_intent_id")
      .eq("user_id", charge.user_id)
      .eq("status", "paid")
      .not("stripe_customer_id", "is", null)
      .order("paid_at", { ascending: false })
      .limit(1);
    if (priorCharges?.[0]) {
      stripeCustomerId = priorCharges[0].stripe_customer_id || "";
      sourcePaymentIntentId = priorCharges[0].stripe_payment_intent_id || "";
    }
  }
  if (!stripeCustomerId) {
    return { status: "customer_action_required", reason: "No saved Stripe customer exists. The customer payment link remains available." };
  }

  let paymentMethodId = "";
  if (sourcePaymentIntentId) {
    const sourceIntent = await stripe!.paymentIntents.retrieve(sourcePaymentIntentId);
    paymentMethodId = typeof sourceIntent.payment_method === "string"
      ? sourceIntent.payment_method
      : sourceIntent.payment_method?.id || "";
  }
  if (!paymentMethodId) {
    const stripeCustomer = await stripe!.customers.retrieve(stripeCustomerId);
    if (!stripeCustomer.deleted) {
      paymentMethodId = typeof stripeCustomer.invoice_settings.default_payment_method === "string"
        ? stripeCustomer.invoice_settings.default_payment_method
        : stripeCustomer.invoice_settings.default_payment_method?.id || "";
    }
  }
  if (!paymentMethodId) {
    const methods = await stripe!.paymentMethods.list({ customer: stripeCustomerId, type: "card", limit: 10 });
    paymentMethodId = methods.data[0]?.id || "";
  }
  if (!paymentMethodId) {
    return { status: "customer_action_required", reason: "No reusable card is saved. The customer payment link remains available." };
  }

  const currentAttempt = Number(charge.admin_charge_attempts || 0);
  const nextAttempt = currentAttempt + 1;
  const { data: claimed, error: claimError } = await adminClient!
    .from("rental_charge_items")
    .update({
      status: "checkout_open",
      admin_charge_attempts: nextAttempt,
      admin_charge_attempted_at: new Date().toISOString(),
      last_admin_charge_error: null,
      updated_at: new Date().toISOString(),
    })
    .eq("id", charge.id)
    .eq("admin_charge_attempts", currentAttempt)
    .in("status", ["pending", "failed", "checkout_open"])
    .select("id")
    .maybeSingle();
  if (claimError) throw claimError;
  if (!claimed) return { status: "processing", reason: "Another payment attempt already started for this charge." };

  const { data: profile } = await adminClient!
    .from("profiles")
    .select("email")
    .eq("id", charge.user_id)
    .maybeSingle();
  const amountCents = cents(Number(charge.total_amount || 0));
  let paymentIntent: Stripe.PaymentIntent | null = null;
  try {
    paymentIntent = await stripe!.paymentIntents.create({
      amount: amountCents,
      currency: "usd",
      customer: stripeCustomerId,
      payment_method: paymentMethodId,
      description: `Rent Me CT - ${charge.name}`,
      receipt_email: profile?.email || undefined,
      metadata: {
        target_type: "charge",
        collection_method: "admin_saved_card",
        charge_id: charge.id,
        rental_id: charge.rental_id,
        user_id: charge.user_id,
        admin_user_id: admin.user.id,
      },
    }, { idempotencyKey: `admin-charge-${charge.id}-attempt-${nextAttempt}` });

    await adminClient!.from("rental_charge_items").update({
      payment_provider: "stripe",
      stripe_customer_id: stripeCustomerId,
      stripe_payment_intent_id: paymentIntent.id,
      payment_amount_cents: amountCents,
      payment_currency: "usd",
      updated_at: new Date().toISOString(),
    }).eq("id", charge.id);

    paymentIntent = await stripe!.paymentIntents.confirm(paymentIntent.id, {
      payment_method: paymentMethodId,
      off_session: true,
    }, { idempotencyKey: `admin-charge-confirm-${paymentIntent.id}` });

    if (paymentIntent.status !== "succeeded") {
      const reason = `Saved card requires customer action (${paymentIntent.status}).`;
      await adminClient!.from("rental_charge_items").update({ status: "failed", last_admin_charge_error: reason, updated_at: new Date().toISOString() }).eq("id", charge.id);
      return { status: "customer_action_required", reason, paymentIntentId: paymentIntent.id };
    }
    const recorded = await recordAdminSavedCardCharge(charge, paymentIntent, admin);
    return { status: "succeeded", charge: recorded, paymentIntentId: paymentIntent.id };
  } catch (error) {
    const stripeError = error as { message?: string; payment_intent?: Stripe.PaymentIntent; raw?: { payment_intent?: Stripe.PaymentIntent } };
    const failedIntent = stripeError.payment_intent || stripeError.raw?.payment_intent || paymentIntent;
    const reason = stripeError.message || "The saved card charge failed.";
    await adminClient!.from("rental_charge_items").update({
      status: "failed",
      stripe_payment_intent_id: failedIntent?.id || paymentIntent?.id || null,
      last_admin_charge_error: reason.slice(0, 1000),
      updated_at: new Date().toISOString(),
    }).eq("id", charge.id);
    await adminClient!.from("rental_audit_events").insert({
      rental_id: charge.rental_id,
      user_id: charge.user_id,
      actor_id: admin.user.id,
      event_type: "admin_saved_card_charge_failed",
      event_payload: { charge_id: charge.id, payment_intent_id: failedIntent?.id || null, error: reason.slice(0, 500) },
    });
    return { status: "customer_action_required", reason: `${reason} The customer payment link remains available.`, paymentIntentId: failedIntent?.id || null };
  }
}

async function handleApiAction(req: Request) {
  if (!stripe || !supabaseUrl || !serviceRoleKey) {
    return json({ error: "Stripe function is missing Stripe or Supabase secrets." }, 500);
  }
  if (!adminClient) {
    return json({ error: "Service role key is missing from Edge Function secrets." }, 500);
  }

  const payload = await req.json() as CheckoutPayload;
  if (payload.action === "release_due_deposits") {
    const suppliedSecret = req.headers.get("x-rentmect-deposit-secret") || "";
    if (!depositReleaseSecret || suppliedSecret !== depositReleaseSecret) {
      return json({ error: "Invalid deposit-release scheduler secret." }, 401);
    }
    return json(await releaseDueSecurityDeposits());
  }

  if (payload.action === "release_deposit") {
    if (!payload.rentalId) return json({ error: "Rental id is required." }, 400);
    const admin = await requireAdmin(req);
    const result = await releaseSecurityDeposit(payload.rentalId, "manual", {
      userId: admin.user.id,
      email: admin.profile.email || admin.user.email,
      reason: payload.reason || null,
    });
    return json(result);
  }

  if (payload.action === "admin_charge_saved_card") {
    return json(await chargeSavedCard(req, payload));
  }

  if (payload.action === "admin_apply_manual_discount") {
    return json(await applyAdminManualDiscount(req, payload));
  }

  if (payload.action === "admin_create_checkout") {
    if (!payload.rentalId) return json({ error: "Rental id is required." }, 400);
    await requireAdmin(req);
    const { data: rental, error } = await adminClient
      .from("rentals")
      .select("user_id")
      .eq("id", payload.rentalId)
      .single();
    if (error || !rental?.user_id) return json({ error: error?.message || "Rental customer not found." }, 404);
    const { data: customerAuth, error: customerAuthError } = await adminClient.auth.admin.getUserById(rental.user_id);
    if (customerAuthError || !customerAuth.user) return json({ error: "Payment cannot be started for a deleted customer account." }, 409);
    return json(await createRentalCheckout(req, payload, rental.user_id, true));
  }

  if (payload.action === "create_identity_verification") {
    return json(await handleIdentityVerification(req, payload, true));
  }

  if (payload.action === "get_identity_verification") {
    return json(await handleIdentityVerification(req, payload, false));
  }

  if (payload.action && payload.action !== "create_checkout") {
    return json({ error: "Unsupported Stripe action." }, 400);
  }

  const user = await getUser(req);
  if (!user?.id) return json({ error: "You must be signed in to start checkout." }, 401);

  const result = payload.targetType === "extension"
    ? await createExtensionCheckout(req, payload, user.id)
    : payload.targetType === "charge"
      ? await createRentalChargeCheckout(req, payload, user.id)
      : await createRentalCheckout(req, payload, user.id);

  return json(result);
}

async function handleWebhook(req: Request) {
  if (!stripe || !stripeWebhookSecret || !supabaseUrl || !serviceRoleKey) {
    return json({ error: "Stripe webhook is missing required secrets." }, 500);
  }
  if (!adminClient) {
    return json({ error: "Service role key is missing from Edge Function secrets." }, 500);
  }

  const signature = req.headers.get("stripe-signature");
  if (!signature) return json({ error: "Missing Stripe signature." }, 400);

  const payload = await req.text();
  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(payload, signature, stripeWebhookSecret);
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Invalid Stripe webhook signature." }, 400);
  }

  if (event.type.startsWith("identity.verification_session.")) {
    const verificationSession = event.data.object as Stripe.Identity.VerificationSession;
    const userId = verificationSession.metadata?.user_id || verificationSession.client_reference_id || "";
    if (!userId || verificationSession.metadata?.purpose !== "renter_identity") {
      return json({ received: true, ignored: "unrelated_identity_verification" });
    }
    const { data: profile } = await adminClient
      .from("profiles")
      .select("stripe_identity_verification_session_id")
      .eq("id", userId)
      .single();
    if (profile?.stripe_identity_verification_session_id !== verificationSession.id) {
      return json({ received: true, ignored: "superseded_identity_verification" });
    }
    await updateIdentityState(userId, verificationSession);
    await writeIdentityAudit(`identity_verification.${verificationSession.status}`, userId, verificationSession.id, verificationSession.status);
    return json({ received: true, identityStatus: verificationSession.status });
  }

  if (["refund.created", "refund.updated", "refund.failed"].includes(event.type)) {
    const refund = event.data.object as Stripe.Refund;
    const rentalId = refund.metadata?.rental_id || "";
    if (!rentalId || refund.metadata?.refund_type !== "security_deposit") {
      return json({ received: true, ignored: "unrelated_refund" });
    }
    const allocationId = refund.metadata?.deposit_allocation_id || "";
    if (allocationId) {
      const { data: allocation } = await adminClient
        .from("rental_deposit_allocations")
        .select("amount_held")
        .eq("id", allocationId)
        .eq("holder_rental_id", rentalId)
        .single();
      await updateAllocationRefundState(
        rentalId,
        allocationId,
        refund,
        cents(Number(allocation?.amount_held || 0)),
      );
    } else {
      const { data: rental } = await adminClient
        .from("rentals")
        .select("security_deposit")
        .eq("id", rentalId)
        .single();
      await updateRefundState(rentalId, refund, cents(Number(rental?.security_deposit || 0)));
    }
    await writeDepositAudit({
      action: `security_deposit.${String(refund.status || "updated")}`,
      rentalId,
      metadata: { stripe_event_id: event.id, refund_id: refund.id, refund_status: refund.status },
    });
    return json({ received: true, refundStatus: refund.status });
  }

  if (["payment_intent.succeeded", "payment_intent.payment_failed"].includes(event.type)) {
    const paymentIntent = event.data.object as Stripe.PaymentIntent;
    const chargeId = paymentIntent.metadata?.charge_id || "";
    const isAdminSavedCardCharge = paymentIntent.metadata?.target_type === "charge"
      && paymentIntent.metadata?.collection_method === "admin_saved_card";
    if (!chargeId || !isAdminSavedCardCharge) {
      return json({ received: true, ignored: "unrelated_payment_intent" });
    }
    if (event.type === "payment_intent.payment_failed") {
      await adminClient.from("rental_charge_items").update({
        status: "failed",
        stripe_payment_intent_id: paymentIntent.id,
        last_admin_charge_error: paymentIntent.last_payment_error?.message || "Stripe reported that the saved-card payment failed.",
        updated_at: new Date().toISOString(),
      }).eq("id", chargeId).neq("status", "paid");
      return json({ received: true, chargeStatus: "failed" });
    }
    const { data, error } = await adminClient.rpc("record_stripe_rental_charge_payment", {
      p_charge_id: chargeId,
      p_checkout_session_id: `off_session:${paymentIntent.id}`,
      p_payment_intent_id: paymentIntent.id,
      p_amount_total: paymentIntent.amount_received || paymentIntent.amount,
      p_currency: paymentIntent.currency || "usd",
    });
    if (error) return json({ error: error.message }, 500);
    return json({ received: true, result: data });
  }

  if (event.type !== "checkout.session.completed") {
    return json({ received: true, ignored: event.type });
  }

  const session = event.data.object as Stripe.Checkout.Session;
  if (session.payment_status !== "paid") {
    return json({ received: true, ignored: "checkout_not_paid" });
  }

  const targetType = session.metadata?.target_type || "";
  const targetId = targetType === "extension"
    ? session.metadata?.extension_request_id
    : targetType === "charge"
      ? session.metadata?.charge_id
      : session.metadata?.rental_id;

  if (!targetId || !["rental", "extension", "charge"].includes(targetType)) {
    return json({ error: "Stripe checkout session is missing Rent Me CT metadata." }, 400);
  }

  if (targetType === "rental") {
    const { data: deadlineRental, error: deadlineError } = await adminClient
      .from("rentals")
      .select("id, user_id, status, payment_status, checkout_expires_at, payment_due_at")
      .eq("id", targetId)
      .single();
    if (deadlineError || !deadlineRental) {
      return json({ error: deadlineError?.message || "Rental not found for checkout." }, 404);
    }

    const deadlineValue = deadlineRental.payment_due_at || deadlineRental.checkout_expires_at;
    const deadlineMs = deadlineValue ? new Date(deadlineValue).getTime() : 0;
    const paidAfterDeadline = Boolean(deadlineMs && event.created * 1000 > deadlineMs);
    const reservationClosed = String(deadlineRental.status || "").toLowerCase() === "cancelled";

    if (
      String(deadlineRental.payment_status || "").toLowerCase() !== "paid" &&
      (paidAfterDeadline || reservationClosed)
    ) {
      const paymentIntentId = typeof session.payment_intent === "string"
        ? session.payment_intent
        : session.payment_intent?.id || "";
      if (!paymentIntentId) {
        return json({ error: "Expired checkout was paid but has no refundable payment intent." }, 500);
      }

      const refund = await stripe!.refunds.create({
        payment_intent: paymentIntentId,
        reason: "requested_by_customer",
        metadata: {
          refund_type: "expired_reservation",
          rental_id: targetId,
          checkout_session_id: session.id,
        },
      }, { idempotencyKey: `expired-rental-checkout-${session.id}` });

      await adminClient.from("rentals").update({
        status: "cancelled",
        cancellation_reason: "Stripe payment completed after the reservation deadline; payment automatically refunded.",
        cancelled_at: new Date().toISOString(),
        stripe_checkout_session_id: session.id,
        stripe_payment_intent_id: paymentIntentId,
        payment_provider: "stripe",
        checkout_expires_at: null,
        payment_due_at: null,
      }).eq("id", targetId);

      await adminClient.from("stripe_webhook_events").upsert({
        id: event.id,
        event_type: event.type,
        target_type: "rental",
        rental_id: targetId,
        payload: event as unknown as Record<string, unknown>,
      }, { onConflict: "id", ignoreDuplicates: true });

      await adminClient.from("rental_audit_events").insert({
        rental_id: targetId,
        user_id: deadlineRental.user_id,
        actor_id: null,
        event_type: "expired_checkout_auto_refunded",
        event_payload: {
          stripe_event_id: event.id,
          checkout_session_id: session.id,
          payment_intent_id: paymentIntentId,
          refund_id: refund.id,
          refund_status: refund.status,
          deadline: deadlineValue,
        },
      });

      return json({
        received: true,
        expired: true,
        automaticallyRefunded: true,
        refundId: refund.id,
        refundStatus: refund.status,
      });
    }
  }

  if (targetType === "extension") {
    const { data: deadlineExtension, error: deadlineError } = await adminClient
      .from("rental_extension_requests")
      .select("id, rental_id, user_id, status, payment_status, payment_due_at")
      .eq("id", targetId)
      .single();
    if (deadlineError || !deadlineExtension) {
      return json({ error: deadlineError?.message || "Extension request not found." }, 404);
    }
    const deadlineMs = deadlineExtension.payment_due_at
      ? new Date(deadlineExtension.payment_due_at).getTime()
      : 0;
    const paidAfterDeadline = Boolean(deadlineMs && event.created * 1000 > deadlineMs);
    const requestClosed = ["cancelled", "rejected"].includes(String(deadlineExtension.status || "").toLowerCase());
    if (
      String(deadlineExtension.payment_status || "").toLowerCase() !== "paid" &&
      (paidAfterDeadline || requestClosed)
    ) {
      const paymentIntentId = typeof session.payment_intent === "string"
        ? session.payment_intent
        : session.payment_intent?.id || "";
      if (!paymentIntentId) {
        return json({ error: "Expired extension checkout has no refundable payment intent." }, 500);
      }
      const refund = await stripe!.refunds.create({
        payment_intent: paymentIntentId,
        reason: "requested_by_customer",
        metadata: {
          refund_type: "expired_extension",
          extension_request_id: targetId,
          checkout_session_id: session.id,
        },
      }, { idempotencyKey: `expired-extension-checkout-${session.id}` });
      await adminClient.from("rental_extension_requests").update({
        status: "cancelled",
        payment_due_at: null,
        stripe_checkout_session_id: session.id,
        stripe_payment_intent_id: paymentIntentId,
      }).eq("id", targetId);
      await adminClient.rpc("release_extension_calendar_hold", { p_extension_request_id: targetId });
      await adminClient.from("stripe_webhook_events").upsert({
        id: event.id,
        event_type: event.type,
        target_type: "extension",
        extension_request_id: targetId,
        payload: event as unknown as Record<string, unknown>,
      }, { onConflict: "id", ignoreDuplicates: true });
      await adminClient.from("rental_audit_events").insert({
        rental_id: deadlineExtension.rental_id,
        user_id: deadlineExtension.user_id,
        actor_id: null,
        event_type: "expired_extension_checkout_auto_refunded",
        event_payload: {
          extension_request_id: targetId,
          stripe_event_id: event.id,
          refund_id: refund.id,
          refund_status: refund.status,
        },
      });
      return json({
        received: true,
        expired: true,
        automaticallyRefunded: true,
        refundId: refund.id,
        refundStatus: refund.status,
      });
    }
  }

  if (targetType === "charge") {
    const stripeCustomerId = typeof session.customer === "string" ? session.customer : session.customer?.id || "";
    const { data, error } = await adminClient.rpc("record_stripe_rental_charge_payment", {
      p_charge_id: targetId,
      p_checkout_session_id: session.id,
      p_payment_intent_id: typeof session.payment_intent === "string" ? session.payment_intent : session.payment_intent?.id || "",
      p_amount_total: session.amount_total || 0,
      p_currency: session.currency || "usd",
    });
    if (error) return json({ error: error.message }, 500);
    if (stripeCustomerId) {
      await adminClient.from("rental_charge_items").update({ stripe_customer_id: stripeCustomerId }).eq("id", targetId);
    }
    return json({ received: true, result: data });
  }

  const { data, error } = await adminClient.rpc("record_stripe_checkout_payment", {
    p_event_id: event.id,
    p_event_type: event.type,
    p_target_type: targetType,
    p_target_id: targetId,
    p_checkout_session_id: session.id,
    p_payment_intent_id: typeof session.payment_intent === "string" ? session.payment_intent : session.payment_intent?.id || "",
    p_customer_id: typeof session.customer === "string" ? session.customer : session.customer?.id || "",
    p_amount_total: session.amount_total || 0,
    p_currency: session.currency || "usd",
    p_payload: event as unknown as Record<string, unknown>,
  });

  if (error) return json({ error: error.message }, 500);
  if (targetType === "rental") {
    await adminClient
      .from("rentals")
      .update({ checkout_expires_at: null })
      .eq("id", targetId);
  }
  return json({ received: true, result: data });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return json({ error: "POST required." }, 405);
  }

  try {
    const pathname = new URL(req.url).pathname;
    if (pathname.endsWith("/webhook")) {
      return await handleWebhook(req);
    }
    return await handleApiAction(req);
  } catch (error) {
    console.error("stripe-web-hook error", error);
    return json(
      { error: error instanceof Error ? error.message : "Unknown Stripe function error." },
      error instanceof HttpError ? error.status : 500,
    );
  }
});
