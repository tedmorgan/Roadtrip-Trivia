-- Copy Auth emails onto profiles created before the email column existed,
-- and let support search match a partial email, username, or display name.

update public.profiles p
set email = u.email,
    updated_at = now()
from auth.users u
where p.id = u.id
  and u.email is not null
  and (p.email is null or btrim(p.email) = '');

create or replace function public.search_support_profiles(p_query text)
returns setof public.profiles
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
    q text := lower(btrim(coalesce(p_query, '')));
    q_like text;
begin
    if q = '' then
        return;
    end if;

    q_like := '%' || replace(replace(replace(q, '\', ''), '%', ''), '_', '') || '%';
    if replace(replace(replace(q, '\', ''), '%', ''), '_', '') = '' then
        return;
    end if;

    return query
    select p.*
    from public.profiles p
    left join auth.users u on u.id = p.id
    where p.id::text = q
       or lower(coalesce(p.username_normalized, '')) = q
       or lower(coalesce(p.email, u.email, '')) = q
       or lower(coalesce(p.email, u.email, '')) like q_like
       or lower(coalesce(p.username, '')) like q_like
       or lower(coalesce(p.username_normalized, '')) like q_like
       or lower(coalesce(p.display_name, '')) like q_like
       or lower(coalesce(u.raw_user_meta_data->>'full_name', '')) like q_like
       or lower(coalesce(u.raw_user_meta_data->>'name', '')) like q_like
    order by
        case
            when p.id::text = q then 0
            when lower(coalesce(p.username_normalized, '')) = q then 1
            when lower(coalesce(p.email, u.email, '')) = q then 2
            when lower(coalesce(p.email, u.email, '')) like q_like then 3
            else 4
        end,
        p.created_at desc nulls last
    limit 8;
end;
$$;

revoke all on function public.search_support_profiles(text) from public, anon, authenticated;
grant execute on function public.search_support_profiles(text) to service_role;
