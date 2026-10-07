-- ES: artist-only uploads. Run this ONCE in Supabase > SQL Editor.
-- Safe to re-run. Review the "songs" and storage policies you already have (see notes at the bottom).

-- 1) Artist applications ---------------------------------------------------
create table if not exists public.artist_applications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  email text,
  artist_name text not null,
  contact text not null,
  link text,
  message text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now()
);
alter table public.artist_applications enable row level security;

drop policy if exists "apply: insert own" on public.artist_applications;
create policy "apply: insert own" on public.artist_applications
  for insert to authenticated with check (user_id = auth.uid() and status = 'pending');

drop policy if exists "apply: read own or admin" on public.artist_applications;
create policy "apply: read own or admin" on public.artist_applications
  for select to authenticated using (
    user_id = auth.uid()
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin));

drop policy if exists "apply: resubmit after rejection" on public.artist_applications;
create policy "apply: resubmit after rejection" on public.artist_applications
  for update to authenticated
  using (user_id = auth.uid() and status = 'rejected')
  with check (user_id = auth.uid() and status = 'pending');

drop policy if exists "apply: admin decides" on public.artist_applications;
create policy "apply: admin decides" on public.artist_applications
  for update to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin))
  with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin));

-- 2) Nobody can make themselves admin / artist / premium ------------------------
-- (service role, the SQL editor and your Telegram bot have no auth.uid(), so they still work)
create or replace function public.guard_profile_write() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  if exists (select 1 from public.profiles where id = auth.uid() and is_admin) then return new; end if;
  if tg_op = 'INSERT' then
    new.is_admin := false; new.is_artist := false; new.premium_until := null;
  else
    new.is_admin := old.is_admin; new.is_artist := old.is_artist; new.premium_until := old.premium_until;
  end if;
  return new;
end $$;
drop trigger if exists guard_profile_write on public.profiles;
create trigger guard_profile_write before insert or update on public.profiles
  for each row execute function public.guard_profile_write();

-- 3) Only artists/admins can add songs, always as themselves ---------------------
create or replace function public.guard_song_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare p record;
begin
  if auth.uid() is null then return new; end if;
  select is_admin, is_artist into p from public.profiles where id = auth.uid();
  if not (coalesce(p.is_admin,false) or coalesce(p.is_artist,false)) then
    raise exception 'artist_only';
  end if;
  new.uploader_id := auth.uid();
  return new;
end $$;
drop trigger if exists guard_song_insert on public.songs;
create trigger guard_song_insert before insert on public.songs
  for each row execute function public.guard_song_insert();

-- 4) Artists can delete their own songs ------------------------------------------
drop policy if exists "songs: delete own" on public.songs;
create policy "songs: delete own" on public.songs
  for delete to authenticated using (uploader_id = auth.uid());

-- 5) Storage: only artists upload, only into their own folder (userId/...) ---------
drop policy if exists "artists upload own folder" on storage.objects;
create policy "artists upload own folder" on storage.objects
  for insert to authenticated with check (
    bucket_id = 'songs-audio'
    and (storage.foldername(name))[1] = auth.uid()::text
    and exists (select 1 from public.profiles p where p.id = auth.uid() and (p.is_artist or p.is_admin)));

drop policy if exists "artists delete own files" on storage.objects;
create policy "artists delete own files" on storage.objects
  for delete to authenticated using (
    bucket_id = 'songs-audio' and (storage.foldername(name))[1] = auth.uid()::text);

-- NOTES
-- * Policies are additive. Open Dashboard > Authentication > Policies and DELETE any older, looser
--   policy on "songs" (insert) and on storage.objects (insert for songs-audio) that lets any logged-in user write.
-- * In Storage, set the songs-audio bucket's file size limit to 50 MB (matches the app).
