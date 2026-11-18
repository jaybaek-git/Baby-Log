-- =====================================================================
--  아기 기록 v1.6 — 30분마다 자동 백업(스냅샷) + 복구
--  · 기록이 바뀌었을 때만 저장, 최근 14일치 보관
--  · 복구 직전 상태도 자동으로 한 번 더 저장 (복구를 되돌릴 수 있게)
-- =====================================================================
create table if not exists public.backups (
  id bigserial primary key,
  taken_at timestamptz not null default now(),
  reason text not null default 'auto',
  n_events int not null,
  hash text not null,
  events jsonb not null,
  config jsonb
);
create index if not exists backups_taken_idx on public.backups (taken_at desc);
alter table public.backups enable row level security;
revoke all on public.backups from anon, authenticated;

create or replace function public._take_backup(p_reason text default 'auto', p_force bool default false)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_ev jsonb; v_hash text; v_last text; v_id bigint;
begin
  select coalesce(jsonb_agg(to_jsonb(e) - 'created_at' order by e.start_at, e.id), '[]'::jsonb) into v_ev from events e;
  v_hash := md5(v_ev::text);
  select hash into v_last from backups order by id desc limit 1;
  if not p_force and v_last is not distinct from v_hash then return null; end if;
  insert into backups (reason, n_events, hash, events, config)
  values (p_reason, jsonb_array_length(v_ev), v_hash, v_ev, (select data from app_config where id = 1))
  returning id into v_id;
  delete from backups where taken_at < now() - interval '14 days' and reason = 'auto';
  return v_id;
end $$;
revoke execute on function public._take_backup(text, bool) from public, anon, authenticated;

create or replace function public.list_backups(p_code text)
returns table (id bigint, taken_at timestamptz, reason text, n_events int)
language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_code);
  return query select b.id, b.taken_at, b.reason, b.n_events from backups b order by b.id desc limit 200;
end $$;

create or replace function public.backup_now(p_code text) returns bigint
language plpgsql security definer set search_path = public as $$
begin perform _chk(p_code); return _take_backup('manual', true); end $$;

create or replace function public.restore_backup(p_code text, p_id bigint) returns int
language plpgsql security definer set search_path = public as $$
declare v_ev jsonb; n int;
begin
  perform _chk(p_code);
  select events into v_ev from backups where id = p_id;
  if v_ev is null then raise exception 'backup not found'; end if;
  perform _take_backup('before-restore', true);
  perform set_config('babylog.skip_also', '1', true);
  delete from events;
  insert into events (id, type, start_at, end_at, value, note, created_by)
  select (r->>'id')::uuid, r->>'type', (r->>'start_at')::timestamptz, nullif(r->>'end_at','')::timestamptz,
         nullif(r->>'value','')::numeric, r->>'note', r->>'created_by'
    from jsonb_array_elements(v_ev) r;
  get diagnostics n = row_count;
  perform set_config('babylog.skip_also', '', true);
  return n;
end $$;

grant execute on function public.list_backups(text), public.backup_now(text), public.restore_backup(text, bigint) to anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'baby-log-backup';
select cron.schedule('baby-log-backup', '*/30 * * * *', 'select public._take_backup()');
select public._take_backup('initial', true);

notify pgrst, 'reload schema';
