// Stable business errors survive PostgREST, Edge Functions and UI boundaries.
export function adminError(error, operation = 'Complete this action') {
  const source = error && typeof error === 'object' ? error : { message: String(error || '') };
  const message = String(typeof source.error === 'string' ? source.error : source.message || '').trim();
  const code = String(source.code || '');
  const match = `${code} ${message}`;
  const requestId = /^[a-zA-Z0-9-]{8,64}$/.test(source.requestId || '') ? source.requestId : null;
  const result = (code, message, field = null) => ({ code, message: code === 'UNEXPECTED_ERROR' && requestId ? `${message} Reference: ${requestId}.` : message, field, ...(requestId ? {requestId} : {}) });
  if (/rentals_one_active_per_customer|customer already has an (?:active|open) rental|already have an active rental/i.test(match))
    return result('CUSTOMER_RENTAL_OPEN','This customer already has an open rental. Open the existing rental to review it. Complete its physical return and inspection before starting another rental, or use an extension or vehicle swap.','customerId');
  if (/customer already has a rental scheduled|customer.*(?:overlap|conflicting reservation)/i.test(match))
    return result('CUSTOMER_DATES_OVERLAP','This customer already has a reservation during these dates and times. Open the existing reservation and edit it, or choose dates that do not overlap.','customerId');
  if (/not.*(?:marked|physically).*returned|awaiting.*return|unreturned|physical return.*required|hard.locked/i.test(match))
    return result('VEHICLE_NOT_RETURNED',message || 'This vehicle has not completed its physical return and inspection. Review its current rental.','vehicleId');
  if (/maintenance/i.test(match) && /block|overdue|unavailable|override|due/i.test(match)) return result('MAINTENANCE_BLOCK',message,'vehicleId');
  if (/vehicle schedule conflict|overlapping rental|vehicle.*(?:unavailable|already reserved)|calendar block|exclusion constraint/i.test(match))
    return result('VEHICLE_DATES_CONFLICT',/constraint/i.test(message) ? 'This vehicle has a conflicting reservation or calendar block. Review its calendar and select another vehicle or time.' : message,'vehicleId');
  if (/partially paid.*reconciliation/i.test(match)) return result('PAYMENT_RECONCILIATION_REQUIRED','This reservation has a partial payment. Review and reconcile that payment before cancelling the reservation.');
  if (/already processing|already.*captured|payment.*reconciliation|checkout.*already open|check saved result/i.test(match)) return result('PAYMENT_REVIEW_REQUIRED',message);
  if (/permission denied|row.level security|\brls\b|42501/.test(match.toLowerCase())) return result('PERMISSION_DENIED','Your staff account does not have permission for this action. Ask an administrator to review your access.');
  if (/jwt|invalid.*token|session.*(?:invalid|expired)|not authenticated/i.test(match)) return result('SESSION_EXPIRED','Your sign-in session has expired. Sign in again, then retry this action.');
  if (/schema cache|relation .* does not exist|function .* does not exist|PGRST202/i.test(match)) return result('DEPLOYMENT_MISMATCH',`${operation} is unavailable because a required database update is missing. Contact support; retrying the form will not fix this.`);
  if (/duplicate key|23505/i.test(match)) return result('DUPLICATE_RECORD','A record with these identifying details already exists. Review the existing record before creating another.');
  if (/violates.*(?:check|foreign key|not-null)|22P02|23502|23503|23514/i.test(match)) return result('INVALID_RECORD',`${operation} could not be completed because a required value is missing, invalid, or refers to a record that changed. Review the form and refresh the affected record.`);
  if (/timed out|timeout|took too long|failed to fetch|network|load failed|connection/i.test(match)) return result('CONNECTION_INTERRUPTED',/check saved result|may already be saved/i.test(message) ? message : `${operation} could not be confirmed because the connection was interrupted. If you were saving or collecting money, check the saved result before submitting again.`);
  // Domain validation messages are useful; SQL internals, provider payloads and
  // generic SDK wrappers are not safe or useful explanations for staff.
  if (message && !/^(?:error|unknown error|\[object Object\]|internal server error|something went wrong\.?|could not create the booking\.?)$/i.test(message)
      && !/non-2xx|SQLSTATE|CONTEXT:|SQL statement|\bSELECT\b.*\bFROM\b|stack trace|secret|service_role|sk_live_|Bearer /i.test(message)) return result(code || 'ACTION_BLOCKED',message.slice(0,1600));
  return result('UNEXPECTED_ERROR',`${operation} could not be completed. The server did not provide a usable explanation. Check the saved result before retrying and contact support if this continues.`);
}
export function adminErrorMessage(error, operation) { return adminError(error, operation).message; }

export function installFunctionErrors(client) {
  const invoke = client.functions.invoke.bind(client.functions);
  client.functions.invoke = async (...args) => {
    const result = await invoke(...args);
    if (!result.error) return result;
    let payload;
    try { payload = await result.error.context?.clone?.().json(); } catch { /* Transport message remains available. */ }
    const detail = adminError(payload || result.error, `The ${args[0].replaceAll('-', ' ')} request`);
    const error = Object.assign(new Error(detail.message), detail, { context: result.error.context });
    return {...result,error};
  };
  return client;
}
