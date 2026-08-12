import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || Deno.env.get("SERVICE_ROLE_KEY") || "";
const adminPortalUrl = Deno.env.get("RENTMECT_ADMIN_PORTAL_URL") || "https://admin.rentmect.com";
const adminClient = createClient(supabaseUrl, serviceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } });

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}

async function requireStaffManager(req: Request) {
  const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token) throw new Response(JSON.stringify({ error: "Manager sign-in required." }), { status: 401 });
  const { data, error } = await adminClient.auth.getUser(token);
  if (error || !data.user?.id) throw new Response(JSON.stringify({ error: "Manager session expired." }), { status: 401 });
  const { data: profile } = await adminClient.from("profiles").select("id,email,role,staff_role").eq("id", data.user.id).single();
  const allowed = profile?.role === "admin" && (
    profile.staff_role === "owner" || String(profile.email || "").toLowerCase() === "anconamgt@aol.com"
  );
  if (!allowed) throw new Response(JSON.stringify({ error: "Only an authorized manager can invite Employees." }), { status: 403 });
  return { user: data.user, profile };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "POST required." }, 405);
  try {
    const actor = await requireStaffManager(req);
    const payload = await req.json();
    if (payload.action !== "invite_employee") return json({ error: "Unsupported staff action." }, 400);
    const email = String(payload.email || "").trim().toLowerCase();
    const fullName = String(payload.fullName || "").trim();
    if (!/^\S+@\S+\.\S+$/.test(email) || !fullName) return json({ error: "Employee name and a valid email are required." }, 400);

    let userId = "";
    let invited = false;
    const { data: existingProfile } = await adminClient.from("profiles").select("id").ilike("email", email).maybeSingle();
    if (existingProfile?.id) {
      userId = existingProfile.id;
    } else {
      const { data: invite, error: inviteError } = await adminClient.auth.admin.inviteUserByEmail(email, {
        redirectTo: adminPortalUrl,
        data: { full_name: fullName, staff_role: "employee" },
      });
      if (inviteError || !invite.user?.id) throw new Error(inviteError?.message || "Employee invite could not be created.");
      userId = invite.user.id;
      invited = true;
    }

    const { error: profileError } = await adminClient.from("profiles").upsert({
      id: userId,
      email,
      full_name: fullName,
      role: "admin",
      staff_role: "employee",
    }, { onConflict: "id" });
    if (profileError) throw profileError;

    await adminClient.from("admin_audit_logs").insert({
      actor_user_id: actor.user.id,
      actor_email: actor.profile.email,
      actor_role: actor.profile.staff_role,
      action: invited ? "employee.invited" : "employee.access_updated",
      entity_type: "staff_profile",
      entity_id: userId,
      metadata: { employee_email: email, employee_name: fullName, staff_role: "employee" },
    });
    return json({ ok: true, invited, userId, email, staffRole: "employee" });
  } catch (error) {
    if (error instanceof Response) return new Response(error.body, { status: error.status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    return json({ error: error instanceof Error ? error.message : "Staff invite failed." }, 400);
  }
});
