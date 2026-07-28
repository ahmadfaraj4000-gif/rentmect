import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey, x-rentmect-email-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || Deno.env.get("SERVICE_ROLE_KEY") || "";
const sendGridApiKey = Deno.env.get("SENDGRID_API_KEY") || "";
const fromEmail = Deno.env.get("SENDGRID_FROM_EMAIL") || "bookings@rentmect.com";
const fromName = Deno.env.get("SENDGRID_FROM_NAME") || "Rent Me CT";
const replyToEmail = Deno.env.get("SENDGRID_REPLY_TO_EMAIL") || fromEmail;
const workerSecret = Deno.env.get("RENTMECT_EMAIL_WORKER_SECRET") || "";
const webhookSecret = Deno.env.get("SENDGRID_EVENT_WEBHOOK_SECRET") || "";
const clientPortalUrl = Deno.env.get("RENTMECT_CLIENT_PORTAL_URL") || "https://login.rentmect.com";
const businessPhone = Deno.env.get("RENTMECT_PHONE") || "860-558-6031";
const marketingGroupId = Number(Deno.env.get("SENDGRID_MARKETING_UNSUBSCRIBE_GROUP_ID") || 0);
const adminClient = supabaseUrl && serviceRoleKey
  ? createClient(supabaseUrl, serviceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } })
  : null;

type Json = Record<string, unknown>;
type Recipient = { user_id?: string | null; email: string; full_name?: string | null };

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function assertConfigured() {
  if (!adminClient || !sendGridApiKey) throw new Error("SendGrid email delivery is not configured.");
}

function escapeHtml(value: unknown) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function sanitizeTemplateHtml(value: unknown) {
  return String(value || "")
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, "")
    .replace(/\son\w+\s*=\s*(["']).*?\1/gi, "")
    .replace(/javascript:/gi, "");
}

function render(value: unknown, variables: Json) {
  return String(value || "").replace(/{{\s*([a-zA-Z0-9_]+)\s*}}/g, (_match, key) => escapeHtml(variables[key]));
}

function emailShell(content: string, preheader = "", marketing = false) {
  const unsubscribe = marketing
    ? '<p style="margin:20px 0 0;font-size:12px;color:#6b7280"><a href="<%asm_group_unsubscribe_url%>" style="color:#374151">Unsubscribe from promotional emails</a></p>'
    : "";
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Rent Me CT</title></head><body style="margin:0;background:#f3f4f6;font-family:Arial,sans-serif;color:#171717"><div style="display:none;max-height:0;overflow:hidden">${escapeHtml(preheader)}</div><table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#f3f4f6;padding:24px 12px"><tr><td align="center"><table role="presentation" width="620" cellspacing="0" cellpadding="0" style="max-width:620px;width:100%;background:#fff;border:1px solid #ddd"><tr><td style="padding:22px 28px;background:#050505;color:#fff;font-size:22px;font-weight:800">RENT ME CT</td></tr><tr><td style="padding:30px 28px;line-height:1.6">${content}<hr style="border:0;border-top:1px solid #e5e7eb;margin:28px 0 18px"><p style="margin:0;font-size:12px;color:#6b7280">Rent Me CT · 12 Holmes Circle, Farmington, CT</p>${unsubscribe}</td></tr></table></td></tr></table></body></html>`;
}

async function requireAdmin(req: Request) {
  assertConfigured();
  const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token) throw new Response(JSON.stringify({ error: "Admin sign-in required." }), { status: 401 });
  const { data, error } = await adminClient!.auth.getUser(token);
  if (error || !data.user?.id) throw new Response(JSON.stringify({ error: "Admin session expired." }), { status: 401 });
  const { data: profile } = await adminClient!.from("profiles").select("role").eq("id", data.user.id).single();
  if (String(profile?.role || "").toLowerCase() !== "admin") {
    throw new Response(JSON.stringify({ error: "Admin access required." }), { status: 403 });
  }
  return data.user;
}

function requireWorker(req: Request) {
  assertConfigured();
  if (!workerSecret || req.headers.get("x-rentmect-email-secret") !== workerSecret) {
    throw new Response(JSON.stringify({ error: "Worker authorization failed." }), { status: 401 });
  }
}

async function sendMail(params: {
  to: string;
  toName?: string | null;
  subject: string;
  html: string;
  text?: string;
  marketing?: boolean;
  customArgs?: Record<string, string>;
}) {
  const payload: Json = {
    personalizations: [{
      to: [{ email: params.to, name: params.toName || undefined }],
      custom_args: params.customArgs || {},
    }],
    from: { email: fromEmail, name: fromName },
    reply_to: { email: replyToEmail, name: fromName },
    subject: params.subject,
    content: [
      { type: "text/plain", value: params.text || params.subject },
      { type: "text/html", value: params.html },
    ],
    categories: [params.marketing ? "rentmect_marketing" : "rentmect_transactional"],
  };
  if (params.marketing && marketingGroupId > 0) payload.asm = { group_id: marketingGroupId };

  const response = await fetch("https://api.sendgrid.com/v3/mail/send", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${sendGridApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  if (!response.ok) {
    const detail = await response.text();
    throw new Error(`SendGrid rejected the email (${response.status}): ${detail.slice(0, 600)}`);
  }
  return response.headers.get("x-message-id") || "";
}

async function processOutbox(limit = 25) {
  const { data: jobs, error } = await adminClient!
    .from("email_outbox")
    .select("*, email_templates(*)")
    .in("status", ["pending", "failed"])
    .lte("next_attempt_at", new Date().toISOString())
    .lt("attempts", 5)
    .order("created_at", { ascending: true })
    .limit(limit);
  if (error) throw error;

  const results = [];
  for (const job of jobs || []) {
    const template = Array.isArray(job.email_templates) ? job.email_templates[0] : job.email_templates;
    if (!template?.enabled) {
      await adminClient!.from("email_outbox").update({ status: "cancelled", last_error: "Template disabled." }).eq("id", job.id);
      continue;
    }
    await adminClient!.from("email_outbox").update({ status: "processing", attempts: Number(job.attempts || 0) + 1 }).eq("id", job.id);
    try {
      const variables = job.payload || {};
      const subject = render(template.subject, variables);
      const html = emailShell(render(sanitizeTemplateHtml(template.html_body), variables), render(template.preheader, variables));
      const text = render(template.text_body || template.subject, variables);
      const messageId = await sendMail({
        to: job.recipient_email,
        toName: job.recipient_name,
        subject,
        html,
        text,
        customArgs: { outbox_id: job.id, rental_id: job.rental_id || "", email_type: job.email_type },
      });
      await adminClient!.from("email_outbox").update({ status: "sent", sent_at: new Date().toISOString(), provider_message_id: messageId, last_error: null }).eq("id", job.id);
      results.push({ id: job.id, status: "sent" });
    } catch (error) {
      const attempts = Number(job.attempts || 0) + 1;
      const retryMinutes = Math.min(60, 2 ** attempts);
      await adminClient!.from("email_outbox").update({
        status: "failed",
        last_error: error instanceof Error ? error.message : "Email send failed.",
        next_attempt_at: new Date(Date.now() + retryMinutes * 60_000).toISOString(),
      }).eq("id", job.id);
      results.push({ id: job.id, status: "failed" });
    }
  }
  return results;
}

async function campaignAudience(campaign: Json): Promise<Recipient[]> {
  const { data: profiles, error } = await adminClient!
    .from("profiles")
    .select("id,email,full_name,email_marketing_opt_in,email_marketing_unsubscribed_at")
    .eq("email_marketing_opt_in", true)
    .is("email_marketing_unsubscribed_at", null)
    .not("email", "is", null);
  if (error) throw error;
  let recipients = (profiles || []).map((profile) => ({ user_id: profile.id, email: String(profile.email).trim().toLowerCase(), full_name: profile.full_name }));
  const audienceType = String(campaign.audience_type || "marketing_opted_in");
  const selectedIds = new Set((campaign.selected_user_ids as string[] || []).map(String));
  if (audienceType === "selected") return recipients.filter((recipient) => recipient.user_id && selectedIds.has(recipient.user_id));
  if (audienceType === "marketing_opted_in") return recipients;

  const { data: rentals, error: rentalsError } = await adminClient!
    .from("rentals")
    .select("user_id,status,pickup_date,payment_status");
  if (rentalsError) throw rentalsError;
  const today = new Date().toISOString().slice(0, 10);
  const ids = new Set((rentals || []).filter((rental) => {
    const status = String(rental.status || "").toLowerCase();
    if (audienceType === "active_rentals") return ["ready_for_pickup", "approved", "active", "overdue", "return_initiated"].includes(status);
    if (audienceType === "upcoming_pickups") return rental.pickup_date >= today && String(rental.payment_status || "").toLowerCase() === "paid" && !["completed", "cancelled"].includes(status);
    if (audienceType === "past_customers") return status === "completed";
    return false;
  }).map((rental) => rental.user_id));
  return recipients.filter((recipient) => recipient.user_id && ids.has(recipient.user_id));
}

async function processCampaign(campaignId: string, batchSize = 60) {
  const { data: campaign, error } = await adminClient!.from("email_campaigns").select("*").eq("id", campaignId).single();
  if (error || !campaign) throw new Error(error?.message || "Campaign not found.");
  if (["completed", "cancelled"].includes(campaign.status)) return { campaignId, status: campaign.status };

  const { count } = await adminClient!.from("email_campaign_recipients").select("id", { count: "exact", head: true }).eq("campaign_id", campaignId);
  if (!count) {
    const recipients = await campaignAudience(campaign);
    if (!recipients.length) {
      await adminClient!.from("email_campaigns").update({ status: "failed", last_error: "No eligible opted-in recipients matched this audience." }).eq("id", campaignId);
      return { campaignId, status: "failed", recipients: 0 };
    }
    const { error: recipientError } = await adminClient!.from("email_campaign_recipients").insert(recipients.map((recipient) => ({
      campaign_id: campaignId,
      user_id: recipient.user_id,
      email: recipient.email,
      customer_name: recipient.full_name,
    })));
    if (recipientError) throw recipientError;
    await adminClient!.from("email_campaigns").update({ recipient_count: recipients.length, status: "sending", last_error: null }).eq("id", campaignId);
  } else {
    await adminClient!.from("email_campaigns").update({ status: "sending" }).eq("id", campaignId);
  }

  const { data: pending, error: pendingError } = await adminClient!
    .from("email_campaign_recipients")
    .select("*")
    .eq("campaign_id", campaignId)
    .eq("status", "pending")
    .limit(batchSize);
  if (pendingError) throw pendingError;

  for (const recipient of pending || []) {
    const variables = {
      customer_name: recipient.customer_name || "Customer",
      customer_first_name: String(recipient.customer_name || "Customer").split(/\s+/)[0],
      business_address: "12 Holmes Circle, Farmington, CT",
    };
    try {
      const messageId = await sendMail({
        to: recipient.email,
        toName: recipient.customer_name,
        subject: render(campaign.subject, variables),
        html: emailShell(render(sanitizeTemplateHtml(campaign.html_body), variables), render(campaign.preheader, variables), true),
        text: render(campaign.text_body || campaign.subject, variables),
        marketing: true,
        customArgs: { campaign_id: campaignId, recipient_id: recipient.id },
      });
      await adminClient!.from("email_campaign_recipients").update({ status: "processed", processed_at: new Date().toISOString(), provider_message_id: messageId, error: null }).eq("id", recipient.id);
    } catch (error) {
      await adminClient!.from("email_campaign_recipients").update({ status: "failed", error: error instanceof Error ? error.message : "Send failed." }).eq("id", recipient.id);
    }
  }

  const { data: totals } = await adminClient!.from("email_campaign_recipients").select("status").eq("campaign_id", campaignId);
  const sentCount = (totals || []).filter((item) => ["processed", "delivered"].includes(item.status)).length;
  const failedCount = (totals || []).filter((item) => ["failed", "bounced", "spam"].includes(item.status)).length;
  const pendingCount = (totals || []).filter((item) => item.status === "pending").length;
  await adminClient!.from("email_campaigns").update({
    status: pendingCount ? "sending" : "completed",
    sent_count: sentCount,
    failed_count: failedCount,
    sent_at: pendingCount ? null : new Date().toISOString(),
  }).eq("id", campaignId);
  return { campaignId, status: pendingCount ? "sending" : "completed", sentCount, failedCount, pendingCount };
}

async function processDueCampaigns() {
  const now = new Date().toISOString();
  const [sendingResult, scheduledResult] = await Promise.all([
    adminClient!
      .from("email_campaigns")
      .select("id")
      .eq("status", "sending")
      .limit(10),
    adminClient!
    .from("email_campaigns")
    .select("id")
      .eq("status", "scheduled")
      .lte("scheduled_for", now)
      .limit(10),
  ]);
  if (sendingResult.error) throw sendingResult.error;
  if (scheduledResult.error) throw scheduledResult.error;
  const data = [...(sendingResult.data || []), ...(scheduledResult.data || [])]
    .filter((campaign, index, items) => items.findIndex((item) => item.id === campaign.id) === index)
    .slice(0, 10);
  const results = [];
  for (const campaign of data) results.push(await processCampaign(campaign.id));
  return results;
}

async function handleCampaign(req: Request) {
  const user = await requireAdmin(req);
  const payload = await req.json();
  const scheduledFor = payload.scheduledFor ? new Date(payload.scheduledFor) : null;
  if (!payload.name || !payload.subject || !payload.htmlBody) return json({ error: "Campaign name, subject, and email body are required." }, 400);
  if (payload.audienceType === "selected" && !payload.selectedUserIds?.length) return json({ error: "Select at least one opted-in customer." }, 400);
  const status = scheduledFor && scheduledFor.getTime() > Date.now() ? "scheduled" : "sending";
  const { data: campaign, error } = await adminClient!.from("email_campaigns").insert({
    name: String(payload.name).trim(),
    template_id: payload.templateId || null,
    subject: String(payload.subject).trim(),
    preheader: String(payload.preheader || "").trim(),
    html_body: sanitizeTemplateHtml(payload.htmlBody),
    text_body: String(payload.textBody || "").trim(),
    audience_type: payload.audienceType || "marketing_opted_in",
    selected_user_ids: payload.selectedUserIds || [],
    scheduled_for: scheduledFor?.toISOString() || null,
    status,
    created_by: user.id,
  }).select("*").single();
  if (error) return json({ error: error.message }, 400);
  if (status === "scheduled") return json({ campaign, queued: true });
  return json({ campaign, result: await processCampaign(campaign.id) });
}

async function handleTest(req: Request) {
  await requireAdmin(req);
  const payload = await req.json();
  const to = String(payload.to || "").trim().toLowerCase();
  if (!/^\S+@\S+\.\S+$/.test(to)) return json({ error: "Enter a valid test email address." }, 400);
  const variables = { customer_name: "Test Customer", customer_first_name: "Test", booking_number: "TEST123456", vehicle_name: "Rent Me CT Test Vehicle", pickup_date: "Jul 25, 2026", pickup_time: "9:00 AM", return_date: "Jul 27, 2026", return_time: "9:00 AM", rental_total: "$200.00", tax_amount: "$12.70", deposit_amount: "$300.00", manage_booking_url: "https://login.rentmect.com", business_address: "12 Holmes Circle, Farmington, CT" };
  const messageId = await sendMail({
    to,
    subject: `[TEST] ${render(payload.subject, variables)}`,
    html: emailShell(render(sanitizeTemplateHtml(payload.htmlBody), variables), render(payload.preheader, variables)),
    text: render(payload.textBody || payload.subject, variables),
    customArgs: { email_type: "admin_test" },
  });
  return json({ sent: true, messageId });
}

function dateLabel(value: unknown) {
  const raw = String(value || "");
  if (!raw) return "your scheduled date";
  const date = new Date(`${raw}T12:00:00Z`);
  return Number.isNaN(date.getTime()) ? raw : new Intl.DateTimeFormat("en-US", {
    timeZone: "UTC", month: "short", day: "numeric", year: "numeric",
  }).format(date);
}

async function handleCustomerEmail(req: Request) {
  const admin = await requireAdmin(req);
  const payload = await req.json();
  const customerId = String(payload.customerId || "").trim();
  const templateId = String(payload.emailTemplateId || "").trim();
  const rentalId = String(payload.rentalId || "").trim();
  const chargeId = String(payload.chargeId || "").trim();
  if (!customerId || !templateId) return json({ error: "Customer and email template are required." }, 400);

  const [{ data: profile, error: profileError }, { data: template, error: templateError }] = await Promise.all([
    adminClient!.from("profiles").select("id,email,full_name").eq("id", customerId).single(),
    adminClient!.from("email_templates").select("*").eq("id", templateId).eq("category", "manual").eq("enabled", true).single(),
  ]);
  if (profileError || !profile) return json({ error: profileError?.message || "Customer not found." }, 404);
  if (templateError || !template) return json({ error: templateError?.message || "Email template is unavailable." }, 404);
  const recipient = String(profile.email || "").trim().toLowerCase();
  if (!/^\S+@\S+\.\S+$/.test(recipient)) return json({ error: "This customer does not have a valid email address." }, 400);

  let rental: Record<string, unknown> | null = null;
  if (rentalId) {
    const rentalResult = await adminClient!.from("rentals").select("id,user_id,pickup_date,pickup_time,return_date,return_time,vehicles(name)").eq("id", rentalId).eq("user_id", customerId).single();
    if (rentalResult.error) return json({ error: "The selected rental does not belong to this customer." }, 400);
    rental = rentalResult.data;
  }
  let charge: Record<string, unknown> | null = null;
  if (chargeId) {
    const chargeResult = await adminClient!.from("rental_charge_items").select("id,rental_id,user_id,name,description,total_amount,status").eq("id", chargeId).eq("user_id", customerId).single();
    if (chargeResult.error || (rentalId && chargeResult.data?.rental_id !== rentalId)) return json({ error: "The selected charge does not belong to this customer and rental." }, 400);
    charge = chargeResult.data;
  }
  const vehicleRelation = rental?.vehicles;
  const vehicle = Array.isArray(vehicleRelation) ? vehicleRelation[0] : vehicleRelation as Record<string, unknown> | null;
  const variables: Json = {
    customer_name: profile.full_name || "Customer",
    customer_first_name: String(profile.full_name || "Customer").trim().split(/\s+/)[0],
    vehicle_name: vehicle?.name || "your rental vehicle",
    pickup_date: dateLabel(rental?.pickup_date),
    pickup_time: rental?.pickup_time || "your scheduled time",
    return_date: dateLabel(rental?.return_date),
    return_time: rental?.return_time || "your scheduled time",
    manage_booking_url: charge ? `${clientPortalUrl}?billing=1` : clientPortalUrl,
    business_phone: businessPhone,
    business_address: "12 Holmes Circle, Farmington, CT",
    charge_name: charge?.name || "additional rental charge",
    charge_description: charge?.description || "Please contact Rent Me CT with any questions.",
    charge_total: charge?.total_amount == null ? "$0.00" : new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(Number(charge.total_amount)),
  };
  const subject = render(template.subject, variables);
  const renderedBody = render(template.text_body || template.subject, variables);
  try {
    const messageId = await sendMail({
      to: recipient,
      toName: profile.full_name,
      subject,
      html: emailShell(render(sanitizeTemplateHtml(template.html_body), variables), render(template.preheader, variables)),
      text: renderedBody,
      customArgs: { email_type: "admin_customer_manual", customer_id: customerId, rental_id: rentalId, charge_id: chargeId },
    });
    await adminClient!.from("admin_customer_messages").insert({
      user_id: customerId, rental_id: rentalId || null, channel: "email", email_template_id: templateId,
      recipient, subject, rendered_body: renderedBody, status: "sent", provider_message_id: messageId,
      created_by: admin.id, sent_at: new Date().toISOString(),
    });
    await adminClient!.rpc("record_admin_audit_event", { p_action: "customer.email.sent", p_entity_type: "profile", p_entity_id: customerId, p_metadata: { template_id: templateId, rental_id: rentalId || null } });
    return json({ sent: true, messageId });
  } catch (error) {
    const detail = error instanceof Error ? error.message : "Email send failed.";
    await adminClient!.from("admin_customer_messages").insert({
      user_id: customerId, rental_id: rentalId || null, channel: "email", email_template_id: templateId,
      recipient, subject, rendered_body: renderedBody, status: "failed", last_error: detail, created_by: admin.id,
    });
    throw error;
  }
}

async function handleWebhook(req: Request) {
  const url = new URL(req.url);
  if (!webhookSecret || url.searchParams.get("token") !== webhookSecret) return json({ error: "Webhook authorization failed." }, 401);
  const events = await req.json();
  if (!Array.isArray(events)) return json({ error: "Expected an event array." }, 400);
  for (const event of events) {
    const eventType = String(event.event || "unknown");
    const campaignId = event.campaign_id || null;
    const outboxId = event.outbox_id || null;
    const providerMessageId = event.sg_message_id || null;
    const providerEventId = event.sg_event_id || null;
    await adminClient!.from("email_delivery_events").upsert({
      provider_event_id: providerEventId,
      provider_message_id: providerMessageId,
      email: event.email || null,
      event_type: eventType,
      event_at: event.timestamp ? new Date(Number(event.timestamp) * 1000).toISOString() : new Date().toISOString(),
      campaign_id: campaignId,
      outbox_id: outboxId,
      payload: event,
    }, { onConflict: "provider_event_id", ignoreDuplicates: true });
    if (event.recipient_id) {
      const statusMap: Record<string, string> = { delivered: "delivered", deferred: "deferred", bounce: "bounced", dropped: "failed", spamreport: "spam", unsubscribe: "unsubscribed", group_unsubscribe: "unsubscribed" };
      if (statusMap[eventType]) await adminClient!.from("email_campaign_recipients").update({ status: statusMap[eventType], delivered_at: eventType === "delivered" ? new Date().toISOString() : undefined }).eq("id", event.recipient_id);
    }
    if (["unsubscribe", "group_unsubscribe", "spamreport"].includes(eventType) && event.email) {
      await adminClient!.from("profiles").update({ email_marketing_opt_in: false, email_marketing_unsubscribed_at: new Date().toISOString() }).ilike("email", event.email);
    }
  }
  return json({ received: events.length });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "POST required." }, 405);
  try {
    const pathname = new URL(req.url).pathname;
    if (pathname.endsWith("/webhook")) {
      assertConfigured();
      return await handleWebhook(req);
    }
    if (pathname.endsWith("/test")) return await handleTest(req);
    if (pathname.endsWith("/customer")) return await handleCustomerEmail(req);
    if (pathname.endsWith("/campaign")) return await handleCampaign(req);
    if (pathname.endsWith("/process")) {
      requireWorker(req);
      return json({ outbox: await processOutbox(), campaigns: await processDueCampaigns() });
    }
    return json({ error: "Unknown email action." }, 404);
  } catch (error) {
    if (error instanceof Response) return new Response(error.body, { status: error.status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    console.error("send-emails error", error);
    return json({ error: error instanceof Error ? error.message : "Email action failed." }, 500);
  }
});
