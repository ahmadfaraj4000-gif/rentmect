import {
  adminClient,
  corsHeaders,
  getSavedPhone,
  handleError,
  json,
  PhoneVerificationError,
  requireUser,
  twilioVerifyRequest,
} from "../_shared/phone-verification.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "POST required" }, 405);

  try {
    const user = await requireUser(req);
    const payload = await req.json().catch(() => ({}));
    const code = String(payload.code || "").replace(/\s/g, "");
    if (!/^\d{4,10}$/.test(code)) {
      throw new PhoneVerificationError("Enter the verification code from the text message.", 400);
    }

    const { phone, savedPhone } = await getSavedPhone(user.id, payload.phone);
    const result = await twilioVerifyRequest("VerificationCheck", { To: phone, Code: code });
    if (result.status !== "approved") {
      return json({ status: result.status || "pending", verified: false });
    }

    if (!adminClient) throw new PhoneVerificationError("Phone verification is not configured.", 500);
    const now = new Date().toISOString();
    const { error } = await adminClient
      .from("profiles")
      .update({
        phone_verified: true,
        phone_verified_at: now,
        phone_verification_method: "twilio_verify",
        phone_verification_updated_at: now,
      })
      .eq("id", user.id)
      .eq("phone", savedPhone);
    if (error) throw new PhoneVerificationError("The code was approved, but the profile could not be updated.", 500);

    return json({ status: "approved", verified: true });
  } catch (error) {
    return handleError("check-phone-code error", error);
  }
});
