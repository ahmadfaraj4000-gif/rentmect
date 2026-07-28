import {
  corsHeaders,
  getSavedPhone,
  handleError,
  json,
  requireUser,
  twilioVerifyRequest,
} from "../_shared/phone-verification.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "POST required" }, 405);

  try {
    const user = await requireUser(req);
    const payload = await req.json().catch(() => ({}));
    const { phone } = await getSavedPhone(user.id, payload.phone);

    const result = await twilioVerifyRequest("Verifications", {
      To: phone,
      Channel: "sms",
    });

    return json({ sent: true, status: result.status || "pending" });
  } catch (error) {
    return handleError("send-phone-code error", error);
  }
});
