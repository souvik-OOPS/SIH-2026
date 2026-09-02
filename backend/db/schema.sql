-- Personal Health Companion — PostgreSQL schema (Supabase)
--
-- Apply it once, either way:
--   psql "$DATABASE_URL" -f db/schema.sql
--   or paste into the Supabase dashboard → SQL Editor → Run
--
-- The backend also applies this automatically on boot (store.js), so a fresh
-- database works without running anything by hand. Every statement is
-- idempotent, so re-running is safe.

create table if not exists devices (
  device_id              text primary key,
  wearer_name            text not null default 'Unknown wearer',
  profile                text not null default 'general'
                           check (profile in ('general', 'elderly', 'outdoor_worker', 'chronic_condition')),
  emergency_contact      text,
  emergency_contact_name text,
  lat                    double precision,
  lon                    double precision,
  last_seen              timestamptz,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);

-- Age and sex arrived after the first deployments, so they are added rather
-- than folded into the create above: an existing database must survive boot.
-- Both stay nullable. Age tightens the heart-rate ceiling when present and
-- changes nothing when absent, so an unknown wearer is never worse off.
alter table devices add column if not exists age smallint;
alter table devices add column if not exists sex text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'devices_age_range') then
    alter table devices add constraint devices_age_range
      check (age is null or (age between 1 and 120));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'devices_sex_values') then
    alter table devices add constraint devices_sex_values
      check (sex is null or sex in ('male', 'female', 'other'));
  end if;
end $$;

-- One row per sensor sample. Every vital is nullable: the ESP32 sends whatever
-- its attached sensors produced, and a flaky MAX30102 must not cost us the
-- temperature reading.
create table if not exists readings (
  id              bigserial primary key,
  device_id       text not null references devices (device_id) on delete cascade,
  heart_rate      real,
  spo2            real,
  body_temp       real,
  ambient_temp    real,
  humidity        real,
  accel_magnitude real,
  fall_detected   boolean not null default false,
  motion          text    not null default 'unknown',
  signal_ok       boolean not null default true,
  heat_index      real,
  "timestamp"     timestamptz not null
);

-- Every history query is "latest N for one device", so this index is the one
-- that matters. Without it Postgres sorts the whole table each time.
create index if not exists readings_device_time_idx
  on readings (device_id, "timestamp" desc);

create table if not exists alerts (
  id            bigserial primary key,
  device_id     text not null references devices (device_id) on delete cascade,
  type          text not null,
  severity      text not null check (severity in ('info', 'warning', 'critical')),
  message       text not null,
  detail        text,
  -- The numbers that tripped the rule, so the UI can show *why*, not just *that*.
  snapshot      jsonb,
  sms_sent      boolean not null default false,
  sms_error     text,
  sms_note      text,
  acknowledged  boolean not null default false,
  "timestamp"   timestamptz not null
);

create index if not exists alerts_device_time_idx
  on alerts (device_id, "timestamp" desc);

-- Keeps devices.updated_at honest without the application having to remember.
create or replace function touch_updated_at() returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists devices_touch_updated_at on devices;
create trigger devices_touch_updated_at
  before update on devices
  for each row execute function touch_updated_at();
