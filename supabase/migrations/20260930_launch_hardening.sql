-- Pre-launch hardening.
--
-- Three problems, all reachable with nothing but the public anon key:
--
--  1. Every `security definer` helper was left executable by PUBLIC, which
--     is Postgres' default. `delete_user_data(uuid)` is the worst of them:
--     anyone who guessed or harvested a user id could erase that account.
--  2. The "service role manages rate limits" policy was written without a
--     TO clause, so it applied to `authenticated` too and let any signed-in
--     player read and edit every other player's rate-limit rows.
--  3. Several of those helpers ran without a fixed `search_path`, so a
--     schema earlier on the caller's path could shadow the tables they
--     write.

-- ------------------------------------------------------------------
-- 1. Account deletion is the caller's own account only
-- ------------------------------------------------------------------

create or replace function public.delete_user_data(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if p_user_id is null
       or not (
           auth.uid() = p_user_id
           or coalesce(auth.jwt() ->> 'role', '') = 'service_role'
       )
    then
        raise exception 'delete_user_data: not authorized'
            using errcode = '42501';
    end if;

    delete from public.support_actions where user_id = p_user_id;
    delete from public.session_history where user_id = p_user_id;
    delete from public.rate_limits where user_id = p_user_id;
    delete from public.subscriptions where user_id = p_user_id;
    delete from public.profiles where id = p_user_id;
end;
$$;

-- ------------------------------------------------------------------
-- 2. Pin search_path on the helpers that lacked it
-- ------------------------------------------------------------------

alter function public.increment_rate_limit(uuid, text)
    set search_path = public;
alter function public.check_rate_limit(uuid, text)
    set search_path = public;
alter function public.update_user_stats(
        uuid, integer, integer, integer, integer, integer, integer, integer)
    set search_path = public;
alter function public.upsert_subscription(
        uuid, text, text, text, timestamptz, timestamptz)
    set search_path = public;

-- ------------------------------------------------------------------
-- 3. Lock execute down to the roles that actually call each helper
-- ------------------------------------------------------------------

-- Edge Functions reach these with the service role key. The app never
-- calls them directly.
revoke all on function public.increment_rate_limit(uuid, text)
    from public, anon, authenticated;
revoke all on function public.check_rate_limit(uuid, text)
    from public, anon, authenticated;
revoke all on function public.update_user_stats(
        uuid, integer, integer, integer, integer, integer, integer, integer)
    from public, anon, authenticated;
revoke all on function public.upsert_subscription(
        uuid, text, text, text, timestamptz, timestamptz)
    from public, anon, authenticated;
revoke all on function public.ensure_subscription_row(uuid)
    from public, anon, authenticated;
revoke all on function public.compensation_rounds(uuid)
    from public, anon, authenticated;

grant execute on function public.increment_rate_limit(uuid, text)
    to service_role;
grant execute on function public.check_rate_limit(uuid, text)
    to service_role;
grant execute on function public.update_user_stats(
        uuid, integer, integer, integer, integer, integer, integer, integer)
    to service_role;
grant execute on function public.upsert_subscription(
        uuid, text, text, text, timestamptz, timestamptz)
    to service_role;
grant execute on function public.ensure_subscription_row(uuid)
    to service_role;
grant execute on function public.compensation_rounds(uuid)
    to service_role;

-- Account deletion is reachable from the app, so `authenticated` keeps
-- execute. The body above limits it to the caller's own row.
revoke all on function public.delete_user_data(uuid) from public, anon;
grant execute on function public.delete_user_data(uuid)
    to authenticated, service_role;

-- ------------------------------------------------------------------
-- 4. Rate-limit rows are not readable or writable across accounts
-- ------------------------------------------------------------------

drop policy if exists "Service role manages rate limits" on public.rate_limits;

create policy "Service role manages rate limits"
    on public.rate_limits for all
    to service_role
    using (true)
    with check (true);
