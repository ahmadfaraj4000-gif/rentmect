import { createClient } from "npm:@supabase/supabase-js@2";

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const twilioAccountSid = Deno.env.get("TWILIO_ACCOUNT_SID") || "";
const twilioAuthToken = Deno.env.get("TWILIO_AUTH_TOKEN") || "";
const twilioVerifyServiceSid = Deno.env.get("TWILIO_VERIFY_SERVICE_SID") ||
  Deno.env.get("TWILIO_VERIFY_SID") ||
  "";

export const adminClient = supabaseUrl && serviceRoleKey
  ? createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  })
  : null;

export function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

export function normalizeUSPhone(value: unknown) {
  const digits = String(value || "").replace(/\D/g, "");
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith("1")) return `+${digits}`;
  return "";
}

export async function requireUser(req: Request) {
  if (!adminClient) throw new PhoneVerificationError("Phone verification is not configured.", 500);

  const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token) throw new PhoneVerificationError("Sign in again before verifying your phone.", 401);

  const { data, error } = await adminClient.auth.getUser(token);
  if (error || !data.user?.id) {
    throw new PhoneVerificationError("Your session expired. Sign in again and retry.", 401);
  }
  return data.user;
}

export function requireTwilioVerify() {
  if (!/^AC[a-zA-Z0-9]{32}$/.test(twilioAccountSid)) {
    throw new PhoneVerificationError("Phone verification is unavailable because the Twilio Account SID is missing or invalid.", 503);
  }
  if (twilioAuthToken.length !== 32) {
    throw new PhoneVerificationError("Phone verification is unavailable because the Twilio auth token is missing or invalid.", 503);
  }
  if (!/^VA[a-zA-Z0-9]{32}$/.test(twilioVerifyServiceSid)) {
    throw new PhoneVerificationError("Phone verification is unavailable because the Twilio Verify Service SID is missing or invalid.", 503);
  }
  return { twilioAccountSid, twilioAuthToken, twilioVerifyServiceSid };
}

export async function twilioVerifyRequest(path: string, values: Record<string, string>) {
  const config = requireTwilioVerify();
  const response = await fetch(
    `https://verify.twilio.com/v2/Services/${config.twilioVerifyServiceSid}/${path}`,
    {
      method: "POST",
      headers: {
        Authorization: `Basic ${btoa(`${config.twilioAccountSid}:${config.twilioAuthToken}`)}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: new URLSearchParams(values),
    },
  );
  const result = await response.json().catch(() => ({})) as Record<string, unknown>;
  if (!response.ok) {
    const invalidCode = path === "VerificationCheck" && response.status === 404;
    const twilioCode = Number(result.code || 0);
    const configurationError = twilioCode === 20003 || twilioCode === 20404;
    throw new PhoneVerificationError(
      invalidCode
        ? "That code is invalid or expired. Request a new code and try again."
        : configurationError
          ? "Phone verification is temporarily unavailable because Twilio is not configured correctly."
          : String(result.message || "Twilio could not complete phone verification."),
      invalidCode ? 400 : configurationError ? 503 : response.status,
    );
  }
  return result;
}

export async function getSavedPhone(userId: string, requestedPhone: unknown) {
  if (!adminClient) throw new PhoneVerificationError("Phone verification is not configured.", 500);

  const phone = normalizeUSPhone(requestedPhone);
  if (!phone) throw new PhoneVerificationError("Enter a valid 10-digit US phone number.", 400);

  const { data: profile, error } = await adminClient
    .from("profiles")
    .select("phone")
    .eq("id", userId)
    .single();
  if (error || !profile) throw new PhoneVerificationError("Save your renter details before verifying your phone.", 400);
  if (normalizeUSPhone(profile.phone) !== phone) {
    throw new PhoneVerificationError("The phone number changed. Save it and request a new code.", 409);
  }
  return { phone, savedPhone: profile.phone as string };
}

export class PhoneVerificationError extends Error {
  status: number;

  constructor(message: string, status = 400) {
    super(message);
    this.status = status;
  }
}

export function handleError(label: string, error: unknown) {
  console.error(label, error);
  if (error instanceof PhoneVerificationError) return json({ error: error.message }, error.status);
  return json({ error: "Phone verification could not be completed. Please try again." }, 500);
}
