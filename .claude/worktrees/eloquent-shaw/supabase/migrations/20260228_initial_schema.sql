-- ============================================================
-- Roadtrip Trivia — Initial Database Schema
-- PRD v1.0.2 — Accounts, Session History, Rate Limiting, Analytics
-- ============================================================

-- ============================================================
-- 1. USER PROFILES (AUTH-01, AUTH-02)
-- Extends Supabase Auth with app-specific user data.
-- Supabase Auth handles: Sign in with Apple, email/password,
-- magic link, Google, Facebook (configured in Dashboard).
-- ============================================================
create table public.profiles (
    id uuid primary key references auth.users(id) on delete cascade,
    display_name text,
    last_difficulty text default 'Tricky' check (last_difficulty in ('Simple', 'Tricky', 'Hard', 'Einstein')),
    total_sessions integer default 0,
    total_rounds integer default 0,
    total_questions_answered integer default 0,
    total_questions_correct integer default 0,
    total_hints_used integer default 0,
    total_challenges_used integer default 0,
    total_challenges_overturned integer default 0,
    total_lightning_rounds integer default 0,
    created_at timestamptz default now(),
    updated_at timestamptz default now()
);

-- Auto-create profile when a new user signs up
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
    insert into public.profiles (id, display_name)
    values (
        new.id,
        coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', 'Player')
    );
    return new;
end;
$$;

create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_user();

-- ============================================================
-- 2. SESSION HISTORY (Analytics, RESUME-01/02)
-- Tracks completed and in-progress game sessions.
-- ============================================================
create table public.session_history (
    id uuid primary key default gen_random_uuid(),
    user_id uuid references public.profiles(id) on delete cascade not null,
    difficulty text not null,
    player_count integer not null default 1,
    age_bands text[] not null default '{"Adults (18+)"}',
    location_label text,
    rounds_played integer default 0,
    total_questions_answered integer default 0,
    total_questions_correct integer default 0,
    hints_used integer default 0,
    challenges_used integer default 0,
    challenges_overturned integer default 0,
    lightning_rounds_played integer default 0,
    is_complete boolean default false,
    started_at timestamptz default now(),
    ended_at timestamptz,
    -- Resume checkpoint data (RESUME-02)
    checkpoint_round_index integer,
    checkpoint_question_index integer,
    checkpoint_category text,
    checkpoint_data jsonb
);

create index idx_session_history_user on public.session_history(user_id);
create index idx_session_history_started on public.session_history(started_at desc);

-- ============================================================
-- 3. RATE LIMITING (COST-05)
-- Soft limits per account to prevent abuse.
-- Tracked per user per day.
-- ============================================================
create table public.rate_limits (
    id bigint generated always as identity primary key,
    user_id uuid references public.profiles(id) on delete cascade not null,
    action_type text not null, -- 'generate', 'grade', 'challenge'
    window_date date not null default current_date,
    request_count integer default 1,
    created_at timestamptz default now(),
    unique(user_id, action_type, window_date)
);

create index idx_rate_limits_lookup on public.rate_limits(user_id, action_type, window_date);

-- Rate limit thresholds (soft limits per PRD COST-05):
--   generate:  50 rounds/day  (250 questions)
--   grade:     300 grades/day (50 rounds x 5 questions + retries)
--   challenge: 50 challenges/day
-- These are enforced in the Edge Functions, not at the DB level.

-- ============================================================
-- 4. ROW LEVEL SECURITY (RLS)
-- Users can only read/write their own data.
-- ============================================================

alter table public.profiles enable row level security;
alter table public.session_history enable row level security;
alter table public.rate_limits enable row level security;

-- Profiles: users can read and update their own profile
create policy "Users can view own profile"
    on public.profiles for select
    using (auth.uid() = id);

create policy "Users can update own profile"
    on public.profiles for update
    using (auth.uid() = id);

-- Session history: users can CRUD their own sessions
create policy "Users can view own sessions"
    on public.session_history for select
    using (auth.uid() = user_id);

create policy "Users can insert own sessions"
    on public.session_history for insert
    with check (auth.uid() = user_id);

create policy "Users can update own sessions"
    on public.session_history for update
    using (auth.uid() = user_id);

create policy "Users can delete own sessions"
    on public.session_history for delete
    using (auth.uid() = user_id);

-- Rate limits: users can view their own; Edge Functions insert/update via service role
create policy "Users can view own rate limits"
    on public.rate_limits for select
    using (auth.uid() = user_id);

-- Service role policies for Edge Functions (they use the service_role key)
create policy "Service role manages rate limits"
    on public.rate_limits for all
    using (true)
    with check (true);

-- ============================================================
-- 5. HELPER FUNCTIONS
-- ============================================================

-- Increment rate limit counter (called from Edge Functions)
create or replace function public.increment_rate_limit(
    p_user_id uuid,
    p_action_type text
)
returns integer
language plpgsql
security definer
as $$
declare
    v_count integer;
begin
    insert into public.rate_limits (user_id, action_type, window_date, request_count)
    values (p_user_id, p_action_type, current_date, 1)
    on conflict (user_id, action_type, window_date)
    do update set request_count = rate_limits.request_count + 1
    returning request_count into v_count;

    return v_count;
end;
$$;

-- Check rate limit (called from Edge Functions)
create or replace function public.check_rate_limit(
    p_user_id uuid,
    p_action_type text
)
returns integer
language plpgsql
security definer
as $$
declare
    v_count integer;
begin
    select coalesce(request_count, 0) into v_count
    from public.rate_limits
    where user_id = p_user_id
      and action_type = p_action_type
      and window_date = current_date;

    return coalesce(v_count, 0);
end;
$$;

-- Update user lifetime stats after a session completes
create or replace function public.update_user_stats(
    p_user_id uuid,
    p_rounds integer,
    p_answered integer,
    p_correct integer,
    p_hints integer,
    p_challenges integer,
    p_overturned integer,
    p_lightning integer
)
returns void
language plpgsql
security definer
as $$
begin
    update public.profiles
    set
        total_sessions = total_sessions + 1,
        total_rounds = total_rounds + p_rounds,
        total_questions_answered = total_questions_answered + p_answered,
        total_questions_correct = total_questions_correct + p_correct,
        total_hints_used = total_hints_used + p_hints,
        total_challenges_used = total_challenges_used + p_challenges,
        total_challenges_overturned = total_challenges_overturned + p_overturned,
        total_lightning_rounds = total_lightning_rounds + p_lightning,
        updated_at = now()
    where id = p_user_id;
end;
$$;

-- Delete all user data (AUTH-05: account deletion)
create or replace function public.delete_user_data(p_user_id uuid)
returns void
language plpgsql
security definer
as $$
begin
    delete from public.session_history where user_id = p_user_id;
    delete from public.rate_limits where user_id = p_user_id;
    delete from public.profiles where id = p_user_id;
end;
$$;
