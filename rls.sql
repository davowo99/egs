-- ES Ethiopian Songs: Supabase security policies
-- Run in Supabase > SQL Editor. READ the comments first; adjust names if your schema differs.
-- Assumes: public.profiles(id uuid pk = auth.users.id, email, premium_until timestamptz, is_admin bool)
--          public.songs(id, title, artist_name, audio_url, cover_url, lyrics, worshiper, uploader_id uuid, status text, created_at)

-- 0. Helper: is the current user an admin? (SECURITY DEFINER avoids policy recursion)
create or replace function public.is_admin() returns boolean
language sql security definer set search_path = public stable as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;

alter table public.profiles enable row level security;
alter table public.songs    enable row level security;

-- 1. PROFILES
drop policy if exists "profiles read own or admin" on public.profiles;
create policy "profiles read own or admin" on public.profiles
  for select using (id = auth.uid() or public.is_admin());

-- Users must NOT be able to update their own profile at all (premium_until / is_admin live here).
-- Only admins can update profiles (used by "Grant premium").
drop policy if exists "profiles admin update" on public.profiles;
create policy "profiles admin update" on public.profiles
  for update using (public.is_admin()) with check (public.is_admin());

-- Belt and braces: even an admin's client can't flip is_admin through the API.
create or replace function public.protect_admin_flag() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.is_admin is distinct from old.is_admin and auth.uid() is not null then
    raise exception 'is_admin can only be changed from the SQL editor';
  end if;
  return new;
end $$;
drop trigger if exists trg_protect_admin on public.profiles;
create trigger trg_protect_admin before update on public.profiles
  for each row execute function public.protect_admin_flag();

-- No client inserts/deletes on profiles: they should come from your signup trigger.
-- (If you currently insert profiles from the app, remove this comment and add an insert policy: with check (id = auth.uid() and is_admin = false and premium_until is null))

-- 2. SONGS
drop policy if exists "songs read approved or own or admin" on public.songs;
create policy "songs read approved or own or admin" on public.songs
  for select using (status = 'approved' or uploader_id = auth.uid() or public.is_admin());

-- Normal users can only insert PENDING songs for themselves. Only admins may insert 'approved'
-- (your bulk upload inserts status = 'approved').
drop policy if exists "songs insert" on public.songs;
create policy "songs insert" on public.songs
  for insert with check (
    auth.uid() is not null and uploader_id = auth.uid()
    and (status = 'pending' or public.is_admin())
  );

drop policy if exists "songs admin update" on public.songs;
create policy "songs admin update" on public.songs
  for update using (public.is_admin()) with check (public.is_admin());

drop policy if exists "songs admin delete" on public.songs;
create policy "songs admin delete" on public.songs
  for delete using (public.is_admin());

-- NOTE: your app's single-song upload inserts without a status. Make sure the column default is 'pending':
alter table public.songs alter column status set default 'pending';

-- 3. STORAGE (bucket songs-audio)
-- Reads stay public (audio URLs are public). Restrict who can WRITE/DELETE.
drop policy if exists "audio upload signed-in" on storage.objects;
create policy "audio upload signed-in" on storage.objects
  for insert with check (bucket_id = 'songs-audio' and auth.uid() is not null);

drop policy if exists "audio delete admin" on storage.objects;
create policy "audio delete admin" on storage.objects
  for delete using (bucket_id = 'songs-audio' and public.is_admin());

-- 4. QUICK TEST (run as a normal user in the app's console, each should FAIL):
--   await supa.from('profiles').update({premium_until:'2099-01-01'}).eq('id', S.user.id)
--   await supa.from('profiles').update({is_admin:true}).eq('id', S.user.id)
--   await supa.from('songs').insert({title:'x',audio_url:'x',uploader_id:S.user.id,status:'approved'})

-- 5. PER-ACCOUNT DOWNLOAD LIMIT (free users: 10 songs per account, any device)
create table if not exists public.downloads (
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  song_id    text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, song_id)
);
alter table public.downloads enable row level security;

drop policy if exists "downloads read own" on public.downloads;
create policy "downloads read own" on public.downloads
  for select using (user_id = auth.uid());

drop policy if exists "downloads insert own" on public.downloads;
create policy "downloads insert own" on public.downloads
  for insert with check (user_id = auth.uid());

drop policy if exists "downloads delete own" on public.downloads;
create policy "downloads delete own" on public.downloads
  for delete using (user_id = auth.uid());

-- Server-side limit: the app cannot bypass this by clearing its local storage.
create or replace function public.enforce_download_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- re-downloading a song already counted is always fine
  if exists (select 1 from public.downloads where user_id = new.user_id and song_id = new.song_id) then
    return new;
  end if;
  -- premium users are unlimited
  if coalesce((select premium_until > now() from public.profiles where id = new.user_id), false) then
    return new;
  end if;
  if (select count(*) from public.downloads where user_id = new.user_id) >= 10 then
    raise exception 'download_limit';
  end if;
  return new;
end $$;
drop trigger if exists trg_download_limit on public.downloads;
create trigger trg_download_limit before insert on public.downloads
  for each row execute function public.enforce_download_limit();
