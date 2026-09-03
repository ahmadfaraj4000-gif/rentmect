import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import Stripe from "npm:stripe@19.2.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey, stripe-signature, x-rentmect-deposit-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type CheckoutPayload = {
  action?: "create_checkout" | "confirm_checkout" | "admin_create_checkout" | "admin_create_installment_checkout" | "admin_create_charge_checkout" | "admin_create_extension_checkout" | "admin_charge_saved_card" | "admin_waive_rental_charge" | "admin_record_external_charge" | "admin_apply_manual_discount" | "admin_apply_rental_amendment" | "admin_record_external_balance" | "refund_rental_payment" | "release_deposit" | "release_due_deposits" | "create_identity_verification" | "get_identity_verification";
  targetType?: "rental" | "extension" | "charge";
  rentalId?: string;
  extensionRequestId?: string;
  chargeId?: string;
  amountCents?: number;
  reuseOpenInstallment?: boolean;
  refundRequestId?: string;
  successUrl?: string;
  cancelUrl?: string;
  reason?: string;
  returnUrl?: string;
  sessionId?: string;
  discountMode?: "fixed" | "percentage" | "remove";
  discountValue?: number;
  idempotencyKey?: string;
  paymentMethod?: string;
  paymentReference?: string;
  vehicleId?: string;
  pickupDate?: string;
  pickupTime?: string;
  returnDate?: string;
  returnTime?: string;
  dailyRate?: number | null;
  securityDeposit?: number | null;
  adminNotes?: string;
  waiveLateFees?: boolean;
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") || "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const stripeSecretKey = Deno.env.get("STRIPE_SECRET_KEY") || "";
const stripeIdentityRestrictedKey = Deno.env.get("STRIPE_IDENTITY_RESTRICTED_KEY")
  || Deno.env.get("STRIPE_ID_RESULTS")
  || "";
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
const identityResultsStripe = stripeIdentityRestrictedKey
  ? new Stripe(stripeIdentityRestrictedKey, { httpClient: Stripe.createFetchHttpClient() })
  : null;

const IDENTITY_RESULTS_ACCESS_ERROR = "identity_results_access_required";

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function publicApiErrorMessage(error: unknown) {
  const message = error instanceof Error ? error.message : String(error || "");
  if (isIdentityResultsPermissionError(error)) {
    return "Your Stripe submission was received, but Rent Me CT must finish secure Identity-results setup. Do not submit your ID again.";
  }
  return message || "The secure Stripe service could not complete this request.";
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
  const successUrl = new URL(safeUrl(payload.successUrl, "/?payment=stripe_success"));
  // Stripe replaces this literal after payment. Keeping the session id in the
  // return URL lets the customer portal reconcile a successful charge even if
  // webhook delivery is delayed or the endpoint was temporarily unavailable.
  successUrl.searchParams.set("session_id", "__CHECKOUT_SESSION_ID__");
  return {
    successUrl: successUrl.toString().replace("__CHECKOUT_SESSION_ID__", "{CHECKOUT_SESSION_ID}"),
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

async function findActiveAdminInstallment(rentalId: string) {
  const { data: installments, error } = await adminClient!
    .from("rental_charge_items")
    .select("id, rental_id, user_id, status, description, stripe_checkout_session_id, stripe_payment_intent_id, created_at")
    .eq("rental_id", rentalId)
    .eq("charge_type", "rental_installment")
    .in("status", ["pending", "checkout_open", "failed"])
    .order("created_at", { ascending: true });
  if (error) throw error;

  for (const installment of installments || []) {
    const sessionId = String(installment.stripe_checkout_session_id || "");
    const paymentIntentId = String(installment.stripe_payment_intent_id || "");
    let active = false;
    let staleReason = "";

    if (paymentIntentId.startsWith("pi_")) {
      try {
        const intent = await stripe!.paymentIntents.retrieve(paymentIntentId);
        if (["succeeded", "processing", "requires_capture"].includes(intent.status)) {
          throw new HttpError(
            "Stripe is already processing or captured an administrator-started payment. Refresh while it is reconciled.",
            409,
          );
        }
        active = ["requires_payment_method", "requires_confirmation", "requires_action"].includes(intent.status);
      } catch (intentError) {
        if (intentError instanceof HttpError) throw intentError;
        if ((intentError as { code?: string })?.code !== "resource_missing") throw intentError;
        staleReason = "The Stripe PaymentIntent no longer exists.";
      }
    }

    if (sessionId.startsWith("cs_")) {
      try {
        const checkout = await stripe!.checkout.sessions.retrieve(sessionId);
        if (checkout.status === "complete" || checkout.payment_status === "paid") {
          throw new HttpError(
            "Stripe completed an administrator-started payment. Refresh while it is reconciled.",
            409,
          );
        }
        active = checkout.status === "open";
        if (!active) staleReason = `Stripe Checkout ${checkout.status || "closed"} before payment.`;
      } catch (checkoutError) {
        if (checkoutError instanceof HttpError) throw checkoutError;
        if ((checkoutError as { code?: string })?.code !== "resource_missing") throw checkoutError;
        staleReason = "The Stripe Checkout session no longer exists.";
      }
    } else if (!paymentIntentId) {
      const createdAt = new Date(installment.created_at || 0).getTime();
      active = Number.isFinite(createdAt) && Date.now() - createdAt < 5 * 60_000;
      if (!active) staleReason = "The payment attempt did not finish creating a Stripe Checkout session within five minutes.";
    }

    if (active) return installment;

    const { data: retired, error: retireError } = await adminClient!.rpc(
      "retire_expired_stripe_rental_installment",
      {
        p_charge_id: installment.id,
        p_reason: staleReason || "Stripe payment attempt is no longer active.",
        p_checkout_session_id: sessionId || "",
        p_payment_intent_id: paymentIntentId || "",
      },
    );
    if (retireError) throw retireError;
    if (!retired) continue;
  }
  return null;
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

async function requireAdmin(req: Request, permissionKey?: string) {
  const user = await getUser(req);
  if (!user?.id) throw new Error("You must be signed in as an admin.");
  const { data: profile, error } = await adminClient!
    .from("profiles")
    .select("id, email, role, staff_role")
    .eq("id", user.id)
    .single();
  if (error || profile?.role !== "admin" || profile?.staff_role === "customer") throw new Error("Staff access is required.");
  if (permissionKey && profile?.staff_role === "employee") {
    const { data: permission, error: permissionError } = await adminClient!
      .from("employee_permissions").select("enabled").eq("permission_key", permissionKey).single();
    if (permissionError || permission?.enabled !== true) throw new Error("Your Employee role does not have permission for this action.");
  }
  return { user, profile };
}

function authenticatedClient(req: Request) {
  const authorization = req.headers.get("authorization") || "";
  if (!supabaseUrl || !supabaseAnonKey || !authorization) {
    throw new Error("Authenticated Supabase client is not configured.");
  }
  return createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

async function applyAdminRentalAmendment(req: Request, payload: CheckoutPayload) {
  const admin = await requireAdmin(req, "rental.edit");
  if (!payload.rentalId || !payload.vehicleId) {
    throw new HttpError("Rental and vehicle are required.", 400);
  }
  if (!payload.pickupDate || !payload.returnDate || !payload.idempotencyKey) {
    throw new HttpError("Rental dates and idempotency key are required.", 400);
  }

  // Stripe Checkout amounts are immutable. Retire every open rental-payment
  // attempt before repricing so a link created for the old vehicle cannot be
  // paid after the amendment. Temporary admin installments remain typed as
  // rental_installment until Stripe confirms them, so they must be included.
  const [
    { data: paymentRental, error: paymentRentalError },
    { data: openCharges, error: openChargesError },
    { data: lateFeeCharges, error: lateFeeChargesError },
  ] = await Promise.all([
    adminClient!
      .from("rentals")
      .select("id, paid_at, stripe_checkout_session_id, stripe_payment_intent_id")
      .eq("id", payload.rentalId)
      .single(),
    adminClient!
      .from("rental_charge_items")
      .select("id, charge_type, status, stripe_checkout_session_id, stripe_payment_intent_id")
      .eq("rental_id", payload.rentalId)
      .in("charge_type", ["rental_amendment", "rental_installment"])
      .in("status", ["pending", "checkout_open", "failed"])
      .order("created_at", { ascending: false }),
    adminClient!
      .from("rental_charge_items")
      .select("id, status, description, total_amount, stripe_checkout_session_id, stripe_payment_intent_id")
      .eq("rental_id", payload.rentalId)
      .eq("source_type", "late_return")
      .in("status", ["pending", "checkout_open", "failed"])
      .order("created_at", { ascending: true }),
  ]);
  if (paymentRentalError || !paymentRental) {
    throw new HttpError(paymentRentalError?.message || "Rental not found.", 404);
  }
  if (openChargesError) throw openChargesError;
  if (lateFeeChargesError) throw lateFeeChargesError;

  const retireStripePaymentAttempt = async (
    paymentIntentId: string | null | undefined,
    checkoutSessionId: string | null | undefined,
  ) => {
    let retired = false;
    if (paymentIntentId?.startsWith("pi_")) {
      const intent = await stripe!.paymentIntents.retrieve(paymentIntentId);
      if (["succeeded", "processing", "requires_capture"].includes(intent.status)) {
        throw new HttpError(
          "A Stripe rental payment is already processing or captured. Refresh and reconcile it before editing the rental.",
          409,
        );
      }
      if (["requires_payment_method", "requires_confirmation", "requires_action"].includes(intent.status)) {
        await stripe!.paymentIntents.cancel(intent.id);
        retired = true;
      }
    }

    if (checkoutSessionId?.startsWith("cs_")) {
      const checkout = await stripe!.checkout.sessions.retrieve(checkoutSessionId);
      if (checkout.status === "complete" || checkout.payment_status === "paid") {
        throw new HttpError(
          "Stripe already received this rental payment. Refresh and reconcile it before editing the rental.",
          409,
        );
      }
      if (checkout.status === "open") {
        await stripe!.checkout.sessions.expire(checkout.id);
        retired = true;
      }
    }
    return retired;
  };

  let staleStripePaymentExpired = false;
  if (payload.waiveLateFees === true) {
    for (const lateFee of lateFeeCharges || []) {
      staleStripePaymentExpired = await retireStripePaymentAttempt(
        lateFee.stripe_payment_intent_id,
        lateFee.stripe_checkout_session_id,
      ) || staleStripePaymentExpired;
    }
  }
  if (!paymentRental.paid_at) {
    staleStripePaymentExpired = await retireStripePaymentAttempt(
      paymentRental.stripe_payment_intent_id,
      paymentRental.stripe_checkout_session_id,
    ) || staleStripePaymentExpired;
  }

  for (const openCharge of openCharges || []) {
    if (
      openCharge.status === "checkout_open"
      && !openCharge.stripe_checkout_session_id
      && !openCharge.stripe_payment_intent_id
    ) {
      throw new HttpError("A rental payment attempt is starting. Refresh before editing the rental.", 409);
    }
    staleStripePaymentExpired = await retireStripePaymentAttempt(
      openCharge.stripe_payment_intent_id,
      openCharge.stripe_checkout_session_id,
    ) || staleStripePaymentExpired;
  }

  if (!paymentRental.paid_at && (
    paymentRental.stripe_checkout_session_id || paymentRental.stripe_payment_intent_id
  )) {
    const { error: clearRentalPaymentError } = await adminClient!
      .from("rentals")
      .update({
        stripe_checkout_session_id: null,
        stripe_payment_intent_id: null,
        payment_provider: null,
        payment_amount_cents: null,
        updated_at: new Date().toISOString(),
      })
      .eq("id", paymentRental.id)
      .is("paid_at", null);
    if (clearRentalPaymentError) throw clearRentalPaymentError;
  }

  for (const openCharge of openCharges || []) {
    const isInstallment = openCharge.charge_type === "rental_installment";
    const { error: resetOpenChargeError } = await adminClient!
      .from("rental_charge_items")
      .update({
        status: isInstallment ? "waived" : "pending",
        description: isInstallment
          ? "Superseded by a rental edit before Stripe payment."
          : "Unpaid portion of the rental invoice after crediting payments already received.",
        stripe_checkout_session_id: null,
        stripe_payment_intent_id: null,
        payment_provider: null,
        last_admin_charge_error: null,
        updated_at: new Date().toISOString(),
      })
      .eq("id", openCharge.id)
      .in("status", ["pending", "checkout_open", "failed"]);
    if (resetOpenChargeError) throw resetOpenChargeError;
  }

  const userClient = authenticatedClient(req);
  const { data, error } = await userClient.rpc("admin_apply_rental_amendment", {
    p_rental_id: payload.rentalId,
    p_vehicle_id: payload.vehicleId,
    p_pickup_date: payload.pickupDate,
    p_pickup_time: payload.pickupTime || "9:00 AM",
    p_return_date: payload.returnDate,
    p_return_time: payload.returnTime || "9:00 AM",
    p_daily_rate: payload.dailyRate ?? null,
    p_security_deposit: payload.securityDeposit ?? null,
    p_reason: String(payload.reason || "").trim(),
    p_admin_notes: payload.adminNotes || null,
    p_idempotency_key: payload.idempotencyKey,
  });
  if (error || !data) throw new HttpError(error?.message || "The rental changes could not be applied.", 400);

  const lateFeeDecision = payload.waiveLateFees === true ? "waive" : "keep";
  for (const lateFee of lateFeeCharges || []) {
    const description = lateFeeDecision === "waive"
      ? `${String(lateFee.description || "Late-return charge.").replace(/\s*\[(?:AUTO-)?WAIVED[^\]]*\]\s*$/i, "")} [WAIVED BY ADMIN DURING RENTAL EXTENSION.]`
      : lateFee.description;
    const { error: lateFeeDecisionError } = await adminClient!
      .from("rental_charge_items")
      .update(lateFeeDecision === "waive" ? {
        status: "waived",
        description,
        stripe_checkout_session_id: null,
        stripe_payment_intent_id: null,
        payment_provider: null,
        last_admin_charge_error: null,
        updated_at: new Date().toISOString(),
      } : {
        status: lateFee.status,
        description,
        stripe_checkout_session_id: lateFee.stripe_checkout_session_id,
        stripe_payment_intent_id: lateFee.stripe_payment_intent_id,
        updated_at: new Date().toISOString(),
      })
      .eq("id", lateFee.id)
      .in("status", ["pending", "checkout_open", "failed", "waived"]);
    if (lateFeeDecisionError) throw lateFeeDecisionError;
  }

  if ((lateFeeCharges || []).length > 0) {
    const { error: lateFeeAuditError } = await userClient.rpc("record_admin_audit_event", {
      p_action: lateFeeDecision === "waive"
        ? "rental.late_fees_waived_on_extension"
        : "rental.late_fees_kept_on_extension",
      p_entity_type: "rental",
      p_entity_id: payload.rentalId,
      p_metadata: {
        decision: lateFeeDecision,
        charge_ids: lateFeeCharges!.map((charge) => charge.id),
        charge_count: lateFeeCharges!.length,
        total_amount: lateFeeCharges!.reduce((sum, charge) => sum + Number(charge.total_amount || 0), 0),
      },
    });
    if (lateFeeAuditError) throw lateFeeAuditError;
  }

  const { data: settlement, error: settlementError } = await adminClient!.rpc(
    "sync_rental_remaining_balance",
    { p_rental_id: payload.rentalId, p_actor_id: admin.user.id },
  );
  if (settlementError) throw settlementError;

  const balanceChargeId = settlement?.balance_charge_id || null;
  let balanceCharge = null;
  if (balanceChargeId) {
    const { data: resetCharge, error: resetError } = await adminClient!
      .from("rental_charge_items")
      .update({
        status: "pending",
        stripe_checkout_session_id: null,
        stripe_payment_intent_id: null,
        payment_provider: null,
        payment_amount_cents: Math.round(Number(settlement.balance_due || 0) * 100),
        last_admin_charge_error: null,
        updated_at: new Date().toISOString(),
      })
      .eq("id", balanceChargeId)
      .in("status", ["pending", "checkout_open", "failed"])
      .select("*")
      .maybeSingle();
    if (resetError) throw resetError;
    balanceCharge = resetCharge;
  }

  return {
    ...data,
    settlement,
    balanceCharge,
    lateFeeDecision: (lateFeeCharges || []).length > 0 ? lateFeeDecision : null,
    staleStripePaymentExpired,
  };
}

async function applyAdminManualDiscount(req: Request, payload: CheckoutPayload) {
  const admin = await requireAdmin(req, "rental.discount");
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

async function recordAdminExternalBalance(req: Request, payload: CheckoutPayload) {
  const admin = await requireAdmin(req, "payment.collect");
  if (!payload.rentalId) throw new HttpError("Rental id is required.", 400);
  const amountCents = Math.trunc(Number(payload.amountCents || 0));
  if (!Number.isSafeInteger(amountCents) || amountCents <= 0) {
    throw new HttpError("Enter the external payment amount received.", 400);
  }
  const paymentMethod = String(payload.paymentMethod || "").trim();
  if (!paymentMethod) throw new HttpError("Choose the external payment method.", 400);

  const { data: rental, error: rentalError } = await adminClient!
    .from("rentals")
    .select("id, status, paid_at, stripe_checkout_session_id")
    .eq("id", payload.rentalId)
    .single();
  if (rentalError || !rental) throw new HttpError(rentalError?.message || "Rental not found.", 404);
  if (String(rental.status || "").toLowerCase() === "cancelled") {
    throw new HttpError("Cancelled rentals cannot receive a payment.", 409);
  }

  // Retire an earlier full-invoice checkout before crediting an installment.
  // Otherwise its original amount could still be paid after the balance drops.
  const rentalCheckoutId = rental.paid_at ? "" : String(rental.stripe_checkout_session_id || "");
  if (rentalCheckoutId.startsWith("cs_")) {
    try {
      const checkout = await stripe!.checkout.sessions.retrieve(rentalCheckoutId);
      if (checkout.status === "complete" || checkout.payment_status === "paid") {
        throw new HttpError(
          "Stripe already completed this rental payment. Refresh and reconcile it before recording an external payment.",
          409,
        );
      }
      if (checkout.status === "open") await stripe!.checkout.sessions.expire(checkout.id);
      await adminClient!
        .from("rentals")
        .update({ stripe_checkout_session_id: null })
        .eq("id", payload.rentalId)
        .eq("stripe_checkout_session_id", rentalCheckoutId);
    } catch (checkoutError) {
      if (checkoutError instanceof HttpError) throw checkoutError;
      if ((checkoutError as { code?: string })?.code === "resource_missing") {
        await adminClient!
          .from("rentals")
          .update({ stripe_checkout_session_id: null })
          .eq("id", payload.rentalId)
          .eq("stripe_checkout_session_id", rentalCheckoutId);
      } else {
        throw new HttpError(
          "The earlier Stripe checkout could not be retired safely. Try again before recording this payment.",
          409,
        );
      }
    }
  }

  // Initial installments and post-amendment balances share one canonical
  // ledger. For a never-paid rental this creates the first open balance item;
  // for an existing partial payment it refreshes the amount still due.
  const { error: syncError } = await adminClient!.rpc("sync_rental_remaining_balance", {
    p_rental_id: payload.rentalId,
    p_actor_id: admin.user.id,
  });
  if (syncError) throw new HttpError(syncError.message, 400);

  const { data: balanceCharge, error: chargeError } = await adminClient!
    .from("rental_charge_items")
    .select("id, status, stripe_checkout_session_id, stripe_payment_intent_id")
    .eq("rental_id", payload.rentalId)
    .eq("charge_type", "rental_amendment")
    .in("status", ["pending", "checkout_open", "failed"])
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (chargeError) throw chargeError;
  if (!balanceCharge?.id) throw new HttpError("This rental has no remaining balance.", 409);

  if (
    balanceCharge.status === "checkout_open"
    && !balanceCharge.stripe_checkout_session_id
    && !balanceCharge.stripe_payment_intent_id
  ) {
    throw new HttpError("A Stripe payment attempt is starting. Refresh before recording an external payment.", 409);
  }

  if (balanceCharge.stripe_payment_intent_id?.startsWith("pi_")) {
    const intent = await stripe!.paymentIntents.retrieve(balanceCharge.stripe_payment_intent_id);
    if (["succeeded", "processing", "requires_capture"].includes(intent.status)) {
      throw new HttpError("Stripe is already processing or has captured this balance. Refresh before recording an external payment.", 409);
    }
    if (["requires_payment_method", "requires_confirmation", "requires_action"].includes(intent.status)) {
      await stripe!.paymentIntents.cancel(intent.id);
    }
  }

  if (balanceCharge.stripe_checkout_session_id?.startsWith("cs_")) {
    const checkout = await stripe!.checkout.sessions.retrieve(balanceCharge.stripe_checkout_session_id);
    if (checkout.status === "open") await stripe!.checkout.sessions.expire(checkout.id);
    if (checkout.status === "complete" || checkout.payment_status === "paid") {
      throw new HttpError("Stripe already received this balance payment. Refresh before recording an external payment.", 409);
    }
  }

  const { data, error } = await adminClient!.rpc("record_admin_rental_balance_payment", {
    p_rental_id: payload.rentalId,
    p_amount: amountCents / 100,
    p_payment_method: paymentMethod,
    p_reference: String(payload.paymentReference || "").trim() || null,
    p_actor_id: admin.user.id,
  });
  if (error || !data) throw new HttpError(error?.message || "The external balance payment could not be recorded.", 400);
  return data;
}

async function createAdminStripeInstallmentCheckout(req: Request, payload: CheckoutPayload) {
  assertPaymentCreationEnabled();
  const admin = await requireAdmin(req, "payment.collect");
  if (!payload.rentalId) throw new HttpError("Rental id is required.", 400);
  const amountCents = Math.trunc(Number(payload.amountCents || 0));
  if (!Number.isSafeInteger(amountCents) || amountCents < 50) {
    throw new HttpError("Stripe installments must be at least $0.50.", 400);
  }

  const { data: rental, error: rentalError } = await adminClient!
    .from("rentals")
    .select("id, user_id, status, paid_at, security_deposit, deposit_status, stripe_checkout_session_id")
    .eq("id", payload.rentalId)
    .single();
  if (rentalError || !rental) throw new HttpError(rentalError?.message || "Rental not found.", 404);
  if (String(rental.status || "").toLowerCase() === "cancelled") {
    throw new HttpError("Cancelled rentals cannot receive a payment.", 409);
  }
  const { data: customerAuth, error: customerAuthError } = await adminClient!.auth.admin.getUserById(rental.user_id);
  if (customerAuthError || !customerAuth.user) {
    throw new HttpError("Payment cannot be started for a deleted customer account.", 409);
  }

  const { data: settlement, error: settlementError } = await adminClient!.rpc(
    "sync_rental_remaining_balance",
    { p_rental_id: rental.id, p_actor_id: admin.user.id },
  );
  if (settlementError || !settlement) {
    throw new HttpError(settlementError?.message || "The remaining rental balance could not be calculated.", 409);
  }
  const balanceDueCents = cents(Number(settlement.balance_due || 0));
  if (balanceDueCents <= 0) throw new HttpError("This rental has no remaining balance.", 409);
  if (amountCents > balanceDueCents) {
    throw new HttpError(`The Stripe payment cannot exceed the remaining ${moneyDescription(balanceDueCents)} balance.`, 400);
  }

  // Keep the refundable deposit in the final capture so its allocation points
  // to a single Stripe PaymentIntent that can later be refunded safely.
  const depositAlreadyHeld = ["held", "adjustment_refund_due", "release_pending", "released", "transferred"]
    .includes(String(rental.deposit_status || "").toLowerCase());
  const protectedDepositCents = depositAlreadyHeld ? 0 : cents(Number(rental.security_deposit || 0));
  if (amountCents < balanceDueCents && balanceDueCents - amountCents < protectedDepositCents) {
    const largestInstallmentCents = Math.max(0, balanceDueCents - protectedDepositCents);
    throw new HttpError(
      largestInstallmentCents >= 50
        ? `Leave the ${moneyDescription(protectedDepositCents)} security deposit for the final Stripe payment. The largest installment available now is ${moneyDescription(largestInstallmentCents)}.`
        : `The remaining ${moneyDescription(balanceDueCents)} must be collected as one final Stripe payment so the security deposit stays refundable.`,
      400,
    );
  }

  const retireCheckout = async (sessionId: string, completedMessage: string) => {
    if (!sessionId.startsWith("cs_")) return;
    try {
      const checkout = await stripe!.checkout.sessions.retrieve(sessionId);
      if (checkout.status === "complete" || checkout.payment_status === "paid") {
        throw new HttpError(completedMessage, 409);
      }
      if (checkout.status === "open") await stripe!.checkout.sessions.expire(checkout.id);
    } catch (checkoutError) {
      if (checkoutError instanceof HttpError) throw checkoutError;
      if ((checkoutError as { code?: string })?.code !== "resource_missing") {
        throw new HttpError("An earlier Stripe checkout could not be retired safely. Refresh and try again.", 409);
      }
    }
  };

  await retireCheckout(
    rental.paid_at ? "" : String(rental.stripe_checkout_session_id || ""),
    "Stripe already completed the earlier rental checkout. Refresh before starting another payment.",
  );

  const { data: openCharges, error: openChargesError } = await adminClient!
    .from("rental_charge_items")
    .select("id, charge_type, status, total_amount, stripe_checkout_session_id, stripe_payment_intent_id")
    .eq("rental_id", rental.id)
    .in("charge_type", ["rental_amendment", "rental_installment"])
    .in("status", ["checkout_open"]);
  if (openChargesError) throw openChargesError;
  const openInstallment = (openCharges || []).find((charge) => charge.charge_type === "rental_installment");
  if (payload.reuseOpenInstallment && openInstallment) {
    if (!String(openInstallment.stripe_checkout_session_id || "").startsWith("cs_")) {
      throw new HttpError("The existing Stripe installment is still starting. Refresh in a moment.", 409);
    }
    const openAmountCents = cents(Number(openInstallment.total_amount || 0));
    const existingCheckout = await reusableCheckout(
      openInstallment.stripe_checkout_session_id,
      "charge",
      openInstallment.id,
      openAmountCents,
    );
    if (existingCheckout.url) {
      return {
        url: existingCheckout.url,
        sessionId: existingCheckout.sessionId,
        targetType: "charge",
        targetId: openInstallment.id,
        rentalId: rental.id,
        installment: openAmountCents < balanceDueCents,
        installmentAmount: openAmountCents / 100,
        balanceBeforePayment: balanceDueCents / 100,
        balanceAfterPayment: Math.max(0, balanceDueCents - openAmountCents) / 100,
        reused: true,
      };
    }
  }
  for (const charge of openCharges || []) {
    if (!charge.stripe_checkout_session_id && !charge.stripe_payment_intent_id) {
      throw new HttpError("Another Stripe payment attempt is starting. Refresh before choosing a new amount.", 409);
    }
    if (String(charge.stripe_payment_intent_id || "").startsWith("pi_")) {
      const intent = await stripe!.paymentIntents.retrieve(charge.stripe_payment_intent_id);
      if (["succeeded", "processing", "requires_capture"].includes(intent.status)) {
        throw new HttpError("Stripe is already processing or captured an earlier payment. Refresh before continuing.", 409);
      }
      if (["requires_payment_method", "requires_confirmation", "requires_action"].includes(intent.status)) {
        await stripe!.paymentIntents.cancel(intent.id);
      }
    }
    await retireCheckout(
      String(charge.stripe_checkout_session_id || ""),
      "Stripe already completed an earlier rental payment. Refresh before starting another payment.",
    );
    const { error: resetError } = await adminClient!
      .from("rental_charge_items")
      .update({
        status: charge.charge_type === "rental_installment" ? "waived" : "pending",
        updated_at: new Date().toISOString(),
      })
      .eq("id", charge.id)
      .eq("status", "checkout_open");
    if (resetError) throw resetError;
  }

  const { data: installmentCharge, error: prepareError } = await adminClient!.rpc(
    "prepare_admin_stripe_rental_installment",
    {
      p_rental_id: rental.id,
      p_amount: amountCents / 100,
      p_actor_id: admin.user.id,
    },
  );
  if (prepareError || !installmentCharge?.id) {
    throw new HttpError(prepareError?.message || "The Stripe installment could not be prepared.", 409);
  }

  try {
    const checkout = await createRentalChargeCheckout(
      req,
      { ...payload, chargeId: installmentCharge.id },
      rental.user_id,
    );
    return {
      ...checkout,
      installment: amountCents < balanceDueCents,
      installmentAmount: amountCents / 100,
      balanceBeforePayment: balanceDueCents / 100,
      balanceAfterPayment: (balanceDueCents - amountCents) / 100,
    };
  } catch (checkoutError) {
    await adminClient!
      .from("rental_charge_items")
      .update({ status: "failed", last_admin_charge_error: publicApiErrorMessage(checkoutError), updated_at: new Date().toISOString() })
      .eq("id", installmentCharge.id)
      .eq("status", "pending");
    throw checkoutError;
  }
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

function normalizedDateOfBirth(value?: string | null) {
  const match = String(value || "").trim().match(/^(\d{4})-(\d{2})-(\d{2})$/);
  return match ? `${match[1]}-${match[2]}-${match[3]}` : "";
}

function verifiedIdentityDateOfBirthMatches(
  profileDateOfBirth: string,
  session: Stripe.Identity.VerificationSession,
) {
  const dob = session.verified_outputs?.dob;
  if (!dob || typeof dob === "string") return false;
  const year = Number(dob.year);
  const month = Number(dob.month);
  const day = Number(dob.day);
  if (!year || !month || !day) return false;
  const verifiedDate = `${String(year).padStart(4, "0")}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
  return normalizedDateOfBirth(profileDateOfBirth) === verifiedDate;
}

function isIdentityResultsPermissionError(error: unknown) {
  const stripeError = error as {
    statusCode?: number;
    code?: string;
    raw?: { statusCode?: number; code?: string; message?: string };
  };
  const message = error instanceof Error
    ? error.message
    : stripeError?.raw?.message || String(error || "");
  return stripeError?.statusCode === 403
    || stripeError?.raw?.statusCode === 403
    || stripeError?.code === "permission_denied"
    || stripeError?.raw?.code === "permission_denied"
    || /sensitive verification results|restricted api key|access-verification-results|required permissions?|permission.*identity/i.test(message);
}

async function retrieveIdentitySessionForComparison(sessionId: string) {
  const baseSession = await stripe!.identity.verificationSessions.retrieve(
    sessionId,
    { expand: ["verified_outputs"] },
  );
  if (baseSession.status !== "verified") {
    return { session: baseSession, sensitiveResultsAvailable: true };
  }
  if (!identityResultsStripe) {
    return { session: baseSession, sensitiveResultsAvailable: false };
  }
  try {
    const sensitiveSession = await identityResultsStripe.identity.verificationSessions.retrieve(
      sessionId,
      { expand: ["verified_outputs", "verified_outputs.dob"] },
    );
    return { session: sensitiveSession, sensitiveResultsAvailable: true };
  } catch (error) {
    if (!isIdentityResultsPermissionError(error)) throw error;
    console.warn("Stripe Identity restricted key cannot access recent sensitive verification results.");
    return { session: baseSession, sensitiveResultsAvailable: false };
  }
}

async function markIdentityResultsAccessRequired(
  userId: string,
  session: Stripe.Identity.VerificationSession,
) {
  const status = "configuration_required";
  const { error } = await adminClient!.from("profiles").update({
    stripe_identity_verification_session_id: session.id,
    identity_verification_status: status,
    identity_verification_updated_at: new Date().toISOString(),
    identity_verification_livemode: session.livemode,
    identity_verification_error_code: IDENTITY_RESULTS_ACCESS_ERROR,
    identity_verified_at: null,
  }).eq("id", userId);
  if (error) throw error;
  await writeIdentityAudit("identity_verification.results_access_required", userId, session.id, status);
  return {
    status,
    verified: false,
    submissionReceived: true,
    nameMatched: null,
    dateOfBirthMatched: null,
    errorCode: IDENTITY_RESULTS_ACCESS_ERROR,
  };
}

async function updateIdentityState(
  userId: string,
  session: Stripe.Identity.VerificationSession,
  expectedDateOfBirth?: string | null,
) {
  let dateOfBirth = normalizedDateOfBirth(expectedDateOfBirth);
  if (session.status === "verified" && !dateOfBirth) {
    const { data: profile, error: profileError } = await adminClient!
      .from("profiles")
      .select("date_of_birth")
      .eq("id", userId)
      .single();
    if (profileError) throw profileError;
    if (!dateOfBirth) dateOfBirth = normalizedDateOfBirth(profile?.date_of_birth);
  }

  const dateOfBirthMatched = session.status !== "verified" ||
    verifiedIdentityDateOfBirthMatches(dateOfBirth, session);
  const effectiveStatus = session.status === "verified" && !dateOfBirthMatched
    ? "requires_input"
    : session.status;
  const mismatchErrorCode = "date_of_birth_mismatch";
  const updates: Record<string, unknown> = {
    stripe_identity_verification_session_id: dateOfBirthMatched ? session.id : null,
    identity_verification_status: effectiveStatus,
    identity_verification_updated_at: new Date().toISOString(),
    identity_verification_livemode: session.livemode,
    identity_verification_error_code: dateOfBirthMatched
      ? session.last_error?.code || null
      : mismatchErrorCode,
  };
  if (session.status === "verified" && dateOfBirthMatched) {
    updates.identity_verified_at = new Date().toISOString();
  }
  if (!dateOfBirthMatched) updates.identity_verified_at = null;
  const { error } = await adminClient!.from("profiles").update(updates).eq("id", userId);
  if (error) throw error;

  if (!dateOfBirthMatched) {
    await writeIdentityAudit(`identity_verification.${mismatchErrorCode}`, userId, session.id, effectiveStatus);
    return {
      status: effectiveStatus,
      verified: false,
      nameMatched: null,
      dateOfBirthMatched,
      errorCode: mismatchErrorCode,
    };
  }

  if (session.status === "verified") {
    const { data: rentals } = await adminClient!
      .from("rentals")
      .select("id, status, payment_status")
      .eq("user_id", userId)
      .neq("status", "cancelled")
      .neq("payment_status", "paid");
    for (const rental of rentals || []) {
      const { data: repricedRental, error: pricingError } = await adminClient!.rpc("reprice_unpaid_rental_for_verified_dob", {
        p_rental_id: rental.id,
        p_user_id: userId,
      });
      if (pricingError) console.warn("Could not reprice rental after DOB verification", rental.id, pricingError.message);
      if (!pricingError && repricedRental?.stripe_checkout_session_id) {
        const verifiedAmountCents = cents(
          Number(repricedRental.rental_total || 0) +
          Number(repricedRental.service_fee_total || 0) +
          Number(repricedRental.tax_amount || 0) +
          Number(repricedRental.security_deposit || 0),
        );
        try {
          await reusableCheckout(
            repricedRental.stripe_checkout_session_id,
            "rental",
            rental.id,
            verifiedAmountCents,
          );
        } catch (checkoutError) {
          console.warn("Could not reconcile an existing checkout after DOB repricing", rental.id, checkoutError);
        }
      }
      if (["documents_needed", "document_review", "approved"].includes(String(rental.status || ""))) {
        const { error: syncError } = await adminClient!.rpc("sync_rental_ready_for_pickup_global", { p_rental_id: rental.id });
        if (syncError) console.warn("Could not sync rental after identity verification", rental.id, syncError.message);
      }
    }
  }
  return {
    status: effectiveStatus,
    verified: effectiveStatus === "verified",
    nameMatched: null,
    dateOfBirthMatched: true,
    errorCode: session.last_error?.code || null,
  };
}

async function requireMatchingStoredIdentity(userId: string) {
  const { data: profile, error } = await adminClient!
    .from("profiles")
    .select("full_name, date_of_birth, identity_verification_status, identity_verification_error_code, stripe_identity_verification_session_id")
    .eq("id", userId)
    .single();
  if (error || !profile) throw new Error(error?.message || "Customer profile not found.");
  if (
    String(profile.identity_verification_error_code || "").toLowerCase() === IDENTITY_RESULTS_ACCESS_ERROR ||
    String(profile.identity_verification_status || "").toLowerCase() === "configuration_required"
  ) {
    throw new Error("Your Stripe submission was received, but Rent Me CT must finish secure Identity-results setup before payment. Do not submit your ID again.");
  }
  if (String(profile.identity_verification_status || "").toLowerCase() !== "verified") {
    throw new Error("Complete Stripe Identity verification before payment.");
  }
  if (!profile.stripe_identity_verification_session_id) {
    throw new Error("Your Stripe Identity record is incomplete. Complete Identity verification once before payment.");
  }

  const identityResult = await retrieveIdentitySessionForComparison(
    profile.stripe_identity_verification_session_id,
  );
  if (!identityResult.sensitiveResultsAvailable) {
    await markIdentityResultsAccessRequired(userId, identityResult.session);
    throw new Error("Your Stripe submission was received, but Rent Me CT must finish secure Identity-results setup before payment. Do not submit your ID again.");
  }
  const session = identityResult.session;
  const state = await updateIdentityState(userId, session, profile.date_of_birth);
  if (!state.verified) {
    if (!state.dateOfBirthMatched) {
      throw new Error("The birthday on your Stripe-verified government ID does not match the renter's date of birth. Update the birthday and retry Identity verification.");
    }
    throw new Error("Complete Stripe Identity verification before payment.");
  }
  return state;
}

async function handleIdentityVerification(req: Request, payload: CheckoutPayload, createIfNeeded: boolean) {
  const user = await getUser(req);
  if (!user?.id) throw new Error("You must be signed in to verify your identity.");
  if (createIfNeeded) assertPaymentCreationEnabled();
  const { data: profile, error } = await adminClient!
    .from("profiles")
    .select("id, full_name, date_of_birth, stripe_identity_verification_session_id, identity_verification_status, identity_verification_error_code")
    .eq("id", user.id)
    .single();
  if (error || !profile) throw new Error(error?.message || "Customer profile not found.");

  let session: Stripe.Identity.VerificationSession | null = null;
  let identityMismatchErrorCode = "";
  if (profile.stripe_identity_verification_session_id) {
    const identityResult = await retrieveIdentitySessionForComparison(
      profile.stripe_identity_verification_session_id,
    );
    session = identityResult.session;
    if (session.status === "verified" && !identityResult.sensitiveResultsAvailable) {
      return await markIdentityResultsAccessRequired(user.id, session);
    }
    const state = await updateIdentityState(user.id, session, profile.date_of_birth);
    if (state.verified || state.status === "processing") {
      return {
        status: state.status,
        verified: state.verified,
        nameMatched: state.nameMatched,
        dateOfBirthMatched: state.dateOfBirthMatched,
      };
    }
    if (session.status === "requires_input" && session.url) {
      return { status: session.status, verified: false, url: session.url };
    }
    if (!state.dateOfBirthMatched) {
      identityMismatchErrorCode = state.errorCode || "date_of_birth_mismatch";
      session = null;
    }
  }

  if (!createIfNeeded) {
    return {
      status: identityMismatchErrorCode ? "requires_input" : session?.status || profile.identity_verification_status || "unverified",
      verified: false,
      errorCode: identityMismatchErrorCode || session?.last_error?.code || profile.identity_verification_error_code || null,
    };
  }

  session = await stripe!.identity.verificationSessions.create({
    type: "document",
    client_reference_id: user.id,
    return_url: identityReturnUrl(req, payload.returnUrl),
    options: { document: { require_matching_selfie: true } },
    metadata: { user_id: user.id, purpose: "renter_identity" },
  }, { idempotencyKey: `rentmect-identity-${user.id}-${Date.now()}` });
  await updateIdentityState(user.id, session, profile.date_of_birth);
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

  // A temporary administrator Stripe installment is not money owed. Reconcile
  // it against Stripe before consulting the deposit blocker ledger. Expired,
  // missing, and never-created attempts are retired; a genuinely open or
  // processing payment remains visible and blocks the refund with a precise
  // explanation.
  const activeInstallment = await findActiveAdminInstallment(rental.id);
  if (activeInstallment?.id) {
    const attemptStatus = String(activeInstallment.status || "pending").replaceAll("_", " ");
    throw new Error(
      `A Stripe rental payment attempt is still ${attemptStatus} and must be completed or cancelled before returning the deposit (attempt ${activeInstallment.id}).`,
    );
  }
  await adminClient!.rpc("sync_deposit_action_task", { p_rental_id: rental.id });

  const { data: chainBlockers, error: chainBlockerError } = await adminClient!.rpc(
    "rentmect_deposit_chain_release_blockers",
    { p_rental_id: rental.id },
  );
  if (chainBlockerError) throw new Error(`The continuation-chain deposit check failed: ${chainBlockerError.message}`);
  if (Array.isArray(chainBlockers) && chainBlockers.length > 0) {
    const blockerSummary = chainBlockers
      .slice(0, 4)
      .map((blocker) => String(blocker?.detail || blocker?.type || "continuation-chain review required"))
      .join("; ");
    const message = `The security deposit is still protecting the rental continuation chain: ${blockerSummary}`;
    const blockerUpdate: Record<string, unknown> = {
      deposit_release_attempted_at: new Date().toISOString(),
      deposit_release_error: message,
    };
    if (source === "automatic") blockerUpdate.deposit_release_due_at = null;
    await adminClient!.from("rentals").update(blockerUpdate).eq("id", rental.id);
    throw new Error(message);
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

function normalizedRefundStatus(status: string | null) {
  if (status === "succeeded") return "succeeded";
  if (status === "failed") return "failed";
  if (status === "canceled") return "cancelled";
  return "pending";
}

type ReconciliationIssueInput = {
  dedupeKey: string;
  issueType: string;
  status: "processing" | "open" | "resolved" | "refunded";
  stripeEventId?: string;
  checkoutSessionId?: string;
  paymentIntentId?: string;
  refundId?: string;
  targetType?: "rental" | "extension" | "charge" | "unknown";
  targetId?: string;
  rentalId?: string;
  extensionRequestId?: string;
  amountCents?: number;
  currency?: string;
  errorMessage?: string;
  payload?: Record<string, unknown>;
};

function uuidOrNull(value?: string) {
  return value && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
    ? value
    : null;
}

async function upsertReconciliationIssue(input: ReconciliationIssueInput) {
  const { data, error } = await adminClient!.rpc("upsert_stripe_reconciliation_issue", {
    p_dedupe_key: input.dedupeKey,
    p_issue_type: input.issueType,
    p_status: input.status,
    p_stripe_event_id: input.stripeEventId || null,
    p_checkout_session_id: input.checkoutSessionId || null,
    p_payment_intent_id: input.paymentIntentId || null,
    p_refund_id: input.refundId || null,
    p_target_type: input.targetType || "unknown",
    p_target_id: uuidOrNull(input.targetId),
    p_rental_id: uuidOrNull(input.rentalId),
    p_extension_request_id: uuidOrNull(input.extensionRequestId),
    p_amount: Math.max(0, Number(input.amountCents || 0)) / 100,
    p_currency: String(input.currency || "usd").toLowerCase(),
    p_error_message: input.errorMessage || null,
    p_payload: input.payload || {},
  });
  if (error) throw new Error(`Stripe reconciliation queue failed: ${error.message}`);
  return Array.isArray(data) ? data[0] : data;
}

async function queueReconciliationAlert(
  issue: Record<string, unknown>,
  input: ReconciliationIssueInput,
) {
  const issueId = String(issue?.id || "");
  if (!issueId) throw new Error("Stripe reconciliation issue was not assigned an id.");
  const { error } = await adminClient!.from("admin_notification_events").upsert({
    event_type: "stripe_reconciliation_required",
    source_id: issueId,
    rental_id: uuidOrNull(input.rentalId),
    dedupe_key: `stripe_reconciliation_required:${issueId}`,
    metadata: {
      issue_type: input.issueType,
      target_type: input.targetType || "unknown",
      target_id: input.targetId || null,
      checkout_session_id: input.checkoutSessionId || null,
      payment_intent_id: input.paymentIntentId || null,
      refund_id: input.refundId || null,
      amount: Math.max(0, Number(input.amountCents || 0)) / 100,
      currency: input.currency || "usd",
      error: input.errorMessage || null,
    },
  }, { onConflict: "dedupe_key", ignoreDuplicates: true });
  if (error) throw new Error(`Stripe reconciliation alert failed: ${error.message}`);
}

async function openReconciliationIssue(input: Omit<ReconciliationIssueInput, "status">) {
  const issue = await upsertReconciliationIssue({ ...input, status: "open" });
  await queueReconciliationAlert(issue, { ...input, status: "open" });
  return issue;
}

async function recordRefundLedger(params: {
  refund: Stripe.Refund;
  rentalId: string;
  paymentIntentId: string;
  sourceType: string;
  reason: string;
  stripeEventId?: string;
  extensionRequestId?: string;
  ledgerId?: string;
}) {
  let existingId = "";
  const { data: existingByStripe, error: lookupError } = await adminClient!
    .from("rental_payment_refunds")
    .select("id")
    .eq("stripe_refund_id", params.refund.id)
    .maybeSingle();
  if (lookupError) throw new Error(`Refund ledger lookup failed: ${lookupError.message}`);
  existingId = existingByStripe?.id || "";
  if (!existingId && uuidOrNull(params.ledgerId)) {
    const { data: existingById, error: idLookupError } = await adminClient!
      .from("rental_payment_refunds")
      .select("id")
      .eq("id", params.ledgerId!)
      .maybeSingle();
    if (idLookupError) throw new Error(`Refund ledger lookup failed: ${idLookupError.message}`);
    existingId = existingById?.id || "";
  }
  const values = {
    rental_id: params.rentalId,
    extension_request_id: uuidOrNull(params.extensionRequestId),
    stripe_payment_intent_id: params.paymentIntentId,
    stripe_refund_id: params.refund.id,
    stripe_event_id: params.stripeEventId || null,
    amount: Number(params.refund.amount || 0) / 100,
    currency: params.refund.currency || "usd",
    reason: params.reason,
    source_type: params.sourceType,
    status: normalizedRefundStatus(params.refund.status),
    failure_reason: params.refund.failure_reason || null,
    updated_at: new Date().toISOString(),
  };
  const query = existingId
    ? adminClient!.from("rental_payment_refunds").update(values).eq("id", existingId)
    : adminClient!.from("rental_payment_refunds").insert({ id: uuidOrNull(params.ledgerId) || crypto.randomUUID(), ...values });
  const { error } = await query;
  if (error) throw new Error(`Refund ledger update failed: ${error.message}`);
}

async function paymentIntentForRefund(refund: Stripe.Refund) {
  const direct = typeof refund.payment_intent === "string"
    ? refund.payment_intent
    : refund.payment_intent?.id || "";
  if (direct) return direct;
  const chargeId = typeof refund.charge === "string" ? refund.charge : refund.charge?.id || "";
  if (!chargeId) return "";
  const charge = await stripe!.charges.retrieve(chargeId);
  return typeof charge.payment_intent === "string"
    ? charge.payment_intent
    : charge.payment_intent?.id || "";
}

async function matchRefundPaymentIntent(paymentIntentId: string) {
  if (!paymentIntentId) return null;
  const { data: rental, error: rentalError } = await adminClient!
    .from("rentals")
    .select("id")
    .or(`stripe_payment_intent_id.eq.${paymentIntentId},stripe_deposit_intent_id.eq.${paymentIntentId}`)
    .limit(1)
    .maybeSingle();
  if (rentalError) throw rentalError;
  if (rental) return { targetType: "rental" as const, targetId: rental.id, rentalId: rental.id };

  const { data: extension, error: extensionError } = await adminClient!
    .from("rental_extension_requests")
    .select("id, rental_id")
    .eq("stripe_payment_intent_id", paymentIntentId)
    .limit(1)
    .maybeSingle();
  if (extensionError) throw extensionError;
  if (extension) {
    return {
      targetType: "extension" as const,
      targetId: extension.id,
      rentalId: extension.rental_id,
      extensionRequestId: extension.id,
    };
  }

  const { data: charge, error: chargeError } = await adminClient!
    .from("rental_charge_items")
    .select("id, rental_id")
    .eq("stripe_payment_intent_id", paymentIntentId)
    .limit(1)
    .maybeSingle();
  if (chargeError) throw chargeError;
  return charge
    ? { targetType: "charge" as const, targetId: charge.id, rentalId: charge.rental_id }
    : null;
}

async function refundRentalPayment(req: Request, payload: CheckoutPayload) {
  if (!payload.rentalId) throw new Error("Rental id is required.");
  if (!payload.refundRequestId || !/^[0-9a-f-]{36}$/i.test(payload.refundRequestId)) {
    throw new Error("A valid refund request id is required.");
  }
  const amountCents = Math.trunc(Number(payload.amountCents || 0));
  if (!Number.isSafeInteger(amountCents) || amountCents < 50) {
    throw new Error("Refund amount must be at least $0.50.");
  }
  const reason = String(payload.reason || "").trim();
  if (reason.length < 5) throw new Error("Enter a refund reason of at least 5 characters.");

  const admin = await requireAdmin(req, "payment.refund");
  const { data: existingRequest, error: existingError } = await adminClient!
    .from("rental_payment_refunds")
    .select("*")
    .eq("id", payload.refundRequestId)
    .maybeSingle();
  if (existingError) throw existingError;
  if (existingRequest) {
    return {
      refundRequestId: existingRequest.id,
      refundId: existingRequest.stripe_refund_id,
      amount: cents(Number(existingRequest.amount || 0)),
      status: existingRequest.status,
      duplicate: true,
    };
  }

  const { data: rental, error: rentalError } = await adminClient!
    .from("rentals")
    .select("id, user_id, payment_status, payment_provider, stripe_payment_intent_id, payment_amount_cents")
    .eq("id", payload.rentalId)
    .single();
  if (rentalError || !rental) throw new Error(rentalError?.message || "Rental not found.");
  if (String(rental.payment_provider || "").toLowerCase() !== "stripe" || !rental.stripe_payment_intent_id) {
    throw new Error("This rental was not paid through Stripe.");
  }
  if (String(rental.payment_status || "").toLowerCase() !== "paid") {
    throw new Error("Only a paid rental can be refunded.");
  }

  await adminClient!.rpc("ensure_rental_deposit_allocation", { p_rental_id: rental.id });
  const [{ data: allocations, error: allocationError }, paymentIntent, charges] = await Promise.all([
    adminClient!
      .from("rental_deposit_allocations")
      .select("amount_held, amount_released, status")
      .eq("payment_provider", "stripe")
      .eq("stripe_payment_intent_id", rental.stripe_payment_intent_id),
    stripe!.paymentIntents.retrieve(rental.stripe_payment_intent_id),
    stripe!.charges.list({ payment_intent: rental.stripe_payment_intent_id, limit: 100 }),
  ]);
  if (allocationError) throw allocationError;

  const protectedDepositCents = cents((allocations || [])
    .filter((allocation) => !["released", "transferred"].includes(String(allocation.status || "").toLowerCase()))
    .reduce(
      (sum, allocation) => sum + Math.max(0, Number(allocation.amount_held || 0) - Number(allocation.amount_released || 0)),
      0,
    ));
  const alreadyRefundedCents = charges.data.reduce(
    (sum, charge) => sum + Number(charge.amount_refunded || 0),
    0,
  );
  const capturedCents = Number(paymentIntent.amount_received || rental.payment_amount_cents || 0);
  const refundableRentalCents = Math.max(0, capturedCents - alreadyRefundedCents - protectedDepositCents);
  if (amountCents > refundableRentalCents) {
    throw new Error(
      `The maximum rental-payment refund is ${moneyDescription(refundableRentalCents)}. The unreleased security deposit remains protected separately.`,
    );
  }

  const { data: reservation, error: reservationError } = await adminClient!
    .rpc("reserve_rental_payment_refund", {
      p_id: payload.refundRequestId,
      p_rental_id: rental.id,
      p_stripe_payment_intent_id: rental.stripe_payment_intent_id,
      p_amount: amountCents / 100,
      p_reason: reason,
      p_requested_by: admin.user.id,
      p_stripe_refundable_max: refundableRentalCents / 100,
    });
  if (reservationError) {
    const { data: duplicate } = await adminClient!
      .from("rental_payment_refunds")
      .select("*")
      .eq("id", payload.refundRequestId)
      .maybeSingle();
    if (duplicate) {
      return {
        refundRequestId: duplicate.id,
        refundId: duplicate.stripe_refund_id,
        amount: cents(Number(duplicate.amount || 0)),
        status: duplicate.status,
        duplicate: true,
      };
    }
    throw reservationError;
  }
  const reservedRefund = Array.isArray(reservation) ? reservation[0] : reservation;
  if (!reservedRefund) throw new Error("The refund reservation could not be confirmed.");
  if (reservedRefund.stripe_refund_id || !["processing", "pending"].includes(String(reservedRefund.status || ""))) {
    return {
      refundRequestId: reservedRefund.id,
      refundId: reservedRefund.stripe_refund_id,
      amount: cents(Number(reservedRefund.amount || 0)),
      status: reservedRefund.status,
      duplicate: true,
    };
  }

  try {
    const refund = await stripe!.refunds.create({
      payment_intent: rental.stripe_payment_intent_id,
      amount: amountCents,
      metadata: {
        refund_type: "rental_payment",
        refund_request_id: payload.refundRequestId,
        rental_id: rental.id,
        admin_user_id: admin.user.id,
      },
    }, { idempotencyKey: `rental-payment-refund-${payload.refundRequestId}` });
    const status = normalizedRefundStatus(refund.status);
    const { error: updateError } = await adminClient!
      .from("rental_payment_refunds")
      .update({
        stripe_refund_id: refund.id,
        status,
        failure_reason: refund.failure_reason || null,
        updated_at: new Date().toISOString(),
      })
      .eq("id", payload.refundRequestId);
    if (updateError) throw updateError;

    await Promise.all([
      adminClient!.from("admin_audit_logs").insert({
        actor_user_id: admin.user.id,
        actor_email: admin.profile.email || admin.user.email,
        actor_role: "admin",
        action: "rental_payment.refund_requested",
        entity_type: "rental_payment",
        entity_id: rental.id,
        metadata: {
          refund_request_id: payload.refundRequestId,
          stripe_refund_id: refund.id,
          amount: amountCents / 100,
          reason,
          protected_deposit: protectedDepositCents / 100,
        },
      }),
      adminClient!.from("rental_audit_events").insert({
        rental_id: rental.id,
        user_id: rental.user_id,
        actor_id: admin.user.id,
        event_type: "admin_rental_payment_refund_requested",
        event_payload: {
          refund_request_id: payload.refundRequestId,
          stripe_refund_id: refund.id,
          amount: amountCents / 100,
          reason,
        },
      }),
    ]);
    return {
      refundRequestId: payload.refundRequestId,
      refundId: refund.id,
      amount: amountCents,
      status,
      refundableRentalAmountRemaining: (refundableRentalCents - amountCents) / 100,
    };
  } catch (refundError) {
    const message = refundError instanceof Error ? refundError.message : "Stripe refund failed.";
    await adminClient!
      .from("rental_payment_refunds")
      .update({ status: "failed", failure_reason: message.slice(0, 1000), updated_at: new Date().toISOString() })
      .eq("id", payload.refundRequestId);
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

  const rentalSelect = "id, user_id, vehicle_id, status, payment_status, rental_total, pre_discount_rental_total, discount_code, discount_amount, manual_discount_amount, manual_discount_type, manual_discount_value, service_fee_total, tax_amount, security_deposit, agreement_signed, checkout_expires_at, payment_due_at, stripe_checkout_session_id, vehicles(name, security_deposit)";
  const { data: initialRental, error } = await adminClient
    .from("rentals")
    .select(rentalSelect)
    .eq("id", payload.rentalId)
    .single();

  if (error || !initialRental) throw new Error(error?.message || "Rental not found.");
  let rental = initialRental;
  if (rental.user_id !== userId) throw new Error("This rental does not belong to the signed-in customer.");
  if (String(rental.payment_status || "").toLowerCase() === "paid") {
    throw new Error("This rental is already paid.");
  }
  if (String(rental.status || "").toLowerCase() === "cancelled") {
    throw new Error("Cancelled rentals cannot be paid.");
  }
  const activeAdminInstallment = await findActiveAdminInstallment(rental.id);
  if (activeAdminInstallment?.id) {
    throw new Error("An administrator-started Stripe installment is already open for this rental. Complete or cancel that checkout before starting another payment.");
  }
  if (["partially_paid", "partial"].includes(String(rental.payment_status || "").toLowerCase())) {
    if (!adminAssisted && !rental.agreement_signed) {
      throw new Error("Sign the revised rental agreement before paying the remaining balance.");
    }
    const { data: balanceCharge, error: balanceError } = await adminClient!
      .from("rental_charge_items")
      .select("id")
      .eq("rental_id", rental.id)
      .eq("charge_type", "rental_amendment")
      .in("status", ["pending", "checkout_open", "failed"])
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (balanceError) throw balanceError;
    if (!balanceCharge?.id) {
      throw new Error("The remaining rental balance is still being recalculated. Refresh and try again.");
    }
    return await createRentalChargeCheckout(
      req,
      { ...payload, targetType: "charge", chargeId: balanceCharge.id },
      userId,
    );
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
  if (!adminAssisted) {
    await requireMatchingStoredIdentity(userId);
    const { error: pricingError } = await adminClient.rpc("reprice_unpaid_rental_for_verified_dob", {
      p_rental_id: rental.id,
      p_user_id: userId,
    });
    if (pricingError) {
      throw new Error(`Verified age pricing could not be refreshed: ${pricingError.message}`);
    }
    const { data: refreshedRental, error: refreshError } = await adminClient
      .from("rentals")
      .select(rentalSelect)
      .eq("id", rental.id)
      .single();
    if (refreshError || !refreshedRental) {
      throw new Error(refreshError?.message || "The verified rental price could not be loaded.");
    }
    rental = refreshedRental;
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
  const { data: hasInsurance, error: insurancePacketError } = await adminClient.rpc(
    "rentmect_insurance_packet_complete",
    {
      p_rental_id: rental.id,
      p_extension_request_id: null,
      p_require_approved: false,
    },
  );
  if (insurancePacketError) throw new Error(insurancePacketError.message);
  if (!adminAssisted && (!hasLicense || !hasInsurance)) {
    throw new Error("Upload your driver license and insurance paperwork before payment.");
  }

  const vehicle = Array.isArray(rental.vehicles) ? rental.vehicles[0] : rental.vehicles;
  // The database recalculates the unpaid rental from the Stripe-verified DOB
  // immediately before checkout. Stripe then charges that locked snapshot.
  const securityDeposit = Number(rental.security_deposit || 0);

  const amountCents = cents(
    Number(rental.rental_total || 0) +
    Number(rental.service_fee_total || 0) +
    Number(rental.tax_amount || 0) +
    securityDeposit,
  );
  if (amountCents === 0) {
    const { data: completedRental, error: compError } = await adminClient.rpc(
      "complete_discount_comped_rental",
      { p_rental_id: rental.id, p_user_id: userId },
    );
    if (compError || !completedRental) {
      throw new Error(compError?.message || "The no-charge discount checkout could not be completed.");
    }
    return {
      completed: true,
      noPaymentRequired: true,
      rentalId: completedRental.id,
      paymentStatus: completedRental.payment_status,
    };
  }
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
            ? `Rental with reservation savings${securityDeposit > 0 ? ", CT tax, and refundable security deposit" : " and CT tax; security deposit waived"}: ${moneyDescription(amountCents)}`
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
    .select("id, rental_id, user_id, name, charge_type, source_type, description, total_amount, included_in_initial_payment, status, stripe_checkout_session_id")
    .eq("id", payload.chargeId)
    .single();
  if (error || !charge) throw new Error(error?.message || "Rental charge not found.");
  if (charge.user_id !== userId) throw new Error("This charge does not belong to the signed-in customer.");
  if (charge.included_in_initial_payment) throw new Error("This fee is included in the original booking payment.");
  if (charge.status === "paid") throw new Error("This charge is already paid.");
  if (charge.status === "waived") throw new Error("This charge was waived.");
  if (charge.charge_type !== "rental_installment") {
    const activeAdminInstallment = await findActiveAdminInstallment(charge.rental_id);
    if (activeAdminInstallment?.id) {
      throw new Error("An administrator-started Stripe installment is already open for this rental. Complete or cancel that checkout before paying another balance.");
    }
  }
  const amountCents = cents(Number(charge.total_amount || 0));
  if (amountCents < 50) throw new Error("Charge amount is too small for Stripe Checkout.");
  const priorChargeCheckout = await reusableCheckout(
    charge.stripe_checkout_session_id,
    "charge",
    charge.id,
    amountCents,
  );
  if (priorChargeCheckout.url) {
    return {
      url: priorChargeCheckout.url,
      sessionId: priorChargeCheckout.sessionId,
      targetType: "charge",
      targetId: charge.id,
      rentalId: charge.rental_id,
    };
  }
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
          description: charge.description || "Rental payment",
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
  return {
    url: session.url,
    sessionId: session.id,
    targetType: "charge",
    targetId: charge.id,
    rentalId: charge.rental_id,
  };
}

async function createAdminRentalChargeCheckout(req: Request, payload: CheckoutPayload) {
  await requireAdmin(req, "payment.collect");
  if (!payload.chargeId) throw new HttpError("Rental charge id is required.", 400);
  const { data: charge, error } = await adminClient!
    .from("rental_charge_items")
    .select("id, user_id")
    .eq("id", payload.chargeId)
    .single();
  if (error || !charge?.user_id) {
    throw new HttpError(error?.message || "Rental charge not found.", 404);
  }
  return await createRentalChargeCheckout(req, payload, charge.user_id);
}

async function createExtensionCheckout(req: Request, payload: CheckoutPayload, userId: string) {
  assertPaymentCreationEnabled();
  if (!payload.extensionRequestId) throw new Error("Extension request id is required.");

  const { data: request, error } = await adminClient
    .from("rental_extension_requests")
    .select("id, rental_id, user_id, request_kind, status, payment_status, payment_due_at, extension_total_amount, existing_deposit_held, replacement_deposit_required, deposit_carried_amount, deposit_increase_amount, deposit_decrease_amount, requested_return_date, requested_return_time, stripe_checkout_session_id, created_at, rentals!rental_extension_requests_rental_id_fkey(vehicles(name))")
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
  await requireMatchingStoredIdentity(userId);

  const { data: extensionInsurance, error: insuranceError } = await adminClient.rpc(
    "rentmect_insurance_packet_complete",
    {
      p_rental_id: request.rental_id,
      p_extension_request_id: request.id,
      p_require_approved: true,
    },
  );
  if (insuranceError) throw new Error(insuranceError.message);
  if (!extensionInsurance) {
    throw new Error("The new proof of insurance for this extension must be approved before payment.");
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

async function createAdminExtensionCheckout(req: Request, payload: CheckoutPayload) {
  await requireAdmin(req, "payment.collect");
  if (!payload.extensionRequestId) throw new HttpError("Extension request id is required.", 400);
  const { data: extension, error } = await adminClient!
    .from("rental_extension_requests")
    .select("id, user_id")
    .eq("id", payload.extensionRequestId)
    .single();
  if (error || !extension?.user_id) {
    throw new HttpError(error?.message || "Extension request not found.", 404);
  }
  return await createExtensionCheckout(req, payload, extension.user_id);
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
      charge_name: charge.name,
      payment_intent_id: paymentIntent.id,
      amount_total: amountCents,
      currency: paymentIntent.currency || "usd",
      actor_email: admin.profile.email || admin.user.email || null,
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
  const admin = await requireAdmin(req, "charge.manage");
  assertPaymentCreationEnabled();
  const { data: charge, error: chargeError } = await adminClient!
    .from("rental_charge_items")
    .select("id, rental_id, user_id, name, total_amount, included_in_initial_payment, status, stripe_customer_id, stripe_checkout_session_id, stripe_payment_intent_id, admin_charge_attempts")
    .eq("id", payload.chargeId)
    .single();
  if (chargeError || !charge) throw new Error(chargeError?.message || "Rental charge not found.");
  if (charge.included_in_initial_payment) throw new Error("This fee is included in the original booking payment.");
  if (charge.status === "paid") {
    return { status: "already_settled", charge, reason: "This balance is already paid." };
  }
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

    const { data: intentClaim, error: intentClaimError } = await adminClient!
      .from("rental_charge_items")
      .update({
      payment_provider: "stripe",
      stripe_customer_id: stripeCustomerId,
      stripe_payment_intent_id: paymentIntent.id,
      payment_amount_cents: amountCents,
      payment_currency: "usd",
      updated_at: new Date().toISOString(),
      })
      .eq("id", charge.id)
      .eq("status", "checkout_open")
      .eq("admin_charge_attempts", nextAttempt)
      .select("id")
      .maybeSingle();
    if (intentClaimError) throw intentClaimError;
    if (!intentClaim) {
      await stripe!.paymentIntents.cancel(paymentIntent.id);
      return { status: "already_settled", reason: "The balance was settled through another payment method before Stripe confirmation." };
    }

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
    const { data: latestCharge } = await adminClient!
      .from("rental_charge_items")
      .select("status, payment_provider, external_payment_method")
      .eq("id", charge.id)
      .maybeSingle();
    if (latestCharge?.status === "paid" && latestCharge.payment_provider !== "stripe") {
      return {
        status: "already_settled",
        reason: `The balance was recorded through ${latestCharge.external_payment_method || latestCharge.payment_provider || "another payment method"}.`,
      };
    }
    if (failedIntent?.status === "succeeded") {
      await openReconciliationIssue({
        dedupeKey: `payment-intent:${failedIntent.id}`,
        issueType: "payment_reconciliation",
        paymentIntentId: failedIntent.id,
        targetType: "charge",
        targetId: charge.id,
        rentalId: charge.rental_id,
        amountCents: failedIntent.amount_received || failedIntent.amount,
        currency: failedIntent.currency || "usd",
        errorMessage: `Stripe captured the saved-card charge but Admin reconciliation failed: ${reason}`,
        payload: { source: "admin_saved_card" },
      });
    }
    await adminClient!.from("rental_charge_items").update({
      status: "failed",
      stripe_payment_intent_id: failedIntent?.id || paymentIntent?.id || null,
      last_admin_charge_error: reason.slice(0, 1000),
      updated_at: new Date().toISOString(),
    }).eq("id", charge.id).neq("status", "paid");
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

async function waiveRentalCharge(req: Request, payload: CheckoutPayload) {
  if (!payload.chargeId) throw new HttpError("Rental charge id is required.", 400);
  const admin = await requireAdmin(req, "charge.manage");
  const { data: charge, error: chargeError } = await adminClient!
    .from("rental_charge_items")
    .select("id, rental_id, user_id, name, total_amount, included_in_initial_payment, status, stripe_checkout_session_id, stripe_payment_intent_id, admin_charge_attempts")
    .eq("id", payload.chargeId)
    .single();
  if (chargeError || !charge) {
    throw new HttpError(chargeError?.message || "Rental charge not found.", 404);
  }
  if (charge.included_in_initial_payment) {
    throw new HttpError("This fee was included in the original rental payment.", 409);
  }
  if (charge.status === "paid") {
    return { status: "already_paid", charge, reason: "This charge was already paid and cannot be waived." };
  }
  if (charge.status === "waived") {
    return { status: "already_waived", charge, reason: "This charge was already waived." };
  }
  if (!["pending", "failed", "checkout_open"].includes(charge.status)) {
    throw new HttpError("This charge cannot be waived in its current state.", 409);
  }

  const recordStripePayment = async (
    paymentIntent: Stripe.PaymentIntent,
    checkoutSessionId: string,
    amountTotal?: number | null,
    currency?: string | null,
  ) => {
    const { data: recorded, error: recordError } = await adminClient!.rpc(
      "record_stripe_rental_charge_payment",
      {
        p_charge_id: charge.id,
        p_checkout_session_id: checkoutSessionId,
        p_payment_intent_id: paymentIntent.id,
        p_amount_total: amountTotal || paymentIntent.amount_received || paymentIntent.amount,
        p_currency: currency || paymentIntent.currency || "usd",
      },
    );
    if (recordError) throw recordError;
    return recorded;
  };

  let checkoutExpired = false;
  if (charge.stripe_checkout_session_id?.startsWith("cs_")) {
    const checkout = await stripe!.checkout.sessions.retrieve(charge.stripe_checkout_session_id);
    const paymentIntentId = typeof checkout.payment_intent === "string"
      ? checkout.payment_intent
      : checkout.payment_intent?.id || "";
    if (checkout.payment_status === "paid" || checkout.status === "complete") {
      if (!paymentIntentId) {
        throw new HttpError("Stripe Checkout already completed. Wait for payment reconciliation before trying again.", 409);
      }
      const paymentIntent = await stripe!.paymentIntents.retrieve(paymentIntentId);
      if (paymentIntent.status === "succeeded") {
        const recorded = await recordStripePayment(
          paymentIntent,
          checkout.id,
          checkout.amount_total,
          checkout.currency,
        );
        return {
          status: "already_paid",
          charge: recorded,
          reason: "Stripe already collected this charge, so it was recorded as paid instead of waived.",
        };
      }
      throw new HttpError("A Stripe Checkout payment is already processing. Wait for reconciliation before trying again.", 409);
    }
    if (checkout.status === "open") {
      await stripe!.checkout.sessions.expire(checkout.id);
      checkoutExpired = true;
    }
  }

  if (charge.stripe_payment_intent_id?.startsWith("pi_")) {
    const paymentIntent = await stripe!.paymentIntents.retrieve(charge.stripe_payment_intent_id);
    if (paymentIntent.status === "succeeded") {
      const recorded = await recordStripePayment(
        paymentIntent,
        charge.stripe_checkout_session_id || `off_session:${paymentIntent.id}`,
      );
      return {
        status: "already_paid",
        charge: recorded,
        reason: "Stripe already collected this charge, so it was recorded as paid instead of waived.",
      };
    }
    if (["processing", "requires_capture"].includes(paymentIntent.status)) {
      throw new HttpError("A Stripe payment is already processing for this charge. Wait for it to finish before waiving.", 409);
    }
    if (paymentIntent.status !== "canceled") {
      await stripe!.paymentIntents.cancel(paymentIntent.id);
    }
  }

  const { data: waived, error: waiveError } = await adminClient!.rpc(
    "waive_admin_rental_charge_guarded",
    {
      p_charge_id: charge.id,
      p_actor_id: admin.user.id,
      p_expected_status: charge.status,
      p_expected_checkout_session_id: charge.stripe_checkout_session_id || null,
      p_expected_payment_intent_id: charge.stripe_payment_intent_id || null,
      p_expected_admin_charge_attempts: Number(charge.admin_charge_attempts || 0),
    },
  );
  if (waiveError) throw waiveError;

  await adminClient!.from("admin_audit_logs").insert({
    actor_user_id: admin.user.id,
    actor_email: admin.profile.email || admin.user.email || null,
    actor_role: "admin",
    action: "rental_charge.waived",
    entity_type: "rental_charge",
    entity_id: charge.id,
    metadata: {
      rental_id: charge.rental_id,
      amount: charge.total_amount,
      previous_status: charge.status,
      checkout_session_id: charge.stripe_checkout_session_id || null,
      payment_intent_id: charge.stripe_payment_intent_id || null,
      checkout_expired: checkoutExpired,
    },
  });

  return { status: "waived", charge: waived, checkoutExpired };
}

async function recordExternalRentalCharge(req: Request, payload: CheckoutPayload) {
  if (!payload.chargeId) throw new Error("Rental charge id is required.");
  const method = String(payload.paymentMethod || "").trim().toLowerCase();
  if (!["card", "terminal", "cash_app", "cash", "bank_transfer", "other"].includes(method)) {
    throw new Error("Choose how the external payment was received.");
  }
  const reference = String(payload.paymentReference || "").trim().slice(0, 120);
  const admin = await requireAdmin(req, "charge.manage");
  const { data: charge, error: chargeError } = await adminClient!
    .from("rental_charge_items")
    .select("id, rental_id, user_id, name, total_amount, included_in_initial_payment, status, payment_provider, external_payment_method, stripe_checkout_session_id, stripe_payment_intent_id, admin_charge_attempts")
    .eq("id", payload.chargeId)
    .single();
  if (chargeError || !charge) throw new Error(chargeError?.message || "Rental charge not found.");
  if (charge.included_in_initial_payment) throw new Error("This fee was included in the original rental payment.");
  if (charge.status === "waived") throw new Error("A waived charge cannot be recorded as paid.");
  if (charge.status === "paid") {
    return {
      status: "already_settled",
      charge,
      reason: `This charge was already paid through ${charge.external_payment_method || charge.payment_provider || "another method"}.`,
    };
  }

  // Never leave a live Stripe collection path open after cash or another
  // external payment is accepted. A completed/processing Stripe payment wins
  // and must reconcile before an administrator can record external money.
  if (charge.stripe_payment_intent_id?.startsWith("pi_")) {
    const intent = await stripe!.paymentIntents.retrieve(charge.stripe_payment_intent_id);
    if (intent.status === "succeeded") {
      const recorded = await recordAdminSavedCardCharge(charge, intent, admin);
      return { status: "already_settled", charge: recorded, reason: "Stripe already collected this charge." };
    }
    if (["processing", "requires_capture"].includes(intent.status)) {
      throw new Error("A Stripe payment is already processing for this charge. Wait for it to finish before recording external payment.");
    }
    if (intent.status !== "canceled") {
      await stripe!.paymentIntents.cancel(intent.id);
    }
  }
  if (charge.stripe_checkout_session_id?.startsWith("cs_")) {
    const checkout = await stripe!.checkout.sessions.retrieve(charge.stripe_checkout_session_id);
    if (checkout.payment_status === "paid" || checkout.status === "complete") {
      throw new Error("Stripe Checkout already completed for this charge. Wait for payment reconciliation before recording external payment.");
    }
    if (checkout.status === "open") await stripe!.checkout.sessions.expire(checkout.id);
  }

  const { data: recorded, error: recordError } = await adminClient!.rpc(
    "record_admin_external_rental_charge_payment_guarded",
    {
      p_charge_id: charge.id,
      p_payment_method: method,
      p_reference: reference || null,
      p_actor_id: admin.user.id,
      p_expected_status: charge.status,
      p_expected_checkout_session_id: charge.stripe_checkout_session_id || null,
      p_expected_payment_intent_id: charge.stripe_payment_intent_id || null,
      p_expected_admin_charge_attempts: Number(charge.admin_charge_attempts || 0),
    },
  );
  if (recordError) throw recordError;

  await adminClient!.from("admin_audit_logs").insert({
    actor_user_id: admin.user.id,
    actor_email: admin.profile.email || admin.user.email || null,
    actor_role: "admin",
    action: "rental_charge.external_payment_recorded",
    entity_type: "rental_charge",
    entity_id: charge.id,
    metadata: {
      rental_id: charge.rental_id,
      amount: charge.total_amount,
      payment_method: method,
      reference: reference || null,
    },
  });
  return { status: "paid", charge: recorded };
}

async function confirmCheckout(req: Request, payload: CheckoutPayload) {
  const user = await getUser(req);
  if (!user?.id) throw new HttpError("You must be signed in to confirm checkout.", 401);

  const sessionId = String(payload.sessionId || "").trim();
  if (!/^cs_(test|live)_[A-Za-z0-9]+$/.test(sessionId)) {
    throw new HttpError("A valid Stripe Checkout session is required.", 400);
  }

  const session = await stripe!.checkout.sessions.retrieve(sessionId, {
    expand: ["payment_intent.latest_charge"],
  });
  if (session.status !== "complete" || session.payment_status !== "paid") {
    throw new HttpError("Stripe has not confirmed this payment yet. Refresh in a moment.", 409);
  }

  const targetType = String(session.metadata?.target_type || "");
  const targetId = targetType === "extension"
    ? session.metadata?.extension_request_id
    : targetType === "charge"
      ? session.metadata?.charge_id
      : session.metadata?.rental_id;
  const paymentIntentId = typeof session.payment_intent === "string"
    ? session.payment_intent
    : session.payment_intent?.id || "";
  const stripeCustomerId = typeof session.customer === "string"
    ? session.customer
    : session.customer?.id || "";
  const issueBase = {
    dedupeKey: `checkout:${session.id}`,
    issueType: "payment_reconciliation",
    checkoutSessionId: session.id,
    paymentIntentId,
    targetType: (["rental", "extension", "charge"].includes(targetType) ? targetType : "unknown") as "rental" | "extension" | "charge" | "unknown",
    targetId,
    rentalId: targetType === "rental" ? targetId : undefined,
    extensionRequestId: targetType === "extension" ? targetId : undefined,
    amountCents: session.amount_total || 0,
    currency: session.currency || "usd",
    payload: { source: "customer_return_reconciliation" },
  };
  if (!targetId || !["rental", "extension", "charge"].includes(targetType)) {
    await openReconciliationIssue({
      ...issueBase,
      errorMessage: "Paid Stripe Checkout is missing its Rent Me CT booking reference.",
    });
    throw new HttpError("This Stripe payment is missing its Rent Me CT booking reference.", 409);
  }
  if (session.metadata?.user_id && session.metadata.user_id !== user.id) {
    throw new HttpError("This Stripe payment belongs to a different customer account.", 403);
  }

  const paymentIntent = typeof session.payment_intent === "string" ? null : session.payment_intent;
  const latestCharge = paymentIntent && typeof paymentIntent.latest_charge !== "string"
    ? paymentIntent.latest_charge
    : null;
  const paidAtMs = Number(latestCharge?.created || paymentIntent?.created || session.created || 0) * 1000;
  if (targetType === "charge") {
    const { data: charge, error: chargeError } = await adminClient!
      .from("rental_charge_items")
      .select("id, rental_id, user_id, status, stripe_checkout_session_id")
      .eq("id", targetId)
      .single();
    if (chargeError || !charge) {
      await openReconciliationIssue({ ...issueBase, errorMessage: chargeError?.message || "Rental charge not found." });
      throw new HttpError(chargeError?.message || "Rental charge not found.", 404);
    }
    if (charge.user_id !== user.id) throw new HttpError("This charge belongs to a different customer account.", 403);
    if (charge.stripe_checkout_session_id && charge.stripe_checkout_session_id !== session.id) {
      throw new HttpError("Stripe Checkout does not match this rental charge.", 409);
    }
    if (String(charge.status || "").toLowerCase() === "paid") {
      await upsertReconciliationIssue({ ...issueBase, rentalId: charge.rental_id, status: "resolved" });
      return { confirmed: true, alreadyRecorded: true, targetType, targetId };
    }
    await upsertReconciliationIssue({ ...issueBase, status: "processing" });
    const { data, error } = await adminClient!.rpc("record_stripe_rental_charge_payment", {
      p_charge_id: targetId,
      p_checkout_session_id: session.id,
      p_payment_intent_id: paymentIntentId,
      p_amount_total: session.amount_total || 0,
      p_currency: session.currency || "usd",
    });
    if (error) {
      await openReconciliationIssue({ ...issueBase, rentalId: charge.rental_id, errorMessage: error.message });
      throw new HttpError(error.message, 409);
    }
    if (stripeCustomerId) {
      await adminClient!.from("rental_charge_items").update({ stripe_customer_id: stripeCustomerId }).eq("id", targetId);
    }
    await upsertReconciliationIssue({ ...issueBase, rentalId: charge.rental_id, status: "resolved" });
    return { confirmed: true, targetType, targetId, result: data };
  }

  const table = targetType === "extension" ? "rental_extension_requests" : "rentals";
  const targetColumns = targetType === "extension"
    ? "id, rental_id, user_id, status, payment_status, payment_due_at, stripe_checkout_session_id"
    : "id, user_id, status, payment_status, payment_due_at, checkout_expires_at, stripe_checkout_session_id";
  const { data: target, error: targetError } = await adminClient!
    .from(table)
    .select(targetColumns)
    .eq("id", targetId)
    .single();
  if (targetError || !target) {
    await openReconciliationIssue({ ...issueBase, errorMessage: targetError?.message || "Rental payment record not found." });
    throw new HttpError(targetError?.message || "Rental payment record not found.", 404);
  }
  if (target.user_id !== user.id) throw new HttpError("This payment belongs to a different customer account.", 403);
  if (target.stripe_checkout_session_id && target.stripe_checkout_session_id !== session.id) {
    throw new HttpError("Stripe Checkout does not match this rental payment.", 409);
  }
  if (String(target.payment_status || "").toLowerCase() === "paid") {
    await upsertReconciliationIssue({
      ...issueBase,
      rentalId: targetType === "extension" ? target.rental_id : targetId,
      status: "resolved",
    });
    return { confirmed: true, alreadyRecorded: true, targetType, targetId };
  }

  const deadlineValue = target.payment_due_at || target.checkout_expires_at;
  const deadlineMs = deadlineValue ? new Date(deadlineValue).getTime() : 0;
  const closed = targetType === "extension"
    ? ["cancelled", "rejected"].includes(String(target.status || "").toLowerCase())
    : String(target.status || "").toLowerCase() === "cancelled";
  if (closed || (deadlineMs && paidAtMs && paidAtMs > deadlineMs)) {
    await openReconciliationIssue({
      ...issueBase,
      rentalId: targetType === "extension" ? target.rental_id : targetId,
      errorMessage: "Paid checkout completed after the reservation deadline; automatic refund is pending.",
    });
    throw new HttpError(
      "Stripe received the payment after this reservation closed. Rent Me CT is reviewing the automatic refund; please do not pay again.",
      409,
    );
  }

  const resolvedRentalId = targetType === "extension" ? target.rental_id : targetId;
  await upsertReconciliationIssue({ ...issueBase, rentalId: resolvedRentalId, status: "processing" });
  const { data, error } = await adminClient!.rpc("record_stripe_checkout_payment", {
    p_event_id: `checkout-session:${session.id}`,
    p_event_type: "checkout.session.completed.customer_return",
    p_target_type: targetType,
    p_target_id: targetId,
    p_checkout_session_id: session.id,
    p_payment_intent_id: paymentIntentId,
    p_customer_id: stripeCustomerId,
    p_amount_total: session.amount_total || 0,
    p_currency: session.currency || "usd",
    p_payload: {
      source: "customer_return_reconciliation",
      checkout_session_id: session.id,
    },
  });
  if (error) {
    await openReconciliationIssue({ ...issueBase, rentalId: resolvedRentalId, errorMessage: error.message });
    throw new HttpError(error.message, 409);
  }
  if (targetType === "rental") {
    await adminClient!.from("rentals").update({ checkout_expires_at: null }).eq("id", targetId);
  }
  await upsertReconciliationIssue({ ...issueBase, rentalId: resolvedRentalId, status: "resolved" });
  return { confirmed: true, targetType, targetId, result: data };
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
    const admin = await requireAdmin(req, "deposit.resolve");
    const result = await releaseSecurityDeposit(payload.rentalId, "manual", {
      userId: admin.user.id,
      email: admin.profile.email || admin.user.email,
      reason: payload.reason || null,
    });
    return json(result);
  }

  if (payload.action === "refund_rental_payment") {
    return json(await refundRentalPayment(req, payload));
  }

  if (payload.action === "admin_charge_saved_card") {
    return json(await chargeSavedCard(req, payload));
  }

  if (payload.action === "admin_waive_rental_charge") {
    return json(await waiveRentalCharge(req, payload));
  }

  if (payload.action === "admin_record_external_charge") {
    return json(await recordExternalRentalCharge(req, payload));
  }

  if (payload.action === "admin_apply_manual_discount") {
    return json(await applyAdminManualDiscount(req, payload));
  }

  if (payload.action === "admin_apply_rental_amendment") {
    return json(await applyAdminRentalAmendment(req, payload));
  }

  if (payload.action === "admin_record_external_balance") {
    return json(await recordAdminExternalBalance(req, payload));
  }

  if (payload.action === "admin_create_installment_checkout") {
    return json(await createAdminStripeInstallmentCheckout(req, payload));
  }

  if (payload.action === "admin_create_charge_checkout") {
    return json(await createAdminRentalChargeCheckout(req, payload));
  }

  if (payload.action === "admin_create_extension_checkout") {
    return json(await createAdminExtensionCheckout(req, payload));
  }

  if (payload.action === "admin_create_checkout") {
    if (!payload.rentalId) return json({ error: "Rental id is required." }, 400);
    await requireAdmin(req, "payment.collect");
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

  if (payload.action === "confirm_checkout") {
    return json(await confirmCheckout(req, payload));
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
    const identityResult = verificationSession.status === "verified"
      ? await retrieveIdentitySessionForComparison(verificationSession.id)
      : { session: verificationSession, sensitiveResultsAvailable: true };
    if (verificationSession.status === "verified" && !identityResult.sensitiveResultsAvailable) {
      const configurationState = await markIdentityResultsAccessRequired(userId, identityResult.session);
      return json({
        received: true,
        identityStatus: configurationState.status,
        verified: false,
        submissionReceived: true,
        errorCode: configurationState.errorCode,
      });
    }
    const hydratedSession = identityResult.session;
    const identityState = await updateIdentityState(userId, hydratedSession);
    await writeIdentityAudit(`identity_verification.${identityState.status}`, userId, verificationSession.id, identityState.status);
    return json({
      received: true,
      identityStatus: identityState.status,
      verified: identityState.verified,
      nameMatched: identityState.nameMatched,
      dateOfBirthMatched: identityState.dateOfBirthMatched,
      errorCode: identityState.errorCode,
    });
  }

  if (event.type === "charge.dispute.created") {
    const dispute = event.data.object as Stripe.Dispute;
    const charge = typeof dispute.charge === "string"
      ? await stripe.charges.retrieve(dispute.charge)
      : dispute.charge;
    const paymentIntentId = typeof charge?.payment_intent === "string"
      ? charge.payment_intent
      : charge?.payment_intent?.id || "";

    let rentalId = "";
    if (paymentIntentId) {
      const { data: rental } = await adminClient
        .from("rentals")
        .select("id")
        .or(`stripe_payment_intent_id.eq.${paymentIntentId},stripe_deposit_intent_id.eq.${paymentIntentId}`)
        .limit(1)
        .maybeSingle();
      rentalId = rental?.id || "";

      if (!rentalId) {
        const { data: chargeItem } = await adminClient
          .from("rental_charge_items")
          .select("rental_id")
          .eq("stripe_payment_intent_id", paymentIntentId)
          .limit(1)
          .maybeSingle();
        rentalId = chargeItem?.rental_id || "";
      }
    }

    if (!rentalId) {
      return json({ received: true, ignored: "unmatched_chargeback" });
    }

    const dedupeKey = `chargeback_created:${dispute.id}`;
    const { error } = await adminClient
      .from("admin_notification_events")
      .upsert({
        event_type: "chargeback_created",
        source_id: rentalId,
        rental_id: rentalId,
        dedupe_key: dedupeKey,
        metadata: {
          dispute_id: dispute.id,
          payment_intent_id: paymentIntentId,
          amount: Number(dispute.amount || 0) / 100,
          currency: dispute.currency,
          reason: dispute.reason,
          status: dispute.status,
        },
      }, {
        onConflict: "dedupe_key",
        ignoreDuplicates: true,
      });
    if (error) return json({ error: error.message }, 500);
    return json({ received: true, chargebackQueued: true });
  }

  if (["refund.created", "refund.updated", "refund.failed"].includes(event.type)) {
    const refund = event.data.object as Stripe.Refund;
    const rentalId = refund.metadata?.rental_id || "";
    const refundType = refund.metadata?.refund_type || "";
    const paymentIntentId = await paymentIntentForRefund(refund);
    if (rentalId && refund.metadata?.refund_type === "rental_payment") {
      const refundRequestId = refund.metadata?.refund_request_id || "";
      if (!paymentIntentId) {
        await openReconciliationIssue({
          dedupeKey: `refund:${refund.id}`,
          issueType: "refund_reconciliation",
          stripeEventId: event.id,
          refundId: refund.id,
          targetType: "rental",
          targetId: rentalId,
          rentalId,
          amountCents: refund.amount,
          currency: refund.currency,
          errorMessage: "Stripe refund is missing its payment intent.",
        });
        return json({ received: true, reconciliationQueued: true });
      }
      await recordRefundLedger({
        refund,
        rentalId,
        paymentIntentId,
        sourceType: "admin_rental_payment",
        reason: refund.metadata?.reason || "Rental payment refund processed through Stripe.",
        stripeEventId: event.id,
        ledgerId: refundRequestId,
      });
      return json({ received: true, refundStatus: refund.status });
    }

    if (["expired_reservation", "expired_extension"].includes(refundType)) {
      const matched = await matchRefundPaymentIntent(paymentIntentId);
      const matchedRentalId = rentalId || matched?.rentalId || "";
      const extensionRequestId = refund.metadata?.extension_request_id || matched?.extensionRequestId || "";
      if (!matchedRentalId || !paymentIntentId) {
        await openReconciliationIssue({
          dedupeKey: `refund:${refund.id}`,
          issueType: "expired_checkout_refund_reconciliation",
          stripeEventId: event.id,
          checkoutSessionId: refund.metadata?.checkout_session_id || "",
          paymentIntentId,
          refundId: refund.id,
          targetType: refundType === "expired_extension" ? "extension" : "rental",
          targetId: extensionRequestId || rentalId,
          rentalId: matchedRentalId,
          extensionRequestId,
          amountCents: refund.amount,
          currency: refund.currency,
          errorMessage: "Expired-checkout refund could not be matched to a rental ledger.",
        });
        return json({ received: true, reconciliationQueued: true });
      }
      await recordRefundLedger({
        refund,
        rentalId: matchedRentalId,
        paymentIntentId,
        sourceType: refundType,
        reason: refundType === "expired_extension"
          ? "Automatic refund for an extension payment received after its deadline."
          : "Automatic refund for a reservation payment received after its deadline.",
        stripeEventId: event.id,
        extensionRequestId,
      });
      await upsertReconciliationIssue({
        dedupeKey: `checkout:${refund.metadata?.checkout_session_id || refund.id}`,
        issueType: "expired_checkout_refund",
        status: "refunded",
        stripeEventId: event.id,
        checkoutSessionId: refund.metadata?.checkout_session_id || "",
        paymentIntentId,
        refundId: refund.id,
        targetType: refundType === "expired_extension" ? "extension" : "rental",
        targetId: extensionRequestId || matchedRentalId,
        rentalId: matchedRentalId,
        extensionRequestId,
        amountCents: refund.amount,
        currency: refund.currency,
      });
      return json({ received: true, refundStatus: refund.status, ledgerRecorded: true });
    }

    if (rentalId && refundType === "security_deposit") {
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

    // Refunds created manually in Stripe often contain no Rent Me CT metadata.
    // Match them by the immutable PaymentIntent, record them in the normal
    // refund ledger, and require an admin classification review rather than
    // silently changing rental/deposit accounting.
    const matched = await matchRefundPaymentIntent(paymentIntentId);
    if (matched?.rentalId && paymentIntentId) {
      await recordRefundLedger({
        refund,
        rentalId: matched.rentalId,
        paymentIntentId,
        sourceType: "stripe_manual_review",
        reason: "Stripe Dashboard refund; review rental and deposit classification.",
        stripeEventId: event.id,
        extensionRequestId: matched.extensionRequestId,
      });
    }
    await openReconciliationIssue({
      dedupeKey: `refund:${refund.id}`,
      issueType: matched ? "manual_refund_review" : "unmatched_refund",
      stripeEventId: event.id,
      paymentIntentId,
      refundId: refund.id,
      targetType: matched?.targetType || "unknown",
      targetId: matched?.targetId,
      rentalId: matched?.rentalId,
      extensionRequestId: matched?.extensionRequestId,
      amountCents: refund.amount,
      currency: refund.currency,
      errorMessage: matched
        ? "Manual Stripe refund requires rental/deposit classification review."
        : "Stripe refund could not be matched to a Rent Me CT payment.",
      payload: { stripe_refund_status: refund.status, stripe_refund_reason: refund.reason || null },
    });
    return json({ received: true, reconciliationQueued: true, ledgerRecorded: Boolean(matched) });
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
    const { data: savedCardCharge } = await adminClient
      .from("rental_charge_items")
      .select("rental_id")
      .eq("id", chargeId)
      .maybeSingle();
    const savedCardIssueBase = {
      dedupeKey: `payment-intent:${paymentIntent.id}`,
      issueType: "payment_reconciliation",
      stripeEventId: event.id,
      paymentIntentId: paymentIntent.id,
      targetType: "charge" as const,
      targetId: chargeId,
      rentalId: savedCardCharge?.rental_id,
      amountCents: paymentIntent.amount_received || paymentIntent.amount,
      currency: paymentIntent.currency || "usd",
      payload: event as unknown as Record<string, unknown>,
    };
    await upsertReconciliationIssue({ ...savedCardIssueBase, status: "processing" });
    const { data, error } = await adminClient.rpc("record_stripe_rental_charge_payment", {
      p_charge_id: chargeId,
      p_checkout_session_id: `off_session:${paymentIntent.id}`,
      p_payment_intent_id: paymentIntent.id,
      p_amount_total: paymentIntent.amount_received || paymentIntent.amount,
      p_currency: paymentIntent.currency || "usd",
    });
    if (error) {
      await openReconciliationIssue({ ...savedCardIssueBase, errorMessage: error.message });
      return json({ error: error.message, reconciliationQueued: true }, 500);
    }
    await upsertReconciliationIssue({ ...savedCardIssueBase, status: "resolved" });
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
  const checkoutPaymentIntentId = typeof session.payment_intent === "string"
    ? session.payment_intent
    : session.payment_intent?.id || "";
  const webhookIssueBase = {
    dedupeKey: `checkout:${session.id}`,
    issueType: "payment_reconciliation",
    stripeEventId: event.id,
    checkoutSessionId: session.id,
    paymentIntentId: checkoutPaymentIntentId,
    targetType: (["rental", "extension", "charge"].includes(targetType) ? targetType : "unknown") as "rental" | "extension" | "charge" | "unknown",
    targetId,
    rentalId: targetType === "rental" ? targetId : undefined,
    extensionRequestId: targetType === "extension" ? targetId : undefined,
    amountCents: session.amount_total || 0,
    currency: session.currency || "usd",
    payload: event as unknown as Record<string, unknown>,
  };

  if (!targetId || !["rental", "extension", "charge"].includes(targetType)) {
    await openReconciliationIssue({
      ...webhookIssueBase,
      errorMessage: "Paid Stripe Checkout is missing Rent Me CT metadata.",
    });
    return json({ received: true, reconciliationQueued: true });
  }

  await upsertReconciliationIssue({ ...webhookIssueBase, status: "processing" });

  if (targetType === "rental") {
    const { data: deadlineRental, error: deadlineError } = await adminClient
      .from("rentals")
      .select("id, user_id, status, payment_status, checkout_expires_at, payment_due_at, stripe_checkout_session_id")
      .eq("id", targetId)
      .single();
    if (deadlineError || !deadlineRental) {
      await openReconciliationIssue({
        ...webhookIssueBase,
        errorMessage: deadlineError?.message || "Rental not found for paid checkout.",
      });
      return json({ received: true, reconciliationQueued: true });
    }
    if (
      String(deadlineRental.payment_status || "").toLowerCase() === "paid" &&
      deadlineRental.stripe_checkout_session_id === session.id
    ) {
      await upsertReconciliationIssue({ ...webhookIssueBase, status: "resolved" });
      return json({ received: true, alreadyRecorded: true, targetType, targetId });
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

      await recordRefundLedger({
        refund,
        rentalId: targetId,
        paymentIntentId,
        sourceType: "expired_reservation",
        reason: "Automatic refund for a reservation payment received after its deadline.",
        stripeEventId: event.id,
      });

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

      await upsertReconciliationIssue({
        ...webhookIssueBase,
        issueType: "expired_checkout_refund",
        refundId: refund.id,
        status: "refunded",
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
      .select("id, rental_id, user_id, status, payment_status, payment_due_at, stripe_checkout_session_id")
      .eq("id", targetId)
      .single();
    if (deadlineError || !deadlineExtension) {
      await openReconciliationIssue({
        ...webhookIssueBase,
        errorMessage: deadlineError?.message || "Extension request not found for paid checkout.",
      });
      return json({ received: true, reconciliationQueued: true });
    }
    if (
      String(deadlineExtension.payment_status || "").toLowerCase() === "paid" &&
      deadlineExtension.stripe_checkout_session_id === session.id
    ) {
      await upsertReconciliationIssue({
        ...webhookIssueBase,
        rentalId: deadlineExtension.rental_id,
        status: "resolved",
      });
      return json({ received: true, alreadyRecorded: true, targetType, targetId });
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
      await recordRefundLedger({
        refund,
        rentalId: deadlineExtension.rental_id,
        paymentIntentId,
        sourceType: "expired_extension",
        reason: "Automatic refund for an extension payment received after its deadline.",
        stripeEventId: event.id,
        extensionRequestId: targetId,
      });
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
      await upsertReconciliationIssue({
        ...webhookIssueBase,
        issueType: "expired_checkout_refund",
        rentalId: deadlineExtension.rental_id,
        refundId: refund.id,
        status: "refunded",
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
    const { data: chargeRecord } = await adminClient
      .from("rental_charge_items")
      .select("rental_id")
      .eq("id", targetId)
      .maybeSingle();
    const { data, error } = await adminClient.rpc("record_stripe_rental_charge_payment", {
      p_charge_id: targetId,
      p_checkout_session_id: session.id,
      p_payment_intent_id: typeof session.payment_intent === "string" ? session.payment_intent : session.payment_intent?.id || "",
      p_amount_total: session.amount_total || 0,
      p_currency: session.currency || "usd",
    });
    if (error) {
      await openReconciliationIssue({
        ...webhookIssueBase,
        rentalId: chargeRecord?.rental_id,
        errorMessage: error.message,
      });
      return json({ error: error.message, reconciliationQueued: true }, 500);
    }
    if (stripeCustomerId) {
      await adminClient.from("rental_charge_items").update({ stripe_customer_id: stripeCustomerId }).eq("id", targetId);
    }
    await upsertReconciliationIssue({
      ...webhookIssueBase,
      rentalId: chargeRecord?.rental_id,
      status: "resolved",
    });
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

  if (error) {
    const reconciliationRentalId = targetType === "extension"
      ? (await adminClient.from("rental_extension_requests").select("rental_id").eq("id", targetId).maybeSingle()).data?.rental_id
      : targetId;
    await openReconciliationIssue({
      ...webhookIssueBase,
      rentalId: reconciliationRentalId,
      errorMessage: error.message,
    });
    return json({ error: error.message, reconciliationQueued: true }, 500);
  }
  if (targetType === "rental") {
    await adminClient
      .from("rentals")
      .update({ checkout_expires_at: null })
      .eq("id", targetId);
  }
  const resolvedRentalId = targetType === "extension"
    ? (await adminClient.from("rental_extension_requests").select("rental_id").eq("id", targetId).maybeSingle()).data?.rental_id
    : targetId;
  await upsertReconciliationIssue({
    ...webhookIssueBase,
    rentalId: resolvedRentalId,
    status: "resolved",
  });
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
    // Stripe may be configured with either the function base URL or the
    // explicit /webhook route. A valid Stripe signature is the authoritative
    // signal, and prevents a successful charge from being mistaken for an
    // unauthenticated customer API request.
    if (pathname.endsWith("/webhook") || req.headers.has("stripe-signature")) {
      return await handleWebhook(req);
    }
    return await handleApiAction(req);
  } catch (error) {
    console.error("stripe-web-hook error", error);
    return json(
      { error: publicApiErrorMessage(error) },
      error instanceof HttpError ? error.status : 500,
    );
  }
});
