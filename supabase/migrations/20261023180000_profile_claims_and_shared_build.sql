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

revoke insert, update, delete on public.tenu_players from public, anon, authenticated;
grant update (character_name,appearance,last_seen_at,updated_at) on public.tenu_players to authenticated;

create table if not exists public.tenu_house_items (
  id uuid primary key default gen_random_uuid(),
  item_id text not null check (item_id in (
    'bed','fridge','tv','ceiling_fan','mosquito_net','generator',
    'inverter','solar_panel','water_tank'
  )),
  x numeric(6,2) not null,
  z numeric(6,2) not null,
  rotation smallint not null check (rotation in (0,90,180,270)),
  price_paid bigint not null check (price_paid > 0),
  placed_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.tenu_house_items enable row level security;
revoke all on public.tenu_house_items from public, anon, authenticated;
drop policy if exists "Household members can view shared furniture" on public.tenu_house_items;
create policy "Household members can view shared furniture" on public.tenu_house_items
  for select to authenticated using (true);
grant select on public.tenu_house_items to authenticated;

create or replace function public.validate_tenu_item_placement(
  p_item_id text,
  p_x numeric,
  p_z numeric,
  p_rotation integer,
  p_ignore_id uuid default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_width integer;
  v_depth integer;
  v_other record;
  v_other_width integer;
  v_other_depth integer;
  v_swap integer;
  v_left numeric;
  v_right numeric;
  v_top numeric;
  v_bottom numeric;
  v_other_left numeric;
  v_other_right numeric;
  v_other_top numeric;
  v_other_bottom numeric;
  v_cell_x numeric;
  v_cell_z numeric;
  v_dx integer;
  v_dz integer;
begin
  if p_item_id is null or p_x is null or p_z is null or p_rotation is null
     or p_rotation not in (0,90,180,270) then
    raise exception 'Invalid furniture placement';
  end if;

  select size.width,size.depth into v_width,v_depth
    from (values
      ('bed',5,5),('fridge',3,3),('tv',5,3),('ceiling_fan',3,3),
      ('mosquito_net',7,7),('generator',3,3),('inverter',3,3),
      ('solar_panel',5,3),('water_tank',5,5)
    ) as size(item_id,width,depth)
    where size.item_id = p_item_id;
  if not found then raise exception 'Unknown furniture item'; end if;
  if p_rotation in (90,270) then
    v_swap := v_width;v_width := v_depth;v_depth := v_swap;
  end if;
  if abs((p_x + 34) * 2 - round((p_x + 34) * 2)) > 0.001
     or abs((p_z + 32) * 2 - round((p_z + 32) * 2)) > 0.001 then
    raise exception 'Furniture must align to the house grid';
  end if;

  v_left := p_x - v_width * 0.25;
  v_right := p_x + v_width * 0.25;
  v_top := p_z - v_depth * 0.25;
  v_bottom := p_z + v_depth * 0.25;
  if p_x - (v_width - 1) * 0.25 < -15.5
     or p_x + (v_width - 1) * 0.25 > 3.5
     or p_z - (v_depth - 1) * 0.25 < -16.5
     or p_z + (v_depth - 1) * 0.25 > -1.5 then
    raise exception 'Furniture must stay inside the house';
  end if;

  for v_dx in -((v_width - 1) / 2)..((v_width - 1) / 2) loop
    for v_dz in -((v_depth - 1) / 2)..((v_depth - 1) / 2) loop
      v_cell_x := p_x + v_dx * 0.5;
      v_cell_z := p_z + v_dz * 0.5;
      if exists (
        select 1 from (values
          (-6.0,-17.0,20.0,0.3),(-16.0,-9.0,0.3,16.0),(4.0,-9.0,0.3,16.0),
          (-11.5,-1.0,9.0,0.3),(-0.5,-1.0,9.0,0.3),(-25.0,-4.0,8.0,9.0),
          (21.0,-5.0,9.0,10.0),(22.0,-23.0,13.0,11.0),
          (-11.0,-14.75,0.2,4.5),(-11.0,-9.65,0.2,2.3),
          (-6.0,-14.75,0.2,4.5),(-6.0,-9.65,0.2,2.3),
          (-1.0,-14.75,0.2,4.5),(-1.0,-9.65,0.2,2.3),
          (-16.0,-8.5,3.6,0.2),(-11.3,-8.5,0.8,0.2),
          (-11.0,-8.5,3.6,0.2),(-6.3,-8.5,0.8,0.2),
          (-6.0,-8.5,3.6,0.2),(-1.3,-8.5,0.8,0.2),
          (-1.0,-8.5,3.6,0.2),(3.7,-8.5,0.8,0.2),
          (-13.5,-14.2,2.8,2.8),(-8.5,-14.2,2.8,2.8),
          (-3.5,-14.2,2.8,2.8),(1.5,-14.2,2.8,2.8),
          (-12.0,-4.2,3.2,1.2),(-12.0,-4.9,3.2,0.3),
          (-12.0,-7.8,2.2,0.2),(-12.0,-7.5,2.4,0.5),
          (-6.5,-6.2,2.2,2.4),(-6.5,-7.5,2.2,0.8),
          (1.1,-6.1,1.1,1.1),(-1.5,-3.2,2.6,0.8)
        ) as blocker(x,z,width,depth)
        where abs(v_cell_x-blocker.x) <= blocker.width/2+0.36
          and abs(v_cell_z-blocker.z) <= blocker.depth/2+0.36
      ) then
        raise exception 'Furniture cannot cover a wall or fixed fixture';
      end if;
    end loop;
  end loop;

  for v_other in
    select i.item_id,i.x,i.z,i.rotation from public.tenu_house_items i
    where p_ignore_id is null or i.id <> p_ignore_id
  loop
    select size.width,size.depth into v_other_width,v_other_depth
      from (values
        ('bed',5,5),('fridge',3,3),('tv',5,3),('ceiling_fan',3,3),
        ('mosquito_net',7,7),('generator',3,3),('inverter',3,3),
        ('solar_panel',5,3),('water_tank',5,5)
      ) as size(item_id,width,depth)
      where size.item_id = v_other.item_id;
    if v_other.rotation in (90,270) then
      v_swap := v_other_width;v_other_width := v_other_depth;v_other_depth := v_swap;
    end if;
    v_other_left := v_other.x - v_other_width * 0.25;
    v_other_right := v_other.x + v_other_width * 0.25;
    v_other_top := v_other.z - v_other_depth * 0.25;
    v_other_bottom := v_other.z + v_other_depth * 0.25;
    if v_left < v_other_right and v_right > v_other_left
       and v_top < v_other_bottom and v_bottom > v_other_top then
      raise exception 'Furniture cannot overlap another item';
    end if;
  end loop;
end;
$$;
revoke execute on function public.validate_tenu_item_placement(text,numeric,numeric,integer,uuid) from public, anon, authenticated;

create or replace function public.place_tenu_house_item(
  p_item_id text,
  p_x numeric,
  p_z numeric,
  p_rotation integer
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_character_id text;
  v_price bigint;
  v_balance bigint;
  v_item_id uuid;
begin
  if (select auth.uid()) is null then raise exception 'Sign in to build'; end if;
  select p.character_id into v_character_id
    from public.tenu_players p where p.user_id = (select auth.uid());
  if v_character_id is null then raise exception 'Choose a household character first'; end if;
  v_price := case p_item_id
    when 'bed' then 600 when 'fridge' then 800 when 'tv' then 700
    when 'ceiling_fan' then 350 when 'mosquito_net' then 400
    when 'generator' then 1200 when 'inverter' then 1500
    when 'solar_panel' then 2000 when 'water_tank' then 1000
    else null end;
  if v_price is null then raise exception 'Unknown furniture item'; end if;

  perform pg_advisory_xact_lock(778899001);
  perform public.validate_tenu_item_placement(p_item_id,p_x,p_z,p_rotation,null);
  select a.balance into v_balance from public.tenu_bank_accounts a
    where a.character_id = v_character_id and a.user_id = (select auth.uid()) for update;
  if not found or v_balance < v_price then raise exception 'Insufficient balance'; end if;

  update public.tenu_bank_accounts
    set balance = balance - v_price,updated_at = now()
    where character_id = v_character_id and user_id = (select auth.uid());
  insert into public.tenu_game_transactions(character_id,action,amount_delta)
    values(v_character_id,'build_item',-v_price);
  insert into public.tenu_house_items(item_id,x,z,rotation,price_paid,placed_by)
    values(p_item_id,p_x,p_z,p_rotation,v_price,(select auth.uid()))
    returning id into v_item_id;
  return v_item_id;
end;
$$;
revoke execute on function public.place_tenu_house_item(text,numeric,numeric,integer) from public, anon;
grant execute on function public.place_tenu_house_item(text,numeric,numeric,integer) to authenticated;

create or replace function public.move_tenu_house_item(
  p_item_id uuid,
  p_x numeric,
  p_z numeric,
  p_rotation integer
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item_id text;
begin
  if (select auth.uid()) is null or not exists (
    select 1 from public.tenu_players p where p.user_id = (select auth.uid())
  ) then raise exception 'Choose a household character first'; end if;
  perform pg_advisory_xact_lock(778899001);
  select i.item_id into v_item_id from public.tenu_house_items i
    where i.id = p_item_id for update;
  if not found then raise exception 'Furniture no longer exists'; end if;
  perform public.validate_tenu_item_placement(v_item_id,p_x,p_z,p_rotation,p_item_id);
  update public.tenu_house_items
    set x = p_x,z = p_z,rotation = p_rotation,updated_at = now()
    where id = p_item_id;
end;
$$;
revoke execute on function public.move_tenu_house_item(uuid,numeric,numeric,integer) from public, anon;
grant execute on function public.move_tenu_house_item(uuid,numeric,numeric,integer) to authenticated;

create or replace function public.sell_tenu_house_item(p_item_id uuid)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_character_id text;
  v_refund bigint;
  v_item_id text;
  v_balance bigint;
begin
  if (select auth.uid()) is null then raise exception 'Sign in to sell furniture'; end if;
  select p.character_id into v_character_id
    from public.tenu_players p where p.user_id = (select auth.uid());
  if v_character_id is null then raise exception 'Choose a household character first'; end if;
  perform pg_advisory_xact_lock(778899001);
  select i.price_paid / 2,i.item_id into v_refund,v_item_id
    from public.tenu_house_items i where i.id = p_item_id for update;
  if not found then raise exception 'Furniture no longer exists'; end if;
  select a.balance into v_balance from public.tenu_bank_accounts a
    where a.character_id = v_character_id and a.user_id = (select auth.uid()) for update;
  if not found then raise exception 'Wallet is unavailable'; end if;

  update public.tenu_bank_accounts
    set balance = balance + v_refund,updated_at = now()
    where character_id = v_character_id and user_id = (select auth.uid());
  delete from public.tenu_house_items where id = p_item_id;
  insert into public.tenu_game_transactions(character_id,action,amount_delta)
    values(v_character_id,'sell_item',v_refund);
  return v_refund;
end;
$$;
revoke execute on function public.sell_tenu_house_item(uuid) from public, anon;
grant execute on function public.sell_tenu_house_item(uuid) to authenticated;

alter table public.tenu_game_transactions
  drop constraint if exists tenu_game_transactions_action_check;
alter table public.tenu_game_transactions
  add constraint tenu_game_transactions_action_check
  check (action in (
    'work','school','market','groceries','outfit','phone','bill','doms_gift',
    'diesel','daily_goal','bolt','uber','keke','flight_abuja',
    'flight_port_harcourt','flight_enugu','build_item','sell_item'
  ));

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'tenu_house_items'
  ) then
    alter publication supabase_realtime add table public.tenu_house_items;
  end if;
end $$;
