-- ============================================================
-- Account recovery + customer-support admin console
-- Usernames, admin flag, round compensation ledger, audit log
-- ============================================================

alter table public.profiles
    add column if not exists username text,
    add column if not exists username_normalized text,
    add column if not exists email text,
    add column if not exists is_admin boolean not null default false;

create unique index if not exists profiles_username_normalized_key
    on public.profiles (username_normalized)
    where username_normalized is not null;

create index if not exists profiles_email_idx
    on public.profiles (lower(email))
    where email is not null;

-- Keep profiles in sync with Auth metadata (username + email).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
    v_username text;
    v_normalized text;
begin
    v_username := nullif(trim(coalesce(new.raw_user_meta_data->>'username', '')), '');
    if v_username is not null then
        v_normalized := lower(v_username);
    end if;

    insert into public.profiles (id, display_name, username, username_normalized, email)
    values (
        new.id,
        coalesce(
            new.raw_user_meta_data->>'full_name',
            new.raw_user_meta_data->>'name',
            v_username,
            'Player'
        ),
        v_username,
        v_normalized,
        new.email
    )
    on conflict (id) do update set
        email = excluded.email,
        username = coalesce(public.profiles.username, excluded.username),
        username_normalized = coalesce(public.profiles.username_normalized, excluded.username_normalized),
        updated_at = now();

    insert into public.subscriptions (user_id)
    values (new.id)
    on conflict (user_id) do nothing;

    return new;
end;
$$;

-- Round compensation used by CS credits / refund clawbacks.
alter table public.subscriptions
    add column if not exists support_rounds_granted integer not null default 0,
    add column if not exists support_rounds_clawed_back integer not null default 0;

create table if not exists public.support_actions (
    id uuid primary key default gen_random_uuid(),
    actor_id uuid references auth.users(id) on delete set null,
    user_id uuid references auth.users(id) on delete cascade,
    action text not null,
    rounds integer not null default 0,
    note text,
    apple_transaction_id text,
    payload jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now()
);

create index if not exists support_actions_user_idx
    on public.support_actions (user_id, created_at desc);

create index if not exists support_actions_created_idx
    on public.support_actions (created_at desc);

alter table public.support_actions enable row level security;

-- Players never read the CS audit log; the admin edge function uses
-- the service role. Keep a deny-by-default policy for authenticated users.
create policy "Admins can view support actions"
    on public.support_actions for select
    using (
        exists (
            select 1 from public.profiles p
            where p.id = auth.uid() and p.is_admin = true
        )
    );

create or replace function public.ensure_subscription_row(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.subscriptions (user_id)
    values (p_user_id)
    on conflict (user_id) do nothing;
end;
$$;

create or replace function public.compensation_rounds(p_user_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
    select greatest(
        0,
        coalesce(support_rounds_granted, 0) - coalesce(support_rounds_clawed_back, 0)
    )
    from public.subscriptions
    where user_id = p_user_id;
$$;

-- Players may read their own compensation total via the subscriptions row.

create or replace function public.delete_user_data(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    delete from public.support_actions where user_id = p_user_id;
    delete from public.session_history where user_id = p_user_id;
    delete from public.rate_limits where user_id = p_user_id;
    delete from public.subscriptions where user_id = p_user_id;
    delete from public.profiles where id = p_user_id;
end;
$$;

-- Players must not be able to grant themselves admin or support rounds.
revoke update on public.profiles from anon, authenticated;
grant update (
    display_name,
    last_difficulty,
    username,
    username_normalized,
    email,
    updated_at
) on public.profiles to authenticated;

revoke update on public.subscriptions from anon, authenticated;
grant update (
    product_id,
    status,
    original_transaction_id,
    current_period_start,
    current_period_end,
    purchased_rounds,
    subscription_rounds_used,
    free_round_used,
    rounds_played_total,
    total_amount_spent
) on public.subscriptions to authenticated;

revoke all on public.support_actions from anon, authenticated;
