do $$
declare
  v_constraint record;
begin
  for v_constraint in
    select c.conname
    from pg_constraint c
    where c.conrelid = 'public.tenu_house_settings'::regclass
      and c.contype = 'c'
      and pg_get_constraintdef(c.oid) ilike '%setting_key%'
  loop
    execute format(
      'alter table public.tenu_house_settings drop constraint %I',
      v_constraint.conname
    );
  end loop;
end;
$$;

alter table public.tenu_house_settings
  add constraint tenu_house_settings_setting_key_check
  check (setting_key in ('doms_owner_email','mma_owner_email'));

create or replace function public.sync_tenu_mma_owner(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner_email text;
  v_user_email text;
  v_confirmed_at timestamptz;
  v_existing_character text;
  v_owner_id uuid;
  v_last_seen_at timestamptz;
begin
  select lower(btrim(s.setting_value))
    into v_owner_email
    from public.tenu_house_settings s
    where s.setting_key = 'mma_owner_email';
  select lower(u.email),u.email_confirmed_at
    into v_user_email,v_confirmed_at
    from auth.users u
    where u.id = p_user_id;

  if v_owner_email is null or v_owner_email = ''
     or v_user_email is distinct from v_owner_email
     or v_confirmed_at is null then
    return;
  end if;

  select p.character_id into v_existing_character
    from public.tenu_players p where p.user_id = p_user_id;
  if v_existing_character is not null and v_existing_character <> 'MMA' then
    return;
  end if;

  select p.user_id,p.last_seen_at into v_owner_id,v_last_seen_at
    from public.tenu_players p
    where p.character_id = 'MMA'
    for update;
  if found then
    if v_owner_id = p_user_id then return; end if;
    if v_last_seen_at > now() - interval '30 seconds' then return; end if;
    update public.tenu_players
      set user_id = p_user_id,last_seen_at = now(),updated_at = now()
      where character_id = 'MMA' and user_id = v_owner_id;
    return;
  end if;

  insert into public.tenu_players(character_id,user_id,character_name,last_seen_at)
    values('MMA',p_user_id,'MMA',now())
    on conflict (character_id) do nothing;
end;
$$;
revoke execute on function public.sync_tenu_mma_owner(uuid) from public, anon, authenticated;

create or replace function public.sync_tenu_mma_owner_from_auth()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.sync_tenu_mma_owner(new.id);
  return new;
end;
$$;
revoke execute on function public.sync_tenu_mma_owner_from_auth() from public, anon, authenticated;
drop trigger if exists tenu_sync_mma_owner_from_auth on auth.users;
create trigger tenu_sync_mma_owner_from_auth
  after insert or update of email,email_confirmed_at on auth.users
  for each row execute function public.sync_tenu_mma_owner_from_auth();

create or replace function public.sync_tenu_mma_owner_from_settings()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner_id uuid;
begin
  if new.setting_key = 'mma_owner_email' then
    select u.id into v_owner_id
      from auth.users u
      where lower(u.email) = lower(btrim(new.setting_value))
        and u.email_confirmed_at is not null
      limit 1;
    if v_owner_id is not null then
      perform public.sync_tenu_mma_owner(v_owner_id);
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.sync_tenu_mma_owner_from_settings() from public, anon, authenticated;
drop trigger if exists tenu_sync_mma_owner_from_settings on public.tenu_house_settings;
create trigger tenu_sync_mma_owner_from_settings
  after insert or update of setting_value on public.tenu_house_settings
  for each row execute function public.sync_tenu_mma_owner_from_settings();

create or replace function public.claim_tenu_profile(p_character_id text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing text;
  v_owner_id uuid;
  v_last_seen_at timestamptz;
  v_character_name text;
begin
  if (select auth.uid()) is null
     or p_character_id is null
     or p_character_id not in ('MMA','Ukechi','Chibaby','Jahsfavour','Mummy','Dee') then
    raise exception 'Choose an available household character';
  end if;

  if p_character_id = 'MMA' and not exists (
    select 1
    from public.tenu_house_settings s
    join auth.users u on u.id = (select auth.uid())
    where s.setting_key = 'mma_owner_email'
      and lower(btrim(s.setting_value)) = lower(u.email)
      and u.email_confirmed_at is not null
  ) then
    raise exception 'MMA is reserved for the verified household account';
  end if;

  select p.character_id into v_existing
    from public.tenu_players p where p.user_id = (select auth.uid());
  if found then
    if v_existing = p_character_id then return v_existing; end if;
    raise exception 'This account already has a household character';
  end if;

  select p.user_id,p.last_seen_at into v_owner_id,v_last_seen_at
    from public.tenu_players p
    where p.character_id = p_character_id
    for update;
  if found then
    if v_owner_id = (select auth.uid()) then return p_character_id; end if;
    if v_last_seen_at > now() - interval '30 seconds' then
      raise exception 'This character is currently online';
    end if;
    update public.tenu_players
      set user_id = (select auth.uid()),last_seen_at = now(),updated_at = now()
      where character_id = p_character_id and user_id = v_owner_id;
    if not found then raise exception 'This character could not be claimed'; end if;
    return p_character_id;
  end if;

  v_character_name := p_character_id;
  insert into public.tenu_players(character_id,user_id,character_name,last_seen_at)
    values(p_character_id,(select auth.uid()),v_character_name,now());
  return p_character_id;
exception
  when unique_violation then
    raise exception 'That character is already linked to another account';
end;
$$;
revoke execute on function public.claim_tenu_profile(text) from public, anon;
grant execute on function public.claim_tenu_profile(text) to authenticated;
