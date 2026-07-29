-- POS Client Manager — Supabase schema addition.
--
-- This runs in the SAME Supabase project as your POS app (hafiz-dairy-pos) —
-- sharing one project is what keeps your infra cost flat regardless of how
-- many client stores or how many of YOUR OWN clients you track. These are
-- brand-new tables/functions; nothing here touches the POS app's tables.
--
-- One-time setup:
-- 1. Go to your Supabase project -> SQL Editor -> New query.
-- 2. Paste this ENTIRE file in and click "Run".
-- 3. In Settings -> API, copy the Project URL and anon public key (same
--    ones your POS app uses) into this app's Settings panel.
--
-- Design: same model as the POS app — RLS enabled with zero direct table
-- access, everything goes through SECURITY DEFINER functions below. Your
-- client list and payment history are only ever a few thousand rows at
-- most, so (unlike the POS sales table) there's no need for range-scoped
-- fetching or pagination here — a simple full read/replace per save is
-- plenty fast forever at this scale.

-- ============== TABLES ==============

create table if not exists crm_clients (
  id text primary key,
  store_name text not null,
  owner_name text default '',
  phone text default '',
  address text default '',
  monthly_fee numeric default 0,
  status text default 'active', -- active | paused | cancelled
  start_date date,
  notes text default ''
);

create table if not exists crm_payments (
  id text primary key,
  client_id text not null,
  period text not null, -- e.g. '2026-07' (the month this payment covers)
  amount numeric default 0,
  paid_date date,
  method text default '', -- Cash | Bank Transfer | JazzCash | EasyPaisa | Other
  notes text default ''
);

create index if not exists idx_crm_payments_client_id on crm_payments(client_id);
create index if not exists idx_crm_payments_period on crm_payments(period);

alter table crm_clients enable row level security;
alter table crm_payments enable row level security;

-- ============== sync_pull_crm: read everything back ==============

create or replace function sync_pull_crm()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result jsonb;
begin
  select jsonb_build_object(
    'clients', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'storeName', store_name, 'ownerName', owner_name, 'phone', phone,
      'address', address, 'monthlyFee', monthly_fee, 'status', status,
      'startDate', start_date, 'notes', notes
    )) from crm_clients), '[]'::jsonb),

    'payments', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'clientId', client_id, 'period', period, 'amount', amount,
      'paidDate', paid_date, 'method', method, 'notes', notes
    )) from crm_payments), '[]'::jsonb)
  ) into result;
  return result;
end;
$$;

-- ============== sync_replace_crm_clients: instant full replace ==============

create or replace function sync_replace_crm_clients(clients jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from crm_clients where true;
  insert into crm_clients (id, store_name, owner_name, phone, address, monthly_fee, status, start_date, notes)
  select x->>'id', x->>'storeName', coalesce(x->>'ownerName',''), coalesce(x->>'phone',''),
         coalesce(x->>'address',''), coalesce((x->>'monthlyFee')::numeric,0), coalesce(x->>'status','active'),
         nullif(x->>'startDate','')::date, coalesce(x->>'notes','')
  from jsonb_array_elements(clients) x;
end;
$$;

-- ============== sync_replace_crm_payments: instant full replace ==============

create or replace function sync_replace_crm_payments(payments jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from crm_payments where true;
  insert into crm_payments (id, client_id, period, amount, paid_date, method, notes)
  select x->>'id', x->>'clientId', x->>'period', coalesce((x->>'amount')::numeric,0),
         nullif(x->>'paidDate','')::date, coalesce(x->>'method',''), coalesce(x->>'notes','')
  from jsonb_array_elements(payments) x;
end;
$$;

-- ============== grant access ONLY to the functions above ==============

grant execute on function sync_pull_crm() to anon;
grant execute on function sync_replace_crm_clients(jsonb) to anon;
grant execute on function sync_replace_crm_payments(jsonb) to anon;
