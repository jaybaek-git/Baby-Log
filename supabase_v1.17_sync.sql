-- Baby-Log v1.17.1 : 빠른 동기화 — "바뀐 거 있어?" 확인용 변경 번호
create table if not exists public.sync_stamp (id int primary key default 1, n bigint not null default 0, at timestamptz not null default now());
insert into public.sync_stamp (id) values (1) on conflict do nothing;
alter table public.sync_stamp enable row level security;
revoke all on public.sync_stamp from anon, authenticated;

create or replace function public._bump_sync() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update sync_stamp set n = n + 1, at = now() where id = 1;
  return null;
end $$;

drop trigger if exists trg_bump_sync on public.events;
create trigger trg_bump_sync after insert or update or delete on public.events
  for each statement execute function public._bump_sync();
drop trigger if exists trg_bump_sync_cfg on public.app_config;
create trigger trg_bump_sync_cfg after insert or update on public.app_config
  for each statement execute function public._bump_sync();

create or replace function public.sync_stamp(p_code text) returns bigint
language plpgsql stable security definer set search_path = public as $$
begin
  perform _chk(p_code);
  return (select n from sync_stamp where id = 1);
end $$;
grant execute on function public.sync_stamp(text) to anon, authenticated;
