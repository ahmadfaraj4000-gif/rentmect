import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

export async function requireMerchant(client: SupabaseClient, req: Request, slug = "carcraft") {
  const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  const { data, error } = await client.auth.getUser(token);
  if (error || !data.user?.id) throw new Error("Sign in to your merchant account again.");
  const { data: merchantId, error: membershipError } = await client.rpc("rentmect_merchant_for_actor", {
    p_actor: data.user.id, p_slug: slug,
  });
  if (membershipError || !merchantId) throw new Error("An active merchant invitation and verified email sign-in are required.");
  return { userId: data.user.id, merchantId };
}

export async function requireMerchantRental(client: SupabaseClient, req: Request, rentalId: string) {
  // Derive organization from the saved rental, never a browser-supplied tenant ID.
  const { data: rental, error } = await client.from("rentals")
    .select("id,user_id,merchant_id,status,payment_status,agreement_signed,merchants(slug,bookings_enabled)").eq("id", rentalId).single();
  if (error || !rental?.merchant_id) throw new Error("Merchant booking not found.");
  const organization = Array.isArray(rental.merchants) ? rental.merchants[0] : rental.merchants;
  const actor = await requireMerchant(client, req, organization?.slug);
  if (actor.merchantId !== rental.merchant_id) throw new Error("Merchant booking not found.");
  if (!organization?.bookings_enabled) throw new Error("Merchant payments are paused. Contact Rent Me CT.");
  const { data: verified, error: verificationError } = await client.rpc("rentmect_merchant_identity_valid", { p_rental_id: rental.id });
  if (verificationError || verified !== true) throw new Error("This booking requires Rent Me CT identity review before payment.");
  if (rental.agreement_signed !== true) throw new Error("The customer must sign the rental agreement before payment.");
  return rental;
}
