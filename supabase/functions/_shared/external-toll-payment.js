// Provider calls only retire collection paths. No new charge/refund is created.
// A timeout leaves the database reservation in place for resume or cancellation.
export async function closeTollCollectionPaths(stripe, charges) {
  for (const charge of charges) {
    if (charge.admin_charge_attempted_at && !charge.stripe_payment_intent_id) {
      throw new Error('A saved-card attempt is unresolved. Reconcile it before recording this payment.');
    }
    const intentIds = new Set(charge.stripe_payment_intent_id ? [charge.stripe_payment_intent_id] : []);
    if (charge.stripe_checkout_session_id) {
      let session = await stripe.checkout.sessions.retrieve(charge.stripe_checkout_session_id);
      if (session.payment_status === 'paid' || session.status === 'complete') {
        throw new Error('Stripe Checkout already completed for a selected toll. Cancel this recording and reconcile that payment.');
      }
      if (session.status === 'open') session = await stripe.checkout.sessions.expire(session.id);
      if (session.status !== 'expired') throw new Error('A toll payment link could not be closed. Resume this recording to retry.');
      const intentId = typeof session.payment_intent === 'string' ? session.payment_intent : session.payment_intent?.id;
      if (intentId) intentIds.add(intentId);
    }
    for (const id of intentIds) {
      let intent = await stripe.paymentIntents.retrieve(id);
      if (['succeeded', 'processing', 'requires_capture'].includes(intent.status)) {
        throw new Error('Stripe has collected or is processing a selected toll. Cancel this recording and reconcile that payment.');
      }
      if (intent.status !== 'canceled') intent = await stripe.paymentIntents.cancel(id);
      if (intent.status !== 'canceled') throw new Error('A toll card attempt could not be cancelled. Resume this recording to retry.');
    }
  }
}
