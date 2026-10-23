alter table public.tenu_game_transactions
  drop constraint if exists tenu_game_transactions_action_check;

alter table public.tenu_game_transactions
  add constraint tenu_game_transactions_action_check
  check (action in (
    'work','school','market','groceries','outfit','phone','bill','doms_gift',
    'diesel','daily_goal'
  ));

create table if not exists public.tenu_daily_goals (
  character_id text not null references public.tenu_players(character_id) on update cascade on delete cascade,
  action_date date not null default current_date,
  goal text not null check (goal in ('cook','nepa_bill','earn_500')),
  reward bigint not null default 150 check (reward > 0),
  created_at timestamptz not null default now(),
  primary key (character_id,action_date,goal)
);

alter table public.tenu_daily_goals enable row level security;
revoke all on public.tenu_daily_goals from public, anon, authenticated;

create or replace function public.purchase_tenu_diesel()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_character_id text;
  v_balance bigint;
begin
  if (select auth.uid()) is null then raise exception 'Sign in to buy diesel'; end if;

  select p.character_id into v_character_id
    from public.tenu_players p where p.user_id = (select auth.uid());
  if v_character_id is null then raise exception 'Claim a household character first'; end if;

  select a.balance into v_balance from public.tenu_bank_accounts a
    where a.character_id = v_character_id and a.user_id = (select auth.uid()) for update;
  if not found or v_balance < 300 then raise exception 'Insufficient balance'; end if;

  update public.tenu_bank_accounts
    set balance = balance - 300, updated_at = now()
    where character_id = v_character_id;
  insert into public.tenu_game_transactions(character_id,action,amount_delta)
    values(v_character_id,'diesel',-300);
  return v_balance - 300;
end;
$$;
revoke execute on function public.purchase_tenu_diesel() from public, anon;
grant execute on function public.purchase_tenu_diesel() to authenticated;

create or replace function public.claim_tenu_daily_goal(p_goal text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_character_id text;
  v_balance bigint;
  v_earned bigint;
  v_reward constant bigint := 150;
begin
  if p_goal is null or (select auth.uid()) is null
     or p_goal not in ('cook','nepa_bill','earn_500') then
    raise exception 'Invalid daily goal';
  end if;

  select p.character_id into v_character_id
    from public.tenu_players p where p.user_id = (select auth.uid());
  if v_character_id is null then raise exception 'Claim a household character first'; end if;

  if p_goal = 'nepa_bill' and not exists (
    select 1 from public.tenu_game_transactions t
    where t.character_id = v_character_id and t.action = 'bill'
      and t.amount_delta < 0 and t.created_at >= current_date
  ) then
    raise exception 'Pay the NEPA bill before claiming this goal';
  end if;

  if p_goal = 'earn_500' then
    select coalesce(sum(t.amount_delta),0) into v_earned
      from public.tenu_game_transactions t
      where t.character_id = v_character_id and t.action in ('work','school','market')
        and t.amount_delta > 0 and t.created_at >= current_date;
    if v_earned < 500 then raise exception 'Earn 500 coins before claiming this goal'; end if;
  end if;

  select a.balance into v_balance from public.tenu_bank_accounts a
    where a.character_id = v_character_id and a.user_id = (select auth.uid()) for update;
  if not found then raise exception 'Wallet is unavailable'; end if;

  insert into public.tenu_daily_goals(character_id,action_date,goal,reward)
    values(v_character_id,current_date,p_goal,v_reward) on conflict do nothing;
  if not found then return 0; end if;

  update public.tenu_bank_accounts
    set balance = balance + v_reward, updated_at = now()
    where character_id = v_character_id and user_id = (select auth.uid());
  if not found then raise exception 'Wallet is unavailable'; end if;
  insert into public.tenu_game_transactions(character_id,action,amount_delta)
    values(v_character_id,'daily_goal',v_reward);
  return v_reward;
end;
$$;
revoke execute on function public.claim_tenu_daily_goal(text) from public, anon;
grant execute on function public.claim_tenu_daily_goal(text) to authenticated;
