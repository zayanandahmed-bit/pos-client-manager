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

create table if not exists crm_employees (
  id text primary key,
  name text not null,
  phone text default '',
  role text default '', -- e.g. Sales, Support
  status text default 'active', -- active | inactive
  join_date date,
  notes text default ''
);

create table if not exists crm_clients (
  id text primary key,
  store_name text not null,
  owner_name text default '',
  phone text default '',
  address text default '',
  monthly_fee numeric default 0,
  status text default 'active', -- active | paused | cancelled
  start_date date,
  notes text default '',
  employee_id text default '', -- which employee signed this client
  web_app_url text default '', -- this client's deployed POS app link
  web_app_password text default '' -- this client's POS app-open password
);

-- Columns added after the table already existed for some setups — safe to
-- re-run, these are no-ops if the columns are already there.
alter table crm_clients add column if not exists employee_id text default '';
alter table crm_clients add column if not exists web_app_url text default '';
alter table crm_clients add column if not exists web_app_password text default '';

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
create index if not exists idx_crm_clients_employee_id on crm_clients(employee_id);

alter table crm_employees enable row level security;
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
      'startDate', start_date, 'notes', notes, 'employeeId', employee_id,
      'webAppUrl', web_app_url, 'webAppPassword', web_app_password
    )) from crm_clients), '[]'::jsonb),

    'payments', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'clientId', client_id, 'period', period, 'amount', amount,
      'paidDate', paid_date, 'method', method, 'notes', notes
    )) from crm_payments), '[]'::jsonb),

    'employees', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'name', name, 'phone', phone, 'role', role, 'status', status,
      'joinDate', join_date, 'notes', notes
    )) from crm_employees), '[]'::jsonb)
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
  insert into crm_clients (id, store_name, owner_name, phone, address, monthly_fee, status, start_date, notes, employee_id, web_app_url, web_app_password)
  select x->>'id', x->>'storeName', coalesce(x->>'ownerName',''), coalesce(x->>'phone',''),
         coalesce(x->>'address',''), coalesce((x->>'monthlyFee')::numeric,0), coalesce(x->>'status','active'),
         nullif(x->>'startDate','')::date, coalesce(x->>'notes',''), coalesce(x->>'employeeId',''),
         coalesce(x->>'webAppUrl',''), coalesce(x->>'webAppPassword','')
  from jsonb_array_elements(clients) x;
end;
$$;

-- ============== sync_replace_crm_employees: instant full replace ==============

create or replace function sync_replace_crm_employees(employees jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from crm_employees where true;
  insert into crm_employees (id, name, phone, role, status, join_date, notes)
  select x->>'id', x->>'name', coalesce(x->>'phone',''), coalesce(x->>'role',''),
         coalesce(x->>'status','active'), nullif(x->>'joinDate','')::date, coalesce(x->>'notes','')
  from jsonb_array_elements(employees) x;
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
grant execute on function sync_replace_crm_employees(jsonb) to anon;

-- ============== APP LOGIN (real username + password) ==============
-- Replaces the old hardcoded-in-JavaScript password with a real
-- server-side check: the actual password is never present in the app's
-- source code anymore, only a one-way bcrypt hash sits in the database,
-- and the app just asks Postgres "does this match?" and gets true/false
-- back. This is shared by BOTH apps (POS and Client Manager) since they
-- live in the same Supabase project — each app passes its own app_name
-- ('pos-hafiz-dairy' or 'client-manager') so their credentials are
-- independent even though the mechanism is identical.
--
-- Honest limits: this gates the app's UI, not the data functions below —
-- someone who already has your anon key can still call sync_pull_crm()
-- etc. directly (same as before). What's genuinely new is that reading
-- the page's source no longer reveals the password, and you can change
-- it any time from Settings without needing to touch code or re-run SQL.

-- Supabase installs pgcrypto into the "extensions" schema by default, not
-- "public" — every call below is schema-qualified (extensions.crypt(...))
-- instead of relying on search_path, so this works regardless of which
-- schema it lands in.
create extension if not exists pgcrypto with schema extensions;

create table if not exists app_logins (
  app_name text not null,
  username text not null,
  password_hash text not null,
  primary key (app_name, username)
);
alter table app_logins enable row level security;

create or replace function verify_app_login(p_app text, p_username text, p_password text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
begin
  select password_hash into v_hash from app_logins where app_name = p_app and username = p_username;
  if v_hash is null then
    return false;
  end if;
  return v_hash = extensions.crypt(p_password, v_hash);
end;
$$;

-- Lets a logged-in user change their own app's username/password from
-- Settings. Requires the CURRENT password to succeed — you can't change
-- credentials without already knowing the existing ones.
create or replace function set_app_login(p_app text, p_username text, p_current_password text, p_new_username text, p_new_password text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not verify_app_login(p_app, p_username, p_current_password) then
    return false;
  end if;
  delete from app_logins where app_name = p_app and username = p_username;
  insert into app_logins (app_name, username, password_hash)
  values (p_app, p_new_username, extensions.crypt(p_new_password, extensions.gen_salt('bf')));
  return true;
end;
$$;

grant execute on function verify_app_login(text, text, text) to anon;
grant execute on function set_app_login(text, text, text, text, text) to anon;

-- Seed the initial login — CHANGE THIS from the app's Settings panel right
-- after setup, since these starting credentials are visible in this file.
-- Checks for ANY existing login on that app_name (not just this exact
-- username), so re-running this file after you've changed the username
-- never silently re-adds the old default alongside your real one.
insert into app_logins (app_name, username, password_hash)
select 'pos-hafiz-dairy', 'admin', extensions.crypt('changeme123', extensions.gen_salt('bf'))
where not exists (select 1 from app_logins where app_name = 'pos-hafiz-dairy');

insert into app_logins (app_name, username, password_hash)
select 'client-manager', 'admin', extensions.crypt('changeme123', extensions.gen_salt('bf'))
where not exists (select 1 from app_logins where app_name = 'client-manager');
