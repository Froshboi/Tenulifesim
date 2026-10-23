alter table public.tenu_game_transactions
  drop constraint if exists tenu_game_transactions_action_check;
alter table public.tenu_game_transactions
  add constraint tenu_game_transactions_action_check
  check (action in (
    'work','school','market','groceries','outfit','phone','bill','doms_gift',
    'diesel','daily_goal','bolt','uber','keke','flight_abuja',
    'flight_port_harcourt','flight_enugu','build_item','sell_item',
    'minigame','daily_gift','weekly_goal'
  ));

create table if not exists public.tenu_daily_checkins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  last_claimed_on date,
  streak integer not null default 0 check (streak >= 0),
  updated_at timestamptz not null default now()
);

create table if not exists public.tenu_daily_event_counts (
  user_id uuid not null references auth.users(id) on delete cascade,
  event_date date not null default current_date,
  events_completed integer not null default 0 check (events_completed >= 0),
  primary key (user_id,event_date)
);

create table if not exists public.tenu_weekly_goal_claims (
  week_start date primary key,
  claimed_by uuid not null references auth.users(id),
  reward bigint not null check (reward > 0),
  created_at timestamptz not null default now()
);

alter table public.tenu_daily_checkins enable row level security;
alter table public.tenu_daily_event_counts enable row level security;
alter table public.tenu_weekly_goal_claims enable row level security;
revoke all on public.tenu_daily_checkins from public, anon, authenticated;
revoke all on public.tenu_daily_event_counts from public, anon, authenticated;
revoke all on public.tenu_weekly_goal_claims from public, anon, authenticated;

create or replace function public.track_tenu_daily_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
begin
  if new.amount_delta <= 0 or new.action <> 'work' then
    return new;
  end if;
  select a.user_id into v_user_id
    from public.tenu_bank_accounts a
    where a.character_id = new.character_id;
  if v_user_id is not null then
    insert into public.tenu_daily_event_counts as current_count(user_id,event_date,events_completed)
      values(v_user_id,(now() at time zone 'Africa/Lagos')::date,1)
      on conflict (user_id,event_date) do update
      set events_completed = current_count.events_completed + 1;
  end if;
  return new;
end;
$$;
revoke execute on function public.track_tenu_daily_event() from public, anon, authenticated;
drop trigger if exists tenu_track_daily_events on public.tenu_game_transactions;
create trigger tenu_track_daily_events
  after insert on public.tenu_game_transactions
  for each row execute function public.track_tenu_daily_event();

create or replace function public.track_tenu_minigame_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.tenu_daily_event_counts as current_count(user_id,event_date,events_completed)
    values(new.user_id,(now() at time zone 'Africa/Lagos')::date,1)
    on conflict (user_id,event_date) do update
    set events_completed = current_count.events_completed + 1;
  return new;
end;
$$;
revoke execute on function public.track_tenu_minigame_event() from public, anon, authenticated;
drop trigger if exists tenu_track_minigame_events on public.tenu_minigame_results;
create trigger tenu_track_minigame_events
  after insert on public.tenu_minigame_results
  for each row execute function public.track_tenu_minigame_event();

create or replace function public.get_tenu_engagement_state()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_streak integer := 0;
  v_last_claimed date;
  v_events integer := 0;
  v_today date := (now() at time zone 'Africa/Lagos')::date;
  v_week_start date := date_trunc('week',now() at time zone 'Africa/Lagos')::date;
  v_weekly_earned bigint := 0;
  v_weekly_target constant bigint := 5000;
  v_weekly_reward constant bigint := 500;
  v_weekly_claimed boolean := false;
begin
  if v_user_id is null then raise exception 'Sign in to view daily rewards'; end if;
  if not exists (select 1 from public.tenu_players p where p.user_id = v_user_id) then
    raise exception 'Choose a household character first';
  end if;

  select c.streak,c.last_claimed_on into v_streak,v_last_claimed
    from public.tenu_daily_checkins c where c.user_id = v_user_id;
  select e.events_completed into v_events
    from public.tenu_daily_event_counts e
    where e.user_id = v_user_id and e.event_date = v_today;
  select coalesce(sum(t.amount_delta),0) into v_weekly_earned
    from public.tenu_game_transactions t
    join public.tenu_players p on p.character_id = t.character_id
    where t.action in ('work','school','market','minigame')
      and t.amount_delta > 0
      and t.created_at >= (v_week_start::timestamp at time zone 'Africa/Lagos');
  select exists (
    select 1 from public.tenu_weekly_goal_claims c where c.week_start = v_week_start
  ) into v_weekly_claimed;

  return jsonb_build_object(
    'streak',coalesce(v_streak,0),
    'daily_claimed',v_last_claimed = v_today,
    'daily_reward',case
      when v_last_claimed = v_today - 1 then least(200,50+greatest(0,coalesce(v_streak,0))*10)
      else 50
    end,
    'events_completed',coalesce(v_events,0),
    'weekly_earned',v_weekly_earned,
    'weekly_target',v_weekly_target,
    'weekly_reward',v_weekly_reward,
    'weekly_claimed',v_weekly_claimed,
    'week_start',v_week_start
  );
end;
$$;
revoke execute on function public.get_tenu_engagement_state() from public, anon;
grant execute on function public.get_tenu_engagement_state() to authenticated;

create or replace function public.claim_tenu_daily_reward()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_character_id text;
  v_balance bigint;
  v_streak integer;
  v_last_claimed date;
  v_reward bigint;
  v_today date := (now() at time zone 'Africa/Lagos')::date;
begin
  if v_user_id is null then raise exception 'Sign in to claim your daily gift'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text,0));
  select p.character_id into v_character_id
    from public.tenu_players p where p.user_id = v_user_id;
  if v_character_id is null then raise exception 'Choose a household character first'; end if;

  insert into public.tenu_daily_checkins(user_id)
    values(v_user_id) on conflict (user_id) do nothing;
  select c.streak,c.last_claimed_on into v_streak,v_last_claimed
    from public.tenu_daily_checkins c where c.user_id = v_user_id for update;
  if v_last_claimed = v_today then
    return jsonb_build_object('claimed',true,'streak',v_streak,'reward',0);
  end if;

  v_streak := case when v_last_claimed = v_today - 1 then v_streak + 1 else 1 end;
  v_reward := least(200,50+(v_streak-1)*10);
  select a.balance into v_balance from public.tenu_bank_accounts a
    where a.character_id = v_character_id and a.user_id = v_user_id for update;
  if not found then raise exception 'Wallet is unavailable'; end if;

  update public.tenu_bank_accounts
    set balance = balance + v_reward,updated_at = now()
    where character_id = v_character_id and user_id = v_user_id
    returning balance into v_balance;
  update public.tenu_daily_checkins
    set last_claimed_on = v_today,streak = v_streak,updated_at = now()
    where user_id = v_user_id;
  insert into public.tenu_game_transactions(character_id,action,amount_delta)
    values(v_character_id,'daily_gift',v_reward);

  return jsonb_build_object(
    'claimed',true,'streak',v_streak,'reward',v_reward,'balance',v_balance
  );
end;
$$;
revoke execute on function public.claim_tenu_daily_reward() from public, anon;
grant execute on function public.claim_tenu_daily_reward() to authenticated;

create or replace function public.claim_tenu_weekly_goal()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_character_id text;
  v_week_start date := date_trunc('week',now() at time zone 'Africa/Lagos')::date;
  v_earned bigint;
  v_balance bigint;
  v_target constant bigint := 5000;
  v_reward constant bigint := 500;
begin
  if v_user_id is null then raise exception 'Sign in to claim the family goal'; end if;
  perform pg_advisory_xact_lock(778899011);
  select p.character_id into v_character_id
    from public.tenu_players p where p.user_id = v_user_id;
  if v_character_id is null then raise exception 'Choose a household character first'; end if;

  select coalesce(sum(t.amount_delta),0) into v_earned
    from public.tenu_game_transactions t
    where t.action in ('work','school','market','minigame')
      and t.amount_delta > 0
      and t.created_at >= (v_week_start::timestamp at time zone 'Africa/Lagos');
  if v_earned < v_target then raise exception 'The family has not reached the weekly coin goal yet'; end if;

  insert into public.tenu_weekly_goal_claims(week_start,claimed_by,reward)
    values(v_week_start,v_user_id,v_reward) on conflict (week_start) do nothing;
  if not found then
    return jsonb_build_object('claimed',true,'earned',v_earned,'target',v_target,'reward',0);
  end if;

  select a.balance into v_balance from public.tenu_bank_accounts a
    where a.character_id = v_character_id and a.user_id = v_user_id for update;
  if not found then raise exception 'Wallet is unavailable'; end if;
  update public.tenu_bank_accounts
    set balance = balance + v_reward,updated_at = now()
    where character_id = v_character_id and user_id = v_user_id
    returning balance into v_balance;
  insert into public.tenu_game_transactions(character_id,action,amount_delta)
    values(v_character_id,'weekly_goal',v_reward);
  return jsonb_build_object(
    'claimed',true,'earned',v_earned,'target',v_target,'reward',v_reward,'balance',v_balance
  );
end;
$$;
revoke execute on function public.claim_tenu_weekly_goal() from public, anon;
grant execute on function public.claim_tenu_weekly_goal() to authenticated;
