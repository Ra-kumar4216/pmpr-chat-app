-- PMPR Chat Supabase schema
-- Run this in Supabase Dashboard -> SQL Editor.

create extension if not exists "pgcrypto";

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  name text not null default 'PMPR User',
  phone text,
  avatar_url text,
  about text default 'Hey there! I am using PMPR.',
  username text unique,
  is_online boolean not null default false,
  last_seen timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  kind text not null default 'direct' check (kind in ('direct', 'group')),
  title text,
  avatar_url text,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.conversation_members (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('member', 'admin', 'co_admin')),
  joined_at timestamptz not null default now(),
  primary key (conversation_id, user_id)
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  type text not null default 'text' check (type in ('text', 'image', 'video', 'audio', 'document', 'system')),
  body text,
  media_path text,
  reply_to_id uuid references public.messages(id) on delete set null,
  edited_at timestamptz,
  deleted_for_everyone boolean not null default false,
  pinned boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.message_reactions (
  message_id uuid not null references public.messages(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  emoji text not null,
  created_at timestamptz not null default now(),
  primary key (message_id, user_id, emoji)
);

create index if not exists messages_conversation_created_idx on public.messages(conversation_id, created_at desc);
create index if not exists conversation_members_user_idx on public.conversation_members(user_id);

alter table public.profiles enable row level security;
alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages enable row level security;
alter table public.message_reactions enable row level security;

create or replace function public.is_conversation_member(target_conversation_id uuid, target_user_id uuid default auth.uid())
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.conversation_members
    where conversation_id = target_conversation_id and user_id = target_user_id
  );
$$;

drop policy if exists "profiles are viewable by authenticated users" on public.profiles;
create policy "profiles are viewable by authenticated users" on public.profiles for select to authenticated using (true);
drop policy if exists "users can insert own profile" on public.profiles;
create policy "users can insert own profile" on public.profiles for insert to authenticated with check (id = auth.uid());
drop policy if exists "users can update own profile" on public.profiles;
create policy "users can update own profile" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "members can view conversations" on public.conversations;
create policy "members can view conversations" on public.conversations for select to authenticated using (public.is_conversation_member(id));
drop policy if exists "authenticated users can create conversations" on public.conversations;
create policy "authenticated users can create conversations" on public.conversations for insert to authenticated with check (created_by = auth.uid());

drop policy if exists "members can view membership" on public.conversation_members;
create policy "members can view membership" on public.conversation_members for select to authenticated using (user_id = auth.uid() or public.is_conversation_member(conversation_id));
drop policy if exists "conversation creators can add members" on public.conversation_members;
create policy "conversation creators can add members" on public.conversation_members for insert to authenticated with check (exists (select 1 from public.conversations c where c.id = conversation_id and c.created_by = auth.uid()) or user_id = auth.uid());

drop policy if exists "members can view messages" on public.messages;
create policy "members can view messages" on public.messages for select to authenticated using (public.is_conversation_member(conversation_id));
drop policy if exists "members can send messages" on public.messages;
create policy "members can send messages" on public.messages for insert to authenticated with check (sender_id = auth.uid() and public.is_conversation_member(conversation_id));
drop policy if exists "senders can edit messages" on public.messages;
create policy "senders can edit messages" on public.messages for update to authenticated using (sender_id = auth.uid()) with check (sender_id = auth.uid());
drop policy if exists "senders can delete messages" on public.messages;
create policy "senders can delete messages" on public.messages for delete to authenticated using (sender_id = auth.uid());

drop policy if exists "members can view reactions" on public.message_reactions;
create policy "members can view reactions" on public.message_reactions for select to authenticated using (exists (select 1 from public.messages msg where msg.id = message_id and public.is_conversation_member(msg.conversation_id)));
drop policy if exists "users manage own reactions" on public.message_reactions;
create policy "users manage own reactions" on public.message_reactions for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

insert into storage.buckets (id, name, public) values ('chat-media', 'chat-media', false) on conflict (id) do nothing;
drop policy if exists "authenticated users upload chat media" on storage.objects;
create policy "authenticated users upload chat media" on storage.objects for insert to authenticated with check (bucket_id = 'chat-media' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "authenticated users read chat media" on storage.objects;
create policy "authenticated users read chat media" on storage.objects for select to authenticated using (bucket_id = 'chat-media');

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, name, avatar_url)
  values (new.id, coalesce(new.email, ''), coalesce(new.raw_user_meta_data->>'name', 'PMPR User'), new.raw_user_meta_data->>'avatar_url')
  on conflict (id) do update set email = excluded.email;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();

-- Enable realtime for chat tables in the Supabase dashboard if not already enabled.
