alter table public.tenu_minigame_results
  drop constraint if exists tenu_minigame_results_game_check;
alter table public.tenu_minigame_results
  add constraint tenu_minigame_results_game_check
  check (game in ('cook','market','school','sleep','fun','generator','water'));
alter table public.tenu_minigame_cooldowns
  drop constraint if exists tenu_minigame_cooldowns_game_check;
alter table public.tenu_minigame_cooldowns
  add constraint tenu_minigame_cooldowns_game_check
  check (game in ('cook','market','school','sleep','fun','generator','water'));

create table if not exists public.tenu_generator_fuel (
  user_id uuid primary key references auth.users(id) on delete cascade,
  seconds_remaining integer not null default 0 check (seconds_remaining >= 0),
  updated_at timestamptz not null default now()
);
insert into public.tenu_generator_fuel(user_id,seconds_remaining)
  select a.user_id,least(2147483647::bigint,greatest(0,sum(-t.amount_delta)))::integer
  from public.tenu_game_transactions t
  join public.tenu_bank_accounts a on a.character_id = t.character_id
  where t.action = 'diesel' and t.amount_delta < 0
  group by a.user_id
  on conflict (user_id) do nothing;
alter table public.tenu_generator_fuel enable row level security;
revoke all on public.tenu_generator_fuel from public, anon, authenticated;

create or replace function public.purchase_tenu_diesel()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_character_id text;
  v_balance bigint;
begin
  if v_user_id is null then raise exception 'Sign in to buy diesel'; end if;
  select p.character_id into v_character_id from public.tenu_players p where p.user_id = v_user_id;
  if v_character_id is null then raise exception 'Claim a household character first'; end if;

  select a.balance into v_balance from public.tenu_bank_accounts a
    where a.character_id = v_character_id and a.user_id = v_user_id for update;
  if not found or v_balance < 300 then raise exception 'Insufficient balance'; end if;

  update public.tenu_bank_accounts
    set balance = balance - 300,updated_at = now()
    where character_id = v_character_id and user_id = v_user_id
    returning balance into v_balance;
  insert into public.tenu_game_transactions(character_id,action,amount_delta)
    values(v_character_id,'diesel',-300);
  insert into public.tenu_generator_fuel as fuel(user_id,seconds_remaining)
    values(v_user_id,300)
    on conflict (user_id) do update
      set seconds_remaining = fuel.seconds_remaining + 300,
          updated_at = now();
  return v_balance;
end;
$$;
revoke execute on function public.purchase_tenu_diesel() from public, anon;
grant execute on function public.purchase_tenu_diesel() to authenticated;

create or replace function public.get_tenu_generator_fuel()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_fuel integer;
begin
  if v_user_id is null then raise exception 'Sign in to check generator diesel'; end if;
  if not exists (select 1 from public.tenu_players p where p.user_id = v_user_id) then
    raise exception 'Choose a household character first';
  end if;
  select f.seconds_remaining into v_fuel from public.tenu_generator_fuel f where f.user_id = v_user_id;
  return coalesce(v_fuel,0);
end;
$$;
revoke execute on function public.get_tenu_generator_fuel() from public, anon;
grant execute on function public.get_tenu_generator_fuel() to authenticated;

create or replace function public.consume_tenu_generator_diesel(p_seconds integer)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_fuel integer;
begin
  if v_user_id is null or p_seconds is null or p_seconds not between 1 and 30 then
    raise exception 'Invalid generator fuel request';
  end if;
  select f.seconds_remaining into v_fuel from public.tenu_generator_fuel f
    where f.user_id = v_user_id for update;
  if not found or v_fuel < p_seconds then
    update public.tenu_generator_fuel set seconds_remaining = 0,updated_at = now()
      where user_id = v_user_id;
    return 0;
  end if;
  update public.tenu_generator_fuel
    set seconds_remaining = seconds_remaining - p_seconds,updated_at = now()
    where user_id = v_user_id returning seconds_remaining into v_fuel;
  return v_fuel;
end;
$$;
revoke execute on function public.consume_tenu_generator_diesel(integer) from public, anon;
grant execute on function public.consume_tenu_generator_diesel(integer) to authenticated;

create or replace function public.complete_tenu_minigame(p_game text,p_result text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_character_id text;
  v_needs jsonb;
  v_balance bigint;
  v_coins bigint;
  v_hourly_coins bigint;
  v_last_played_at timestamptz;
  v_need_key text;
  v_restore numeric;
  v_fuel integer;
begin
  if v_user_id is null or p_game is null or p_result is null
     or p_game not in ('cook','market','school','sleep','fun','generator','water')
     or p_result not in ('perfect','good','fail','auto')
     or (p_result = 'auto' and p_game <> 'cook') then
    raise exception 'Invalid mini-game result';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text,0));
  select p.character_id,p.needs into v_character_id,v_needs
    from public.tenu_players p where p.user_id = v_user_id for update;
  if v_character_id is null then raise exception 'Choose a household character first'; end if;

  select c.last_played_at into v_last_played_at
    from public.tenu_minigame_cooldowns c
    where c.user_id = v_user_id and c.game = p_game;
  if found and v_last_played_at > now() - interval '30 seconds' then
    raise exception 'This mini-game is cooling down';
  end if;

  if p_game = 'generator' then
    select f.seconds_remaining into v_fuel from public.tenu_generator_fuel f
      where f.user_id = v_user_id for update;
    if not found or v_fuel < 5 then raise exception 'Not enough generator diesel'; end if;
    update public.tenu_generator_fuel
      set seconds_remaining = seconds_remaining - 5,updated_at = now()
      where user_id = v_user_id returning seconds_remaining into v_fuel;
  end if;

  v_coins := case p_game
    when 'cook' then case p_result when 'perfect' then 10 else 0 end
    when 'market' then case p_result when 'perfect' then 40 when 'good' then 20 else 0 end
    when 'school' then case p_result when 'perfect' then 50 when 'good' then 25 else 0 end
    when 'fun' then case p_result when 'perfect' then 5 when 'good' then 2 else 0 end
    when 'water' then case p_result when 'perfect' then 5 when 'good' then 2 else 0 end
    else 0
  end;
  select coalesce(sum(r.coins_awarded),0) into v_hourly_coins
    from public.tenu_minigame_results r
    where r.user_id = v_user_id and r.completed_at >= now() - interval '1 hour';
  v_coins := least(v_coins,greatest(0,100-v_hourly_coins));

  if p_game in ('cook','sleep','fun') then
    v_need_key := case p_game when 'cook' then 'hunger' when 'sleep' then 'energy' else 'fun' end;
    v_restore := case p_game
      when 'cook' then case p_result when 'perfect' then 60 when 'good' then 40 when 'fail' then 15 else 20 end
      when 'sleep' then case p_result when 'perfect' then 70 when 'good' then 45 else 15 end
      when 'fun' then case p_result when 'perfect' then 60 when 'good' then 40 else 15 end
    end;
    v_needs := jsonb_set(
      coalesce(v_needs,'{"energy":100,"hunger":100,"fun":100}'::jsonb),
      array[v_need_key],
      to_jsonb(least(100,coalesce((v_needs->>v_need_key)::numeric,100)+v_restore))
    );
  end if;

  insert into public.tenu_minigame_cooldowns(user_id,game,last_played_at)
    values(v_user_id,p_game,now())
    on conflict (user_id,game) do update set last_played_at = excluded.last_played_at;
  update public.tenu_players set needs = v_needs,updated_at = now()
    where character_id = v_character_id and user_id = v_user_id;

  select a.balance into v_balance from public.tenu_bank_accounts a
    where a.character_id = v_character_id and a.user_id = v_user_id for update;
  if not found then raise exception 'Wallet is unavailable'; end if;
  if v_coins > 0 then
    update public.tenu_bank_accounts
      set balance = balance + v_coins,updated_at = now()
      where character_id = v_character_id and user_id = v_user_id
      returning balance into v_balance;
    insert into public.tenu_game_transactions(character_id,action,amount_delta)
      values(v_character_id,'minigame',v_coins);
  end if;

  insert into public.tenu_minigame_results(user_id,character_id,game,result,coins_awarded)
    values(v_user_id,v_character_id,p_game,p_result,v_coins);
  return jsonb_build_object(
    'coins',v_coins,'needs',v_needs,'balance',v_balance,'fuel_seconds',v_fuel
  );
end;
$$;
revoke execute on function public.complete_tenu_minigame(text,text) from public, anon;
grant execute on function public.complete_tenu_minigame(text,text) to authenticated;
