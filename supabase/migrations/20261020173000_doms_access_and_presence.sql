alter table public.tenu_players
  add column if not exists last_seen_at timestamptz;

create table if not exists public.tenu_house_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.tenu_house_admins enable row level security;
revoke all on public.tenu_house_admins from public, anon, authenticated;

insert into public.tenu_house_admins(user_id)
  select user_id from public.tenu_players where character_id = 'Doms'
  on conflict (user_id) do nothing;

create or replace function public.guard_doms_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    if old.character_id = 'Doms' and old.user_id <> (select auth.uid()) then
      raise exception 'Only the Doms account owner can change this profile';
    end if;
  end if;
  if new.character_id = 'Doms' and not exists (
    select 1 from public.tenu_house_admins a
    where a.user_id = (select auth.uid())
  ) then
    raise exception 'Doms is reserved for the household owner';
  end if;
  return new;
end;
$$;
revoke execute on function public.guard_doms_profile() from public, anon, authenticated;
drop trigger if exists tenu_guard_doms_profile on public.tenu_players;
create trigger tenu_guard_doms_profile
  before insert or update of character_id,user_id on public.tenu_players
  for each row execute function public.guard_doms_profile();

create or replace function public.set_tenu_presence(
  p_character_id text,
  p_is_online boolean
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or p_is_online is null then
    raise exception 'Invalid presence update';
  end if;
  update public.tenu_players
    set last_seen_at = case when p_is_online then now() else null end,
        updated_at = now()
    where character_id = p_character_id and user_id = (select auth.uid());
  if not found then raise exception 'You do not own this character'; end if;
end;
$$;
revoke execute on function public.set_tenu_presence(text,boolean) from public, anon;
grant execute on function public.set_tenu_presence(text,boolean) to authenticated;

alter table public.tenu_game_transactions
  drop constraint if exists tenu_game_transactions_action_check;
alter table public.tenu_game_transactions
  add constraint tenu_game_transactions_action_check
  check (action in (
    'work','school','market','groceries','outfit','phone','bill','doms_gift',
    'bolt','uber','keke','flight_abuja','flight_port_harcourt','flight_enugu'
  ));

create or replace function public.purchase_tenu_item(p_item text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_character_id text;
  v_price bigint;
  v_balance bigint;
begin
  if (select auth.uid()) is null then raise exception 'Sign in to shop'; end if;
  v_price := case p_item
    when 'groceries' then 120 when 'outfit' then 350
    when 'phone' then 900 when 'bill' then 250
    when 'bolt' then 250 when 'uber' then 350 when 'keke' then 100
    when 'flight_abuja' then 2500 when 'flight_port_harcourt' then 2200
    when 'flight_enugu' then 2300 else null
  end;
  if v_price is null then raise exception 'Unknown shop item'; end if;
  select p.character_id into v_character_id
    from public.tenu_players p where p.user_id = (select auth.uid());
  if v_character_id is null then raise exception 'Claim a household character first'; end if;
  select a.balance into v_balance from public.tenu_bank_accounts a
    where a.character_id = v_character_id and a.user_id = (select auth.uid()) for update;
  if not found or v_balance < v_price then raise exception 'Insufficient balance'; end if;
  update public.tenu_bank_accounts
    set balance = balance - v_price, updated_at = now()
    where character_id = v_character_id;
  if p_item = 'groceries' then
    update public.tenu_players
      set needs = jsonb_set(needs,'{hunger}','100'::jsonb,true), updated_at = now()
      where character_id = v_character_id;
  end if;
  insert into public.tenu_game_transactions(character_id,action,amount_delta)
    values(v_character_id,p_item,-v_price);
  return v_balance - v_price;
end;
$$;
revoke execute on function public.purchase_tenu_item(text) from public, anon;
grant execute on function public.purchase_tenu_item(text) to authenticated;
