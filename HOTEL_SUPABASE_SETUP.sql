-- Run this script in Supabase Dashboard > SQL Editor.
-- Create staff accounts in Authentication > Users; public staff sign-up is not enabled.

create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  room_number text not null unique,
  room_type text not null,
  nightly_rate numeric(12, 2) not null check (nightly_rate >= 0),
  status text not null default 'Available'
    check (status in ('Available', 'Occupied')),
  housekeeping_status text not null default 'Pending'
    check (housekeeping_status in ('Cleaned', 'Pending')),
  assigned_staff text,
  last_cleaned_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.reservations (
  id uuid primary key default gen_random_uuid(),
  booking_code text not null unique default
    ('RES-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))),
  guest_name text not null,
  room_id uuid not null references public.rooms(id) on delete restrict,
  check_in date not null,
  check_out date not null,
  total_amount numeric(12, 2) not null check (total_amount >= 0),
  status text not null default 'confirmed'
    check (status in ('pending', 'confirmed', 'checked_in', 'checked_out', 'cancelled')),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint reservations_valid_stay check (check_out > check_in)
);

create table if not exists public.workers (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  job_title text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null unique
    references public.reservations(id) on delete restrict,
  amount numeric(12, 2) not null check (amount > 0),
  payment_method text not null default 'dummy'
    check (payment_method = 'dummy'),
  status text not null default 'simulated_paid'
    check (status = 'simulated_paid'),
  reference text not null unique default
    ('DUMMY-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))),
  created_by uuid not null references auth.users(id) on delete restrict,
  paid_at timestamptz not null default now()
);

create index if not exists reservations_room_dates_idx
  on public.reservations (room_id, check_in, check_out);

alter table public.rooms enable row level security;
alter table public.reservations enable row level security;
alter table public.workers enable row level security;
alter table public.payments enable row level security;

drop policy if exists "Authenticated staff can manage rooms" on public.rooms;
create policy "Authenticated staff can manage rooms"
  on public.rooms
  for all
  to authenticated
  using (true)
  with check (true);

drop policy if exists "Authenticated staff can view reservations" on public.reservations;
create policy "Authenticated staff can view reservations"
  on public.reservations
  for select
  to authenticated
  using (true);

drop policy if exists "Authenticated staff can create reservations" on public.reservations;
create policy "Authenticated staff can create reservations"
  on public.reservations
  for insert
  to authenticated
  with check (created_by = (select auth.uid()));

drop policy if exists "Authenticated staff can update reservations" on public.reservations;
create policy "Authenticated staff can update reservations"
  on public.reservations
  for update
  to authenticated
  using (true)
  with check (true);

drop policy if exists "Authenticated staff can delete reservations" on public.reservations;
create policy "Authenticated staff can delete reservations"
  on public.reservations
  for delete
  to authenticated
  using (true);

drop policy if exists "Authenticated staff can manage workers" on public.workers;
create policy "Authenticated staff can manage workers"
  on public.workers
  for all
  to authenticated
  using (true)
  with check (true);

drop policy if exists "Authenticated staff can view payments" on public.payments;
create policy "Authenticated staff can view payments"
  on public.payments
  for select
  to authenticated
  using (true);

drop policy if exists "Authenticated staff can record dummy payments" on public.payments;
create policy "Authenticated staff can record dummy payments"
  on public.payments
  for insert
  to authenticated
  with check (created_by = (select auth.uid()));

grant select, insert, update, delete on public.rooms to authenticated;
grant select, insert, update, delete on public.reservations to authenticated;
grant select, insert, update, delete on public.workers to authenticated;
revoke all on public.payments from anon;
revoke update, delete on public.payments from authenticated;
grant select, insert on public.payments to authenticated;
revoke all on public.rooms, public.reservations, public.workers from anon;

-- Populate the original demonstration roster only when no workers exist.
insert into public.workers (full_name, job_title)
select seed.full_name, seed.job_title
from (values
  ('Alice Namaganda', 'Project Manager / Lead Researcher'),
  ('Brian Ochieng', 'Frontend Developer'),
  ('Cynthia Atuhaire', 'Backend Developer'),
  ('David Kintu', 'Database Administrator'),
  ('Esther Nakabugo', 'UI/UX Designer'),
  ('Felix Okello', 'Systems Analyst'),
  ('Gloria Mutesi', 'QA Tester'),
  ('Henry Ssenyondo', 'Network Specialist'),
  ('Irene Kansiime', 'Documentation Lead')
) as seed(full_name, job_title)
where not exists (select 1 from public.workers);

-- Dummy payments must match the full reservation amount and cannot pay cancelled bookings.
create or replace function public.validate_dummy_payment()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  reservation_amount numeric(12, 2);
  reservation_status text;
begin
  select total_amount, status
    into reservation_amount, reservation_status
  from public.reservations
  where id = new.reservation_id;

  if not found then
    raise exception 'Reservation not found.';
  end if;

  if reservation_status = 'cancelled' then
    raise exception 'Cancelled reservations cannot be paid.';
  end if;

  if new.amount <> reservation_amount then
    raise exception 'Dummy payment must equal the full reservation amount.';
  end if;

  return new;
end;
$$;

drop trigger if exists payments_validate_dummy on public.payments;
create trigger payments_validate_dummy
  before insert on public.payments
  for each row
  execute function public.validate_dummy_payment();

-- Serialize bookings for the same room and prevent overlapping active stays.
create or replace function public.prevent_room_booking_overlap()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.status in ('pending', 'confirmed', 'checked_in') then
    perform 1 from public.rooms where id = new.room_id for update;

    if exists (
      select 1
      from public.reservations existing
      where existing.room_id = new.room_id
        and existing.status in ('pending', 'confirmed', 'checked_in')
        and existing.check_in < new.check_out
        and existing.check_out > new.check_in
        and existing.id is distinct from new.id
    ) then
      raise exception 'This room already has an active reservation for those dates.'
        using errcode = '23P01';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists reservations_prevent_room_overlap on public.reservations;
create trigger reservations_prevent_room_overlap
  before insert or update of room_id, check_in, check_out, status
  on public.reservations
  for each row
  execute function public.prevent_room_booking_overlap();

insert into public.rooms (
  room_number, room_type, nightly_rate, status, housekeeping_status, assigned_staff, last_cleaned_at
)
values
  ('101', 'Twin Executive', 150000, 'Available', 'Cleaned', 'Grace Akello', now()),
  ('102', 'Deluxe Queen', 180000, 'Available', 'Cleaned', 'Moses Mugisha', now()),
  ('103', 'Standard Double', 130000, 'Available', 'Pending', 'Sarah Namubiru', null),
  ('104', 'Executive Suite', 250000, 'Available', 'Cleaned', 'Grace Akello', now())
on conflict (room_number) do nothing;
