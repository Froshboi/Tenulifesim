alter table public.tenu_rooms
  add column if not exists wall_color text not null default '#f2e3c6'
    check (wall_color ~ '^#[0-9a-fA-F]{6}$'),
  add column if not exists floor_color text not null default '#dcc28c'
    check (floor_color ~ '^#[0-9a-fA-F]{6}$');

drop function if exists public.save_tenu_customization(text,text,jsonb,text);
create function public.save_tenu_customization(
  p_character_id text,
  p_character_name text,
  p_appearance jsonb,
  p_room_color text,
  p_wall_color text,
  p_floor_color text
) returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_room_id integer;
  v_build numeric;
  v_height numeric;
  v_style text;
  v_color text;
begin
  v_room_id := case p_character_id
    when 'Dee' then 0 when 'Mummy' then 0
    when 'Ukechi' then 1 when 'Doms' then 1
    when 'Chibaby' then 2 when 'MMA' then 2
    when 'Jahsfavour' then 3
    else null
  end;
  if v_room_id is null
     or char_length(btrim(p_character_name)) not between 1 and 24
     or jsonb_typeof(p_appearance) <> 'object' then
    raise exception 'Invalid character customization';
  end if;

  foreach v_color in array array[
    p_appearance->>'shirt', p_appearance->>'skin', p_appearance->>'hair',
    p_room_color, p_wall_color, p_floor_color
  ] loop
    if v_color is null or v_color !~ '^#[0-9a-fA-F]{6}$' then
      raise exception 'Customization colors must be six-digit hex values';
    end if;
  end loop;

  v_style := coalesce(p_appearance->>'hair_style', 'short');
  if v_style not in ('short','afro','bald') then
    raise exception 'Unsupported hairstyle';
  end if;
  begin
    v_build := coalesce((p_appearance->>'body_build')::numeric, 1);
    v_height := coalesce((p_appearance->>'height')::numeric, 1);
  exception when invalid_text_representation then
    raise exception 'Body build and height must be numbers';
  end;
  if v_build not between 0.75 and 1.3 or v_height not between 0.85 and 1.15 then
    raise exception 'Body build or height is outside the allowed range';
  end if;

  update public.tenu_players
    set character_name = btrim(p_character_name),
        appearance = p_appearance,
        updated_at = now()
    where character_id = p_character_id and user_id = (select auth.uid());
  if not found then
    raise exception 'You do not own this character profile';
  end if;

  insert into public.tenu_rooms(room_id,color,wall_color,floor_color,updated_by)
    values(v_room_id,p_room_color,p_wall_color,p_floor_color,(select auth.uid()))
  on conflict (room_id) do update
    set color = excluded.color,
        wall_color = excluded.wall_color,
        floor_color = excluded.floor_color,
        updated_by = excluded.updated_by,
        updated_at = now();
end;
$$;
revoke execute on function public.save_tenu_customization(text,text,jsonb,text,text,text) from public, anon;
grant execute on function public.save_tenu_customization(text,text,jsonb,text,text,text) to authenticated;

drop policy if exists "Players can send chat as their character" on public.tenu_chat;
create policy "Players can send chat as their character" on public.tenu_chat
  for insert to authenticated with check (
    user_id = (select auth.uid()) and exists (
      select 1 from public.tenu_players p
      where p.user_id = (select auth.uid())
        and p.character_id = tenu_chat.character_id
        and p.character_name = tenu_chat.player_name
    )
  );
