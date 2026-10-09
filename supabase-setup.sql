-- Smart Bin v2 (with sign-in). Run once in Supabase > SQL Editor.
-- If you ran the earlier version, this resets its tables (test data is lost).
drop function if exists submit_disposal(uuid,text,text,text[],boolean);
drop function if exists get_balance(uuid);
drop function if exists redeem_reward(uuid,text);
drop function if exists get_my_redemptions(uuid);
drop function if exists get_leaderboard();
drop policy if exists "anon can upload proofs" on storage.objects;
drop table if exists redemptions, disposals, profiles;

create table profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  nickname text not null,
  points int not null default 0,     -- spendable balance
  lifetime int not null default 0,   -- total ever earned (leaderboard)
  created_at timestamptz default now()
);
create table disposals(
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  bin_id text not null,
  photos text[] not null,
  ai_ok boolean not null,            -- false = litter check unavailable, review the photos
  points int not null,
  created_at timestamptz default now()
);
create table redemptions(
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  reward text not null,
  cost int not null,
  code text not null,
  status text not null default 'pending',  -- staff set to 'redeemed' when handed over
  created_at timestamptz default now()
);
-- No policies: the public key cannot touch the tables directly.
alter table profiles enable row level security;
alter table disposals enable row level security;
alter table redemptions enable row level security;

-- Private photo bucket. Signed-in users can upload only into their own folder.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('proofs','proofs',false,2097152,array['image/jpeg']) on conflict(id) do nothing;
create policy "users upload own proofs" on storage.objects for insert to authenticated
  with check(bucket_id='proofs' and (storage.foldername(name))[1]=auth.uid()::text);

create or replace function get_profile() returns table(nick text,pts int)
language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in.'; end if;
  insert into profiles(id,nickname) values(auth.uid(),'Eco-'||floor(1000+random()*9000)::int) on conflict do nothing;
  return query select p.nickname,p.points from profiles p where p.id=auth.uid();
end $$;

create or replace function set_nickname(p_name text) returns void
language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in.'; end if;
  insert into profiles(id,nickname) values(auth.uid(),left(trim(p_name),20))
    on conflict(id) do update set nickname=excluded.nickname;
end $$;

-- Points are awarded by the server, never by the browser.
create or replace function submit_disposal(p_bin text,p_photos text[],p_ai_ok boolean) returns json
language plpgsql security definer set search_path=public as $$
declare u uuid:=auth.uid(); pts int:=case when p_ai_ok then 10 else 5 end; bal int; ph text;
begin
  if u is null then raise exception 'Please sign in.'; end if;
  if p_bin !~ '^[A-Za-z0-9_-]{2,20}$' then raise exception 'Invalid bin code.'; end if;
  if coalesce(array_length(p_photos,1),0)<>2 then raise exception 'Two photos are required.'; end if;
  foreach ph in array p_photos loop
    if ph not like u::text||'/%' then raise exception 'Invalid photo.'; end if;
  end loop;
  if exists(select 1 from disposals where user_id=u and created_at>now()-interval '60 seconds')
    then raise exception 'Please wait a minute before your next item.'; end if;
  if (select count(*) from disposals where user_id=u and created_at>now()-interval '1 day')>=20
    then raise exception 'Daily limit reached. Come back tomorrow.'; end if;
  insert into profiles(id,nickname) values(u,'Eco-'||floor(1000+random()*9000)::int) on conflict do nothing;
  insert into disposals(user_id,bin_id,photos,ai_ok,points) values(u,upper(p_bin),p_photos,p_ai_ok,pts);
  update profiles set points=points+pts,lifetime=lifetime+pts where id=u returning points into bal;
  return json_build_object('awarded',pts,'balance',bal);
end $$;

create or replace function get_leaderboard() returns table(nickname text,lifetime int,me boolean)
language sql security definer set search_path=public as $$
  select p.nickname,p.lifetime,coalesce(p.id=auth.uid(),false) from profiles p
  where p.lifetime>0 order by p.lifetime desc limit 20 $$;

-- Garden Yoghurt: 1 cup for 2,450 points. Rewards unlock from 2,000 points.
create or replace function redeem_reward(p_reward text) returns text
language plpgsql security definer set search_path=public as $$
declare u uuid:=auth.uid(); cost int:=2450; bal int; c text;
begin
  if u is null then raise exception 'Please sign in.'; end if;
  if p_reward<>'garden-yoghurt' then raise exception 'Unknown reward.'; end if;
  select p.points into bal from profiles p where p.id=u for update;
  if coalesce(bal,0)<2000 then raise exception 'You need at least 2,000 points to redeem.'; end if;
  if bal<cost then raise exception 'Garden Yoghurt costs 2,450 points.'; end if;
  c:='GY-'||upper(substr(md5(random()::text||u::text),1,6));
  update profiles set points=points-cost where id=u;
  insert into redemptions(user_id,reward,cost,code) values(u,p_reward,cost,c);
  return c;
end $$;

create or replace function get_my_redemptions() returns table(code text,status text,created_at timestamptz)
language sql security definer set search_path=public as $$
  select r.code,r.status,r.created_at from redemptions r where r.user_id=auth.uid() order by r.created_at desc limit 10 $$;

-- Only the leaderboard is public; everything else needs a signed-in user.
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function get_leaderboard() to anon, authenticated;
grant execute on function get_profile(), set_nickname(text), submit_disposal(text,text[],boolean),
  redeem_reward(text), get_my_redemptions() to authenticated;
