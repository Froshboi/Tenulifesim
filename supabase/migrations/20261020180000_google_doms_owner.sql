create table if not exists public.tenu_house_settings (
  setting_key text primary key check (setting_key = 'doms_owner_email'),
  setting_value text not null,
  updated_at timestamptz not null default now()
);
alter table public.tenu_house_settings enable row level security;
revoke all on public.tenu_house_settings from public, anon, authenticated;

create or replace function public.guard_doms_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.character_id = 'Doms' and not exists (
    select 1 from public.tenu_house_admins a
    where a.user_id = new.user_id
  ) then
    raise exception 'This profile is unavailable to this account';
  end if;
  return new;
end;
$$;
revoke execute on function public.guard_doms_profile() from public, anon, authenticated;
drop trigger if exists tenu_guard_doms_profile on public.tenu_players;
create trigger tenu_guard_doms_profile
  before insert or update of character_id,user_id on public.tenu_players
  for each row execute function public.guard_doms_profile();

create or replace function public.sync_tenu_doms_owner(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner_email text;
  v_user_email text;
  v_confirmed_at timestamptz;
begin
  select lower(btrim(s.setting_value))
    into v_owner_email
    from public.tenu_house_settings s
    where s.setting_key = 'doms_owner_email';
  select lower(u.email),u.email_confirmed_at
    into v_user_email,v_confirmed_at
    from auth.users u
    where u.id = p_user_id;

  if v_owner_email is null or v_owner_email = ''
     or v_user_email is distinct from v_owner_email
     or v_confirmed_at is null then
    delete from public.tenu_house_admins where user_id = p_user_id;
    return;
  end if;

  delete from public.tenu_house_admins where user_id <> p_user_id;
  insert into public.tenu_house_admins(user_id)
    values(p_user_id) on conflict (user_id) do nothing;

  if not exists (
    select 1 from public.tenu_players p where p.user_id = p_user_id
  ) then
    update public.tenu_players
      set user_id = p_user_id, updated_at = now()
      where character_id = 'Doms';
    if not found then
      insert into public.tenu_players(character_id,user_id,character_name,appearance)
        values('Doms',p_user_id,'Doms','{}'::jsonb)
        on conflict (character_id) do nothing;
    end if;
    update public.tenu_bank_accounts
      set user_id = p_user_id, updated_at = now()
      where character_id = 'Doms';
  end if;
end;
$$;
revoke execute on function public.sync_tenu_doms_owner(uuid) from public, anon, authenticated;

create or replace function public.sync_tenu_doms_owner_from_auth()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.sync_tenu_doms_owner(new.id);
  return new;
end;
$$;
revoke execute on function public.sync_tenu_doms_owner_from_auth() from public, anon, authenticated;
drop trigger if exists tenu_sync_doms_owner_from_auth on auth.users;
create trigger tenu_sync_doms_owner_from_auth
  after insert or update of email,email_confirmed_at on auth.users
  for each row execute function public.sync_tenu_doms_owner_from_auth();

create or replace function public.sync_tenu_doms_owner_from_settings()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner_id uuid;
begin
  if new.setting_key = 'doms_owner_email' then
    select u.id into v_owner_id
      from auth.users u
      where lower(u.email) = lower(btrim(new.setting_value))
        and u.email_confirmed_at is not null
      limit 1;
    if v_owner_id is not null then
      perform public.sync_tenu_doms_owner(v_owner_id);
    else
      delete from public.tenu_house_admins;
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.sync_tenu_doms_owner_from_settings() from public, anon, authenticated;
drop trigger if exists tenu_sync_doms_owner_from_settings on public.tenu_house_settings;
create trigger tenu_sync_doms_owner_from_settings
  after insert or update of setting_value on public.tenu_house_settings
  for each row execute function public.sync_tenu_doms_owner_from_settings();
