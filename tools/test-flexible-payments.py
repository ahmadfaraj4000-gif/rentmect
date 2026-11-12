#!/usr/bin/env python3
"""Local disposable PostgreSQL; no real customers, network, or provider calls."""
from pathlib import Path
import subprocess,tempfile,socket,re,json,uuid,concurrent.futures
ROOT=Path(__file__).resolve().parents[1]
BIN=Path(subprocess.check_output(['pg_config','--bindir'],text=True).strip())
def function(file,name):
 s=(ROOT/file).read_text()
 match=re.search(r'create or replace function public\.'+name+r'\s*\(',s,re.I)
 assert match,name
 rest=s[match.start():]; tag=re.search(r'\bas\s+(\$[a-z_]*\$)',rest,re.I).group(1)
 end=rest.index(tag,rest.index(tag)+len(tag))+len(tag)
 return rest[:end]+';'
with tempfile.TemporaryDirectory(prefix='rentme-unified-') as tmp:
 path=Path(tmp)
 with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
 subprocess.run([str(BIN/'initdb'),'-D',tmp+'/data','-A','trust','--no-locale'],check=True,stdout=subprocess.DEVNULL)
 subprocess.run([str(BIN/'pg_ctl'),'-D',tmp+'/data','-l',tmp+'/log','-o',f'-k {tmp} -p {port} -h 127.0.0.1','start'],check=True,stdout=subprocess.DEVNULL)
 base=[str(BIN/'psql'),'-X','-qAt','-h',tmp,'-p',str(port),'-d','postgres','-v','ON_ERROR_STOP=1']
 def sql(s,fail=False):
  result=subprocess.run(base,input=s,text=True,capture_output=True)
  if not fail and result.returncode:raise AssertionError(result.stderr)
  if fail:assert result.returncode,result.stdout
  return result.stdout.strip() if not fail else result.stderr
 def load(file):sql((ROOT/file).read_text())
 try:
  load('supabase/tests/fixtures/external_toll_payments.sql');load('supabase/tests/fixtures/unified_external_payments.sql')
  load('supabase/migrations/20261105160000_external_toll_payment_batches.sql')
  sources=[('20260916190000_cancel_before_pickup_deposit_refund.sql',['rentmect_rental_invoice_total']),
   ('20260813213000_admin_partial_payment_installments.sql',['sync_rental_remaining_balance','record_admin_rental_balance_payment']),
   ('20261014235000_classified_deposit_refunds.sql',['rentmect_rental_net_paid_amount']),
   ('20260917210000_deposit_refund_integrity.sql',['sync_deposit_released_total','ensure_rental_deposit_allocation','admin_adjust_external_rental_payment'])]
  for file,names in sources:
   for name in names:sql(function('supabase/migrations/'+file,name))
  # Apply the actual incremental deposit-closeout synchronizer changes.
  closeout=(ROOT/'supabase/migrations/20261013160000_deposit_rental_balance_closeout.sql').read_text()
  block=closeout[closeout.index(' -- Synchronizing'):closeout.index('end $$;')]
  sql('do $$ declare definition text; marker text; begin '+block+' end $$;')
  sql(function('supabase/migrations/20260811120000_partial_rental_balance_settlement.sql','sync_balance_after_charge_payment'))
  sql('create trigger rental_balance_payment_sync after update of status on rental_charge_items for each row execute function sync_balance_after_charge_payment();')
  load('supabase/migrations/20261106220000_unified_external_payments.sql')
  load('supabase/migrations/20261111190000_flexible_payment_allocations.sql')
  actor=str(uuid.uuid4());customer=str(uuid.uuid4());rid=str(uuid.uuid4());toll=str(uuid.uuid4());fee=str(uuid.uuid4())
  claims=f"set request.jwt.claim.role='service_role';set request.jwt.claim.sub='{actor}';"
  sql(f"insert into auth.users values('{actor}'),('{customer}');insert into profiles(id,role,staff_role) values('{actor}','admin','owner');insert into rentals(id,user_id) values('{rid}','{customer}');insert into rental_charge_items(id,rental_id,user_id,name,charge_type,amount,total_amount,status) values('{toll}','{rid}','{customer}','Bridge toll','toll',26,26,'pending'),('{fee}','{rid}','{customer}','Insurance','add_on',50,50,'pending');")
  def prep(key,request):return f"select service_prepare_external_payment('{key}','{rid}','{actor}','{json.dumps(request)}');"
  def finish(key,cancel=False):return f"select service_finish_external_payment('{key}','{actor}',{'true' if cancel else 'false'});"
  def request(amount=30000,rent=10000,charges=None,funding='external',due=18900):
   charges=charges if charges is not None else [{'id':toll,'amountCents':1000,'expectedRemainingCents':2600},{'id':fee,'amountCents':2000,'expectedRemainingCents':5000}]
   return {'kind':'rental_payment','version':2,'funding':funding,'amountCents':amount,'rentalAmountCents':rent,'charges':charges,'creditAmountCents':amount-rent-sum(c['amountCents'] for c in charges),'expectedRentalDueCents':due,'paymentMethod':'cash','receivedDate':'2026-01-31','receivedTime':'','reference':'Fixture','notes':'Synthetic'}
  key=str(uuid.uuid4()); req=request()
  # Invalid requests fail atomically; no money or reserved credit survives.
  for bad in [{**req,'amountCents':29999}, {**req,'creditAmountCents':-1}, request(rent=19000), request(charges=[{'id':toll,'amountCents':2700,'expectedRemainingCents':2600}]), request(charges=[{'id':toll,'amountCents':1000,'expectedRemainingCents':2500}])]:
   sql(claims+prep(str(uuid.uuid4()),bad),True)
  sql(claims+prep(key,req))
  assert sql(f"select count(*) from external_payment_receipts")=='1'
  assert sql(f"select rental_available_credit_cents('{rid}')")=='0'
  sql(claims+f"update rentals set rental_total=500 where id='{rid}'",True)
  # Failure after charge/rental writes rolls back the entire posting transaction.
  sql("create function synthetic_post_failure() returns trigger language plpgsql as $$ begin if new.status='posted' then raise exception 'Synthetic mid-post failure'; end if; return new; end $$;create trigger synthetic_post_failure before update on external_payment_receipts for each row execute function synthetic_post_failure();")
  assert 'Synthetic mid-post failure' in sql(claims+finish(key),True)
  assert sql(f"select status from external_payment_receipts where id='{key}'")=='pending'
  assert sql(f"select allocated_payment_cents from rental_charge_items where id='{toll}'")=='0'
  assert sql(f"select count(*) from external_payment_allocations where receipt_id='{key}'")=='2'
  assert sql(f"select rental_available_credit_cents('{rid}')")=='0'
  sql('drop trigger synthetic_post_failure on external_payment_receipts;drop function synthetic_post_failure();')
  # Two finishing workers post exactly one receipt.
  with concurrent.futures.ThreadPoolExecutor(2) as pool:
   results=list(pool.map(lambda _:json.loads(sql(claims+finish(key))),range(2)))
  assert all(r['creditAmountCents']==17000 and r['balanceDue']==89 for r in results),results
  assert sql(f"select rental_available_credit_cents('{rid}')")=='17000'
  assert sql(f"select total_amount from rental_charge_items where id='{toll}'")=='26'
  assert sql(f"select rentmect_charge_remaining_amount(c) from rental_charge_items c where id='{toll}'")=='16.0000000000000000'
  assert sql(f"select status from rental_charge_items where id='{toll}'")=='pending'
  assert sql(f"select sum(amount_cents) from external_payment_allocations where receipt_id='{key}'")=='13000'
  # Stale balances and legacy writers cannot overwrite partial accounting.
  sql(claims+f"update rental_charge_items set status='paid' where id='{toll}'",True)
  sql(claims+f"update rental_charge_items set total_amount=1 where id='{toll}'",True)
  sql(claims+prep(str(uuid.uuid4()),req),True)
  # Apply $105 of existing funds: rental $89 + toll $16, no new cash received.
  credit=str(uuid.uuid4()); credit_req=request(amount=10500,rent=8900,charges=[{'id':toll,'amountCents':1600,'expectedRemainingCents':1600}],funding='credit',due=8900)
  sql(claims+prep(credit,credit_req))
  assert sql(f"select rental_available_credit_cents('{rid}')")=='6500'
  # Reservation is released when explicitly cancelled.
  sql(claims+finish(credit,True)); assert sql(f"select rental_available_credit_cents('{rid}')")=='17000'
  credit=str(uuid.uuid4()); sql(claims+prep(credit,credit_req)+finish(credit))
  assert sql(f"select rental_available_credit_cents('{rid}')")=='6500'
  assert sql(f"select status from rental_charge_items where id='{toll}'")=='paid'
  assert sql(f"select payment_status from rentals where id='{rid}'")=='paid'
  assert sql("select sum(amount_cents) from external_payment_receipts where status='posted' and funding_kind<>'credit'")=='30000'
  assert sql(f"select sum(amount_cents) from external_payment_allocations where receipt_id='{credit}'")=='10500'
  # An original receipt cannot be refunded while its credit is spent.
  staff=f"set request.jwt.claim.role='authenticated';set request.jwt.claim.sub='{actor}';"
  failure=sql(staff+f"select admin_refund_external_payment('{key}','Returned externally','r');",True)
  assert 'credit in use' in failure,failure
  # Waive only the unpaid insurance remainder, retain $20 received.
  sql(claims+f"update rental_charge_items set status='waived' where id='{fee}'")
  assert sql(f"select allocated_payment_cents||':'||allocated_waiver_cents from rental_charge_items where id='{fee}'")=='2000:3000'
  assert sql(f"select rentmect_charge_remaining_amount(c) from rental_charge_items c where id='{fee}'")=='0'
  # Reverse a credit application, then refund the external receipt. Audit survives.
  sql(staff+f"select admin_refund_external_payment('{credit}','Reverse credit application','r');")
  assert sql(f"select rental_available_credit_cents('{rid}')")=='17000'
  sql(staff+f"select admin_refund_external_payment('{key}','Returned externally','r');")
  sql(staff+f"select admin_refund_external_payment('{key}','Returned externally','r');")
  assert sql(f"select rental_available_credit_cents('{rid}')")=='0'
  assert sql(f"select total_amount from rental_charge_items where id='{toll}'")=='26'
  assert sql(f"select allocated_payment_cents from rental_charge_items where id='{fee}'")=='0'
  # Credit-only receipt on a settled invoice is accepted; no deposit changes.
  k=str(uuid.uuid4());sql(claims+prep(k,request(amount=7000,rent=0,charges=[]))+finish(k))
  assert sql(f"select rental_available_credit_cents('{rid}')")=='7000'
  assert sql(f"select deposit_held_amount from rentals where id='{rid}'")=='0'
  # Credit spending is serialized per rental, including two independently valid drafts.
  q=request(amount=5000,rent=5000,charges=[],funding='credit',due=18900)
  def attempt(_):
   k=str(uuid.uuid4())
   result=subprocess.run(base,input=claims+prep(k,q)+finish(k),text=True,capture_output=True)
   return result.returncode
  with concurrent.futures.ThreadPoolExecutor(2) as pool: outcomes=list(pool.map(attempt,range(2)))
  assert outcomes.count(0)==1,outcomes
  assert sql(f"select rental_available_credit_cents('{rid}')")=='2000'
  # Cancelling a rejected/lost prepare can never permit that delayed key to post.
  abandoned=str(uuid.uuid4())
  sql(claims+f"select service_cancel_flexible_payment('{abandoned}','{rid}','{actor}');")
  assert 'cancelled' in sql(claims+prep(abandoned,request(amount=1000,rent=0,charges=[])),True)
  print('Flexible payments: overpayments, explicit partial allocations, credit, waivers, refunds, concurrency and original amounts passed.')
 finally:
  subprocess.run([str(BIN/'pg_ctl'),'-D',tmp+'/data','stop','-m','immediate'],stdout=subprocess.DEVNULL)
