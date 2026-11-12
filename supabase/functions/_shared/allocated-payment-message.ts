// Only a server-owned, pending collection can supply a direct payment link to messages.
export async function allocatedPaymentMessage(client: any, receiptId: string, rentalId: string, customerId: string) {
  if (!receiptId) return null;
  const {data: rental, error: rentalError} = await client.from('rentals').select('user_id').eq('id',rentalId).single();
  if (rentalError || rental?.user_id !== customerId) throw new Error('The payment does not belong to this customer and rental.');
  const {data: receipt, error} = await client.from('external_payment_receipts').select('amount_cents,result,created_at')
    .eq('id',receiptId).eq('rental_id',rentalId).eq('funding_kind','stripe').eq('status','pending').single();
  if (error || !receipt) throw new Error('This Stripe payment is no longer awaiting payment. Refresh before sending.');
  const url = String(receipt.result?.url || '');
  const parsed = new URL(url);
  if (parsed.protocol !== 'https:' || parsed.hostname !== 'checkout.stripe.com') throw new Error('Create the secure Stripe link before sending it.');
  if (Date.now() - new Date(receipt.created_at).getTime() >= 24 * 60 * 60 * 1000) throw new Error('Check the Stripe payment status and renew an expired link before sending.');
  const amount = new Intl.NumberFormat('en-US',{style:'currency',currency:'USD'}).format(receipt.amount_cents / 100);
  return {url, amount, text:`Rent Me CT: A payment of ${amount} has been requested for your rental. Pay securely through Stripe: ${url}. Your payment will be applied to the rental, charges, and customer credit as arranged with our team.`};
}
