-- WXFC 축구회 시스템 - Supabase SQL Editor에 전체 복사·붙여넣기 후 Run (한 번만)
create extension if not exists pgcrypto with schema extensions;

create table if not exists members(
  id bigint generated always as identity primary key,
  name text unique not null, pw text not null,
  role text not null default '회원', position text not null default '',
  approved boolean not null default false, created_at timestamptz default now());
create table if not exists sessions(
  token uuid primary key default gen_random_uuid(),
  member_id bigint references members(id) on delete cascade, created_at timestamptz default now());
create table if not exists pays(
  id bigint generated always as identity primary key,
  type text, title text, category text, amount numeric, reason text,
  receipts jsonb default '[]', proof jsonb default '[]', status text,
  applicant_id bigint, applicant text, reject_reason text default '',
  history jsonb default '[]', created_at timestamptz default now(), paid_at timestamptz);
create table if not exists meets(
  id bigint generated always as identity primary key,
  title text, mdate date, agenda text, files jsonb default '[]',
  minutes text default '', mfiles jsonb default '[]', status text, skip_vice boolean default false,
  by_id bigint, by_name text, history jsonb default '[]', created_at timestamptz default now());
create table if not exists notis(
  id bigint generated always as identity primary key,
  to_id bigint references members(id) on delete cascade,
  title text, body text, link text, read boolean default false, created_at timestamptz default now());
create table if not exists config(k text primary key, v jsonb);
-- 공지 (여러 개, 📌 고정, 게시 종료일)
create table if not exists notices(
  id bigint generated always as identity primary key,
  title text, body text default '', pinned boolean default false, until date,
  by_name text, created_at timestamptz default now(), updated_at timestamptz);
alter table notices enable row level security;
-- 예전 홈 공지(글 하나)를 첫 공지로 옮김 (한 번만)
insert into notices(title, body)
  select left(split_part(trim(v->>'text'), E'\n', 1), 40), trim(v->>'text') from config
  where k='notice' and coalesce(trim(v->>'text'),'') <> '' and not exists(select 1 from notices);
delete from config where k='notice';
-- 공지 종류: notice(일반) · signup(참가 신청) · election(임원 선거)
alter table notices add column if not exists kind text default 'notice';
alter table notices add column if not exists memo_label text;
alter table notices add column if not exists signup_until timestamptz;
alter table notices add column if not exists closed boolean default false;
alter table notices add column if not exists election_id bigint;
-- 참가 신청 (接龙). member_id 없음 = 운영진 대리 등록
create table if not exists signups(
  id bigint generated always as identity primary key,
  notice_id bigint references notices(id) on delete cascade,
  member_id bigint references members(id) on delete set null,
  name text not null, memo text default '', by_name text, created_at timestamptz default now());
create unique index if not exists signups_one on signups(notice_id, member_id) where member_id is not null;
alter table signups enable row level security;
-- 임원 선거: 추천(rec) → 후보 확정 → 익명 투표(vote) → 결과 (동점이면 재투표, round 증가)
create table if not exists elections(
  id bigint generated always as identity primary key,
  title text, positions text[] default array['회장','부회장','감독'],
  rec_until timestamptz, vote_until timestamptz, phase text default 'rec', round int default 0,
  apply_on date, applied boolean default false, created_at timestamptz default now());
create table if not exists nominations(
  id bigint generated always as identity primary key,
  election_id bigint references elections(id) on delete cascade,
  member_id bigint references members(id) on delete cascade,
  position text, candidate_id bigint references members(id) on delete cascade,
  reason text default '', named boolean default false, created_at timestamptz default now(),
  unique(election_id, member_id, position));
create table if not exists candidates(
  election_id bigint references elections(id) on delete cascade, round int, position text,
  candidate_id bigint references members(id) on delete cascade,
  primary key(election_id, round, position, candidate_id));
-- 익명 투표: 표는 개인 기록 없이 '집계 숫자'만 올림 (누가 무엇을 골랐는지 저장하지 않음)
create table if not exists tallies(
  election_id bigint references elections(id) on delete cascade, round int, position text, choice text, n int default 0,
  primary key(election_id, round, position, choice));
-- 투표 여부만 기록 (중복 투표 방지). 무엇을 골랐는지는 없음
create table if not exists voted(
  election_id bigint references elections(id) on delete cascade, round int,
  member_id bigint references members(id) on delete cascade,
  primary key(election_id, round, member_id));
alter table elections enable row level security;
alter table nominations enable row level security;
alter table candidates enable row level security;
alter table tallies enable row level security;
alter table voted enable row level security;
create table if not exists reqs(
  id bigint generated always as identity primary key,
  by_id bigint, by_name text, title text, body text, status text default '접수',
  reply text default '', replied_by text default '', created_at timestamptz default now(), updated_at timestamptz);
alter table pays add column if not exists skip_vice boolean default false;
create table if not exists polls(
  id bigint generated always as identity primary key,
  meet_id bigint references meets(id) on delete cascade, title text, options jsonb,
  closed boolean default false, deadline timestamptz, by_id bigint, by_name text, created_at timestamptz default now());
alter table members add column if not exists fail_count int default 0;
alter table members add column if not exists lock_until timestamptz;
alter table members add column if not exists dues_exempt boolean default false;
alter table members add column if not exists dues_note text default '';
alter table members add column if not exists video_admin boolean default false;
alter table members add column if not exists photo text;  -- 프로필 사진 주소 (없으면 축구회 로고)  -- 영상 관리 권한 (회장이 지정)
create table if not exists dues_pause(
  id bigint generated always as identity primary key, member_id bigint references members(id) on delete cascade,
  from_ym text, to_ym text, reason text default '', by_name text, created_at timestamptz default now());
create table if not exists dues(
  member_id bigint references members(id) on delete cascade, ym text, status text, amount numeric,
  paid_at timestamptz, by_name text, pay_id bigint, primary key(member_id, ym));
create table if not exists matches(
  id bigint generated always as identity primary key,
  title text, opponent text default '', starts_at timestamptz, venue text default '', address text default '', map_url text default '',
  format text default '11인제', need int default 11, memo text default '', deadline timestamptz,
  by_id bigint, by_name text, created_at timestamptz default now());
create table if not exists attends(
  match_id bigint references matches(id) on delete cascade, member_id bigint references members(id) on delete cascade,
  member_name text, status text, at timestamptz default now(), primary key(match_id, member_id));
create table if not exists videos(
  id bigint generated always as identity primary key,
  doc_code text unique not null, sign text, link text, shot_at timestamptz, duration text default '', title text default '',
  match_id bigint references matches(id) on delete set null, hidden boolean default false, created_at timestamptz default now());
alter table videos add column if not exists mp4 text;
alter table videos add column if not exists mp4_until timestamptz;
alter table videos add column if not exists link_manual boolean default false;  -- 영상 관리자가 직접 연결/해제한 영상은 자동 연결 안 함
alter table videos add column if not exists missing int default 0;      -- XbotGo 목록에 연속으로 안 보인 횟수
alter table videos add column if not exists gone boolean default false;  -- 2번 연속 안 보이면 XbotGo에서 지운 것으로 보고 자동 숨김 (다시 보이면 복구)
create table if not exists votes(
  poll_id bigint references polls(id) on delete cascade, member_id bigint references members(id) on delete cascade,
  member_name text, choice int, at timestamptz default now(), primary key(poll_id, member_id));
update pays set status='회장결재' where status='승인대기';
update pays set status='지급대기' where status='승인';

-- 테이블 직접 접근 금지 (모든 처리는 아래 함수로만)
alter table members enable row level security;
alter table sessions enable row level security;
alter table pays enable row level security;
alter table meets enable row level security;
alter table notis enable row level security;
alter table config enable row level security;
alter table reqs enable row level security;
alter table polls enable row level security;
alter table votes enable row level security;
alter table videos enable row level security;
alter table dues enable row level security;
alter table dues_pause enable row level security;
alter table matches enable row level security;
alter table attends enable row level security;

create or replace function _hist(m members, a text, c text) returns jsonb language sql stable as $$
  select jsonb_build_array(jsonb_build_object('who',m.name,'role',m.role,'act',a,'comment',coalesce(c,''),'at',now())) $$;
create or replace function _ids(roles text[]) returns bigint[] language sql stable security definer set search_path=public as $$
  select coalesce(array_agg(id),'{}') from members where approved and (roles is null or role = any(roles)) $$;
create or replace function _notify(ids bigint[], t text, b text, l text) returns void language sql security definer set search_path=public as $$
  insert into notis(to_id,title,body,link) select distinct x,t,b,l from unnest(ids) x where x is not null $$;
create or replace function _err(m text) returns jsonb language sql immutable as $$ select jsonb_build_object('err',m) $$;

-- 회원의 그 달 회비 상태: 가입 전 달은 해당없음, 연납 > 그 달 기록(납부·면제) > 면제 대상 > 일시중단 > 미납
create or replace function _due(mid bigint, p_ym text) returns text language sql stable security definer set search_path=public as $$
  select case
    when (select to_char(created_at at time zone 'Asia/Shanghai','YYYY-MM') from members where id=mid) > p_ym then '해당없음'
    when exists(select 1 from dues d where d.member_id=mid and d.ym=left(p_ym,4) and d.status='연납') then '연납'
    when exists(select 1 from dues d where d.member_id=mid and d.ym=p_ym) then (select d.status from dues d where d.member_id=mid and d.ym=p_ym)
    when coalesce((select dues_exempt from members where id=mid), false) then '면제대상'
    when exists(select 1 from dues_pause z where z.member_id=mid and p_ym between z.from_ym and z.to_ym) then '일시중단'
    else '미납' end $$;

-- XbotGo 자동 연동: GitHub 자동 작업이 '동기화 키'로만 호출 (키 원문은 GitHub 금고에만, 여기엔 해시만 저장)
-- 경기 영상 자동 연결: 경기 시작 ~ 경기 종료 후 1일 안에 찍힌 영상 → 그 경기 (경기 전 영상은 연결 안 함)
-- (경기 종료 시각은 따로 없어서 '시작 + 3시간'으로 봄. 여러 경기에 걸리면 영상 직전에 시작한 경기)
create or replace function _vlink() returns void language sql security definer set search_path=public as $$
  update videos v set match_id = (select m.id from matches m
      where v.shot_at between m.starts_at and m.starts_at + interval '3 hours' + interval '1 day'
      order by m.starts_at desc limit 1)
    where v.match_id is null and not coalesce(v.link_manual, false) and v.shot_at is not null;
$$;
revoke all on function _vlink() from public, anon, authenticated;

create or replace function video_sync(p_key text, p_items jsonb default '[]', p_status jsonb default null) returns jsonb
language plpgsql security definer set search_path=public, extensions as $$
declare h text; it jsonb; n int := 0; vid bigint; seen jsonb; n_gone int := 0;
begin
  select v->>'hash' into h from config where k='sync_key';
  if h is null or length(coalesce(p_key,'')) < 24 or encode(digest(p_key,'sha256'),'hex') <> h then
    return jsonb_build_object('err','동기화 키가 맞지 않습니다'); end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then return jsonb_build_object('err','잘못된 요청'); end if;
  for it in select * from jsonb_array_elements(p_items) loop
    if coalesce(it->>'doc_code','') !~ '^[A-Za-z0-9_-]{8,64}$' then continue; end if;
    if coalesce(it->>'link','') <> '' and (it->>'link' !~ '^https://[^[:space:]"<>]+$' or length(it->>'link') > 600) then continue; end if;
    if coalesce(it->>'mp4','') <> '' and (it->>'mp4' !~ '^https://[^[:space:]"<>]+$' or length(it->>'mp4') > 1200) then continue; end if;
    insert into videos(doc_code, sign, link, shot_at, duration, title, mp4, mp4_until)
      values(it->>'doc_code', left(it->>'sign',300), it->>'link', nullif(it->>'shot_at','')::timestamptz, left(coalesce(it->>'duration',''),20), left(coalesce(it->>'title',''),80),
        nullif(it->>'mp4',''), nullif(it->>'mp4_until','')::timestamptz)
      on conflict(doc_code) do update set sign = coalesce(excluded.sign, videos.sign), link = coalesce(excluded.link, videos.link),
        mp4 = coalesce(excluded.mp4, videos.mp4), mp4_until = coalesce(excluded.mp4_until, videos.mp4_until),
        shot_at = coalesce(excluded.shot_at, videos.shot_at), duration = coalesce(nullif(excluded.duration,''), videos.duration)
      returning id into vid;
    n := n + 1;
  end loop;
  -- XbotGo에서 지운 영상 정리: 전체 목록을 끝까지 받았을 때만, 2번 연속 안 보이면 숨김 (일시 오류로 잘못 숨기는 것 방지)
  seen := p_status->'seen';
  if p_status is not null then p_status := p_status - 'seen'; end if;
  if jsonb_typeof(seen) = 'array' and jsonb_array_length(seen) > 0 and coalesce((p_status->>'complete')::boolean, false) then
    update videos set missing = 0, gone = false where doc_code in (select jsonb_array_elements_text(seen)) and (missing <> 0 or gone);
    update videos set missing = missing + 1 where doc_code not in (select jsonb_array_elements_text(seen));
    update videos set gone = true where missing >= 2 and not gone;
    get diagnostics n_gone = row_count;
    p_status := p_status || jsonb_build_object('removed', n_gone);
  end if;
  perform _vlink();
  if p_status is not null then
    insert into config values('video_sync_status', p_status || jsonb_build_object('at', now(), 'saved', n))
      on conflict(k) do update set v=excluded.v;
    delete from config where k='sync_request';   -- 가져오기를 마쳤으니 수동 요청 처리 완료
  end if;
  return jsonb_build_object('ok', true, 'saved', n, 'removed', n_gone, 'requested', (select v->>'at' from config where k='sync_request'),
    'known', coalesce((select jsonb_agg(doc_code) from videos where sign is not null), '[]'::jsonb));
end $$;

create or replace function ping() returns text language sql as $$ select 'ok' $$;

drop function if exists register(text,text);
create or replace function register(p_name text, p_pw text, p_photo text default null) returns jsonb
language plpgsql security definer set search_path=public, extensions as $$
declare n int; m members;
begin
  p_name := trim(coalesce(p_name,''));
  if not _photo_ok(nullif(p_photo,'')) then p_photo := null; end if;
  if p_name = '' or length(coalesce(p_pw,'')) < 4 then return _err('이름과 비밀번호(4자 이상)를 입력하세요'); end if;
  if exists(select 1 from members where name = p_name) then return _err('이미 등록된 이름입니다'); end if;
  select count(*) into n from members;
  insert into members(name,pw,role,approved,photo)
    values(p_name, crypt(p_pw, gen_salt('bf')), case when n=0 then '회장' else '회원' end, n=0, nullif(p_photo,'')) returning * into m;
  if n > 0 then perform _notify(_ids(array['회장']), '가입 신청', m.name||'님이 가입을 신청했습니다', '#/me'); end if;
  return jsonb_build_object('ok',true,'approved',m.approved);
end $$;

create or replace function login(p_name text, p_pw text) returns jsonb
language plpgsql security definer set search_path=public, extensions as $$
declare m members; t uuid;
begin
  select * into m from members where name = trim(coalesce(p_name,''));
  if m.id is null then return _err('이름 또는 비밀번호가 틀립니다'); end if;
  -- 로그인 보호: 5번 틀리면 10분 잠금
  if m.lock_until is not null and m.lock_until > now() then
    return _err('비밀번호를 5번 틀려 잠겼습니다. '||ceil(extract(epoch from m.lock_until - now())/60)::int||'분 뒤에 다시 시도하세요');
  end if;
  if m.pw <> crypt(coalesce(p_pw,''), m.pw) then
    update members set fail_count = case when coalesce(fail_count,0) + 1 >= 5 then 0 else coalesce(fail_count,0) + 1 end,
      lock_until = case when coalesce(fail_count,0) + 1 >= 5 then now() + interval '10 minutes' else lock_until end where id = m.id;
    if coalesce(m.fail_count,0) + 1 >= 5 then return _err('비밀번호를 5번 틀려 10분간 잠겼습니다'); end if;
    return _err('이름 또는 비밀번호가 틀립니다 ('||(coalesce(m.fail_count,0)+1)||'/5)');
  end if;
  update members set fail_count = 0, lock_until = null where id = m.id;
  if not m.approved then return _err('회장 승인 대기 중입니다'); end if;
  -- 중복 로그인 방지: 다른 기기의 로그인은 자동 해제
  if exists(select 1 from sessions where member_id = m.id) then
    delete from sessions where member_id = m.id;
    perform _notify(array[m.id], '새 기기에서 로그인됨', '이전 기기는 자동 로그아웃되었습니다. 본인이 아니라면 바로 비밀번호를 바꾸세요', '#/me');
  end if;
  insert into sessions(member_id) values(m.id) returning token into t;
  return jsonb_build_object('token',t);
end $$;

-- 프로필 사진 주소는 우리 저장소 주소만 허용
create or replace function _photo_ok(u text) returns boolean language sql immutable as $$
  select u is null or (length(u) < 300 and u ~ '^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/files/[A-Za-z0-9/_.-]+$') $$;

-- 선거 단계 계산: rec(추천 중) · confirm(추천 마감, 회장 확정 대기) · vote(투표 중) · result(결과)
create or replace function _ephase(e elections) returns text language sql stable as $$
  select case when e.phase='rec' and (e.rec_until is null or e.rec_until > now()) then 'rec'
              when e.phase='rec' then 'confirm'
              when e.phase='vote' and e.vote_until > now() then 'vote'
              else 'result' end $$;

-- 직책별 결과 (가장 최근 투표 차수 기준). 후보 1명은 찬성 > 반대 일 때 당선, 기권은 승패에 안 셈
create or replace function _eresult(eid bigint) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare e elections; pos text; r int; res jsonb := '[]'; rws jsonb; top int; ntop int; one boolean; win bigint; st text; yn int; nn int;
begin
  select * into e from elections where id=eid;
  foreach pos in array e.positions loop
    select max(c.round) into r from candidates c where c.election_id=eid and c.position=pos;
    if r is null then res := res || jsonb_build_array(jsonb_build_object('position',pos,'status','none','rows','[]'::jsonb)); continue; end if;
    one := (select count(*) from candidates c where c.election_id=eid and c.round=r and c.position=pos) = 1;
    select coalesce(jsonb_agg(jsonb_build_object('choice',t.choice,'n',t.n,'name',m.name,'photo',m.photo) order by t.n desc, t.choice),'[]') into rws
      from tallies t left join members m on m.id::text = t.choice
     where t.election_id=eid and t.round=r and t.position=pos;
    win := null;
    if one then
      select coalesce(sum(t.n) filter (where t.choice ~ '^\d+$'),0), coalesce(sum(t.n) filter (where t.choice='no'),0) into yn, nn
        from tallies t where t.election_id=eid and t.round=r and t.position=pos;
      if yn > nn then select c.candidate_id into win from candidates c where c.election_id=eid and c.round=r and c.position=pos; end if;
      st := case when win is not null then 'win' else 'rejected' end;
    else
      select max(t.n) into top from tallies t where t.election_id=eid and t.round=r and t.position=pos and t.choice ~ '^\d+$';
      select count(*) into ntop from tallies t where t.election_id=eid and t.round=r and t.position=pos and t.choice ~ '^\d+$' and t.n=top;
      if coalesce(top,0)=0 then st := 'none';
      elsif ntop > 1 then st := 'tie';
      else st := 'win'; select t.choice::bigint into win from tallies t where t.election_id=eid and t.round=r and t.position=pos and t.choice ~ '^\d+$' and t.n=top; end if;
    end if;
    res := res || jsonb_build_array(jsonb_build_object('position',pos,'round',r,'single',one,'rows',rws,'status',st,'winner',win,
      'winner_name',(select name from members where id=win),'winner_photo',(select photo from members where id=win)));
  end loop;
  return res;
end $$;

-- 취임일(apply_on, 기본 다음 해 1월 1일)이 되면 당선자 직책을 자동으로 바꿈. 동점이 남아 있으면 재투표 끝날 때까지 보류
create or replace function _elect_apply() returns void language plpgsql security definer set search_path=public as $$
declare e elections; x jsonb;
begin
  for e in select * from elections where not applied and phase='vote' and vote_until < now()
             and apply_on <= (now() at time zone 'Asia/Shanghai')::date loop
    if exists(select 1 from jsonb_array_elements(_eresult(e.id)) r where r->>'status' = 'tie') then continue; end if;
    -- 아래 직책부터 적용 → 한 사람이 두 직책에 당선되면 높은 직책(회장)이 남음
    for x in select v from jsonb_array_elements(_eresult(e.id)) with ordinality as t(v, i) order by i desc loop
      if x->>'status' = 'win' then
        update members set role='회원' where role = x->>'position' and id <> (x->>'winner')::bigint;
        update members set role = x->>'position' where id = (x->>'winner')::bigint;
        perform _notify(array[(x->>'winner')::bigint], '임원 취임', (x->>'position')||'(으)로 취임했습니다', '#/me');
      end if;
    end loop;
    update elections set applied=true where id=e.id;
  end loop;
exception when others then null;  -- 자동 적용에 문제가 생겨도 사이트 사용은 막지 않음
end $$;
revoke all on function _elect_apply() from public, anon, authenticated;

-- 공지 한 줄 (홈·목록 공통): 참가 신청·선거 상태까지 포함
create or replace function _nrow(n notices, mid bigint, staff boolean) returns jsonb language sql stable security definer set search_path=public as $$
  select to_jsonb(n) || jsonb_build_object(
    'ended', (n.until is not null and n.until < (now() at time zone 'Asia/Shanghai')::date),
    'open', (n.kind='signup' and not coalesce(n.closed,false) and (n.signup_until is null or n.signup_until > now())),
    'mine', exists(select 1 from signups s where s.notice_id=n.id and s.member_id=mid),
    'cnt', case when staff then (select count(*) from signups s where s.notice_id=n.id) end,
    'el', (select jsonb_build_object('phase', _ephase(e), 'rec_until', e.rec_until, 'vote_until', e.vote_until,
             'done', case _ephase(e) when 'rec' then exists(select 1 from nominations x where x.election_id=e.id and x.member_id=mid)
                                     when 'vote' then exists(select 1 from voted v where v.election_id=e.id and v.round=e.round and v.member_id=mid)
                                     else false end)
           from elections e where e.id=n.election_id)) $$;

create or replace function api(p_token text, p_action text, p_d jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=public, extensions as $$
declare me members; p pays; mt meets; ok boolean; n int; xid bigint; ns text; staff boolean; vadm boolean; pid bigint; amt numeric;
begin
  select m.* into me from sessions s join members m on m.id = s.member_id
   where s.token::text = p_token and m.approved and s.created_at > now() - interval '180 days';  -- 로그인 유효기간 180일
  if me.id is null then return jsonb_build_object('err','다른 기기에서 로그인했거나 로그인이 해제되었습니다. 다시 로그인해 주세요','auth',true); end if;
  staff := me.role in ('회장','부회장','총무','감독','코치');
  vadm := me.role = '회장' or coalesce(me.video_admin, false);  -- 영상 관리: 회장 + 회장이 지정한 사람
  p_d := coalesce(p_d,'{}');
  perform _elect_apply();

  case p_action
  when 'me' then
    return jsonb_build_object('me', to_jsonb(me)-'pw', 'unread', (select count(*) from notis where to_id=me.id and not read));

  when 'home' then
    return jsonb_build_object(
      'income', coalesce((select sum(amount) from pays where status='지급완료' and type='수입'),0),
      'spend',  coalesce((select sum(amount) from pays where status='지급완료' and type='지출'),0),
      'month_spend', coalesce((select sum(amount) from pays where status='지급완료' and type='지출'
          and date_trunc('month', paid_at at time zone 'Asia/Shanghai') = date_trunc('month', now() at time zone 'Asia/Shanghai')),0),
      'notices', coalesce((select jsonb_agg(_nrow(nt, me.id, staff) order by nt.pinned desc, nt.created_at desc) from (select * from notices
          where until is null or until >= (now() at time zone 'Asia/Shanghai')::date
          order by pinned desc, created_at desc limit 4) nt),'[]'::jsonb),
      'notice_total', (select count(*) from notices),
      'todo', coalesce((select jsonb_agg(t) from (
          select 'pay' kind, id, title, status from pays
           where (me.role='회장' and status='회장결재') or (me.role='부회장' and status='부회장결재') or (me.role='총무' and status='지급대기')
          union all
          select 'req', id, title, status from reqs where staff and status='접수'
          union all
          select 'meet', id, title, status from meets
           where (me.role='부회장' and status='부회장검토') or (me.role='회장' and status='회장결재')) t),'[]'::jsonb),
      'meets', coalesce((select jsonb_agg(t) from (select id,title,mdate from meets where status='승인'
          order by mdate desc nulls last, id desc limit 3) t),'[]'::jsonb),
      'recent', coalesce((select jsonb_agg(t) from (select id,title,amount,category,applicant from pays
          where status='지급완료' and type='지출' order by paid_at desc limit 3) t),'[]'::jsonb),
      'polls', coalesce((select jsonb_agg(t) from (select pl.id, pl.title, pl.deadline,
          exists(select 1 from votes v where v.poll_id=pl.id and v.member_id=me.id) voted
          from polls pl where not pl.closed and (pl.deadline is null or pl.deadline > now()) order by pl.id desc limit 5) t),'[]'::jsonb),
      'next', (select to_jsonb(t) from (select mt2.id, mt2.title, mt2.opponent, mt2.starts_at, mt2.venue, mt2.format, mt2.need,
          (select count(*) from attends a where a.match_id=mt2.id and a.status='참석') yes,
          (select status from attends a where a.match_id=mt2.id and a.member_id=me.id) mine
          from matches mt2 where mt2.starts_at > now() - interval '3 hours' order by mt2.starts_at limit 1) t),
      'dues_amount', coalesce((select (v->>'amount')::numeric from config where k='dues'),0),
      'mydue', _due(me.id, to_char(now() at time zone 'Asia/Shanghai','YYYY-MM')),
      'unread', (select count(*) from notis where to_id=me.id and not read));

  when 'dues' then
    ns := coalesce(nullif(p_d->>'ym',''), to_char(now() at time zone 'Asia/Shanghai','YYYY-MM'));
    return jsonb_build_object('ym', ns,
      'amount', coalesce((select (v->>'amount')::numeric from config where k='dues'),0),
      'year_amount', coalesce((select (v->>'year_amount')::numeric from config where k='dues'),0),
      'year_deadline', (select v->>'year_deadline' from config where k='dues'),
      'list', coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'role',m.role,
          'status', _due(m.id, ns), 'exempt', coalesce(m.dues_exempt,false), 'note', coalesce(m.dues_note,''),
          'pause', (select jsonb_build_object('id',z.id,'from',z.from_ym,'to',z.to_ym,'reason',z.reason) from dues_pause z
                    where z.member_id=m.id and ns between z.from_ym and z.to_ym order by z.id desc limit 1),
          'amount', case when y.member_id is not null then y.amount else d.amount end,
          'at', coalesce(y.paid_at, d.paid_at), 'by', coalesce(y.by_name, d.by_name)) order by m.id)
        from members m
        left join dues d on d.member_id=m.id and d.ym=ns
        left join dues y on y.member_id=m.id and y.ym=left(ns,4) and y.status='연납'
        where m.approved and _due(m.id, ns) <> '해당없음'),'[]'::jsonb),
      'pauses', coalesce((select jsonb_agg(jsonb_build_object('id',z.id,'member_id',z.member_id,'name',m.name,'from',z.from_ym,'to',z.to_ym,
          'reason',z.reason,'by',z.by_name) order by z.from_ym) from dues_pause z join members m on m.id=z.member_id where z.to_ym >= left(ns,7)),'[]'::jsonb));

  when 'myDues' then
    n := coalesce(nullif(p_d->>'year','')::int, extract(year from now() at time zone 'Asia/Shanghai')::int);
    return jsonb_build_object('year', n,
      'months', (select jsonb_agg(jsonb_build_object('m', g, 'status', _due(me.id, n||'-'||lpad(g::text,2,'0'))) order by g) from generate_series(1,12) g),
      'total', coalesce((select sum(d.amount) from dues d where d.member_id=me.id and (d.ym = n::text or d.ym like n||'-%') and d.status in ('납부','연납')),0));

  when 'duesExempt' then
    if me.role not in ('회장','총무') then return _err('회장·총무만 바꿀 수 있습니다'); end if;
    update members set dues_exempt = coalesce((p_d->>'exempt')::boolean,false), dues_note = coalesce(p_d->>'note','')
      where id=(p_d->>'id')::bigint;
    return jsonb_build_object('ok',true);

  when 'pauseSave' then
    if me.role not in ('회장','총무') then return _err('회장·총무만 일시중단을 설정할 수 있습니다'); end if;
    if coalesce(p_d->>'from','') !~ '^\d{4}-\d{2}$' or coalesce(p_d->>'to','') !~ '^\d{4}-\d{2}$' then return _err('시작·끝 달을 입력하세요'); end if;
    if p_d->>'from' > p_d->>'to' then return _err('끝 달이 시작 달보다 빠릅니다'); end if;
    if nullif(p_d->>'pid','') is null then
      insert into dues_pause(member_id,from_ym,to_ym,reason,by_name)
        values((p_d->>'id')::bigint, p_d->>'from', p_d->>'to', coalesce(p_d->>'reason',''), me.name);
    else
      update dues_pause set from_ym=p_d->>'from', to_ym=p_d->>'to', reason=coalesce(p_d->>'reason',''), by_name=me.name
        where id=(p_d->>'pid')::bigint;
    end if;
    return jsonb_build_object('ok',true);

  when 'pauseDel' then
    if me.role not in ('회장','총무') then return _err('회장·총무만 바꿀 수 있습니다'); end if;
    delete from dues_pause where id=(p_d->>'pid')::bigint;
    return jsonb_build_object('ok',true);

  when 'duesAmount' then
    if me.role not in ('회장','총무') then return _err('회장·총무만 바꿀 수 있습니다'); end if;
    insert into config values('dues', jsonb_build_object(
        'amount', coalesce(nullif(p_d->>'amount','')::numeric,0),
        'year_amount', coalesce(nullif(p_d->>'year_amount','')::numeric,0),
        'year_deadline', coalesce(p_d->>'year_deadline','')))
      on conflict(k) do update set v=excluded.v;
    return jsonb_build_object('ok',true);

  when 'duesSet' then
    if me.role not in ('회장','총무') then return _err('회장·총무만 납부 체크를 할 수 있습니다'); end if;
    ns := p_d->>'ym'; xid := (p_d->>'id')::bigint;
    if ns !~ '^\d{4}-\d{2}$' or p_d->>'status' not in ('미납','납부','면제','연납') then return _err('잘못된 선택'); end if;
    if p_d->>'status' = '연납' then
      amt := coalesce((select (v->>'year_amount')::numeric from config where k='dues'), 0);
      if amt <= 0 then return _err('먼저 연납 금액을 정해 주세요'); end if;
      if exists(select 1 from dues where member_id=xid and ym=left(ns,4)) then return jsonb_build_object('ok',true); end if;
      insert into pays(type,title,category,amount,reason,status,applicant_id,applicant,history,paid_at)
        values('수입', left(ns,4)||'년 연회비(일시납) · '||(select name from members where id=xid),
          '회비', amt, '회비 납부 현황에서 자동 등록 (연납)', '지급완료', me.id, me.name, _hist(me,'연회비 납부 체크',''), now())
        returning id into pid;
      insert into dues(member_id,ym,status,amount,paid_at,by_name,pay_id) values(xid, left(ns,4), '연납', amt, now(), me.name, pid);
      return jsonb_build_object('ok',true);
    end if;
    -- 연납을 취소하고 월별로 바꾸는 경우: 연납 기록과 자동 수입 삭제
    delete from pays where id = (select pay_id from dues where member_id=xid and ym=left(ns,4));
    delete from dues where member_id=xid and ym=left(ns,4);
    amt := coalesce(nullif(p_d->>'amount','')::numeric, (select (v->>'amount')::numeric from config where k='dues'), 0);
    if p_d->>'status' = '납부' and amt <= 0 then return _err('먼저 월 회비 금액을 정해 주세요'); end if;
    -- 이전에 자동 등록된 수입은 지우고 다시 계산
    delete from pays where id = (select pay_id from dues where member_id=xid and ym=ns);
    if p_d->>'status' = '미납' then
      delete from dues where member_id=xid and ym=ns;
    else
      insert into dues(member_id,ym,status,amount,paid_at,by_name,pay_id)
        values(xid, ns, p_d->>'status', case when p_d->>'status'='납부' then amt end, now(), me.name, null)
        on conflict(member_id,ym) do update set status=excluded.status, amount=excluded.amount, paid_at=now(), by_name=me.name, pay_id=null;
      if p_d->>'status' = '납부' then
        insert into pays(type,title,category,amount,reason,status,applicant_id,applicant,history,paid_at)
          values('수입', split_part(ns,'-',1)||'년 '||split_part(ns,'-',2)::int||'월 회비 · '||(select name from members where id=xid),
            '회비', amt, '회비 납부 현황에서 자동 등록', '지급완료', me.id, me.name, _hist(me,'회비 납부 체크',''), now())
          returning id into pid;
        update dues set pay_id=pid where member_id=xid and ym=ns;
      end if;
    end if;
    return jsonb_build_object('ok',true);

  when 'duesRemind' then
    if me.role not in ('회장','총무') then return _err('회장·총무만 알림을 보낼 수 있습니다'); end if;
    ns := p_d->>'ym';
    perform _notify(array(select m.id from members m where m.approved and _due(m.id, ns) = '미납'),
      '회비 납부 안내', split_part(ns,'-',1)||'년 '||split_part(ns,'-',2)::int||'월 회비가 아직 납부되지 않았습니다', '#/dues');
    return jsonb_build_object('ok',true);

  when 'backup' then
    if me.role <> '회장' then return _err('회장만 백업할 수 있습니다'); end if;
    return jsonb_build_object('app','WXFC','version',1,'at',now(),
      'members', (select coalesce(jsonb_agg(to_jsonb(x) - 'pw' order by x.id),'[]'::jsonb) from members x),
      'pays',    (select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]'::jsonb) from pays x),
      'meets',   (select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]'::jsonb) from meets x),
      'polls',   (select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]'::jsonb) from polls x),
      'votes',   (select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from votes x),
      'matches', (select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]'::jsonb) from matches x),
      'attends', (select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from attends x),
      'reqs',    (select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]'::jsonb) from reqs x),
      'notices', (select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]'::jsonb) from notices x),
      'signups', (select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]'::jsonb) from signups x),
      'elections', (select coalesce(jsonb_agg(to_jsonb(x) || jsonb_build_object('result', _eresult(x.id)) order by x.id),'[]'::jsonb) from elections x),
      'dues',    (select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from dues x),
      'dues_pause', (select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from dues_pause x),
      'videos',  (select coalesce(jsonb_agg(to_jsonb(x) - 'sign' - 'mp4' - 'link'),'[]'::jsonb) from videos x),
      'config',  (select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from config x));

  when 'matches' then
    return jsonb_build_object('list', coalesce((select jsonb_agg(t) from (
      select x.id, x.title, x.opponent, x.starts_at, x.venue, x.format, x.need,
        x.starts_at < now() - interval '3 hours' past,
        (select count(*) from attends a where a.match_id=x.id and a.status='참석') yes,
        (select status from attends a where a.match_id=x.id and a.member_id=me.id) mine
      from matches x order by (x.starts_at < now() - interval '3 hours'), 
        case when x.starts_at >= now() - interval '3 hours' then x.starts_at end asc, x.starts_at desc limit 200) t),'[]'::jsonb),
      'venues', coalesce((select jsonb_agg(t) from (select distinct on (venue) venue, address, map_url from matches
        where venue <> '' order by venue, id desc) t),'[]'::jsonb));

  when 'match' then
    return (select jsonb_build_object(
      'm', to_jsonb(x) || jsonb_build_object('open', now() < coalesce(x.deadline, x.starts_at)),
      'att', coalesce((select jsonb_agg(jsonb_build_object('name',a.member_name,'status',a.status) order by a.at)
             from attends a where a.match_id=x.id),'[]'::jsonb),
      'mine', (select status from attends where match_id=x.id and member_id=me.id),
      'missing', coalesce((select jsonb_agg(m.name order by m.id) from members m where m.approved
             and not exists(select 1 from attends a where a.match_id=x.id and a.member_id=m.id)),'[]'::jsonb))
      from matches x where x.id=(p_d->>'id')::bigint);

  when 'matchSave' then
    if not staff then return _err('운영진만 경기를 등록할 수 있습니다'); end if;
    if coalesce(trim(p_d->>'title'),'')='' or coalesce(p_d->>'starts_at','')='' then return _err('경기 이름과 날짜·시간을 입력하세요'); end if;
    xid := nullif(p_d->>'id','')::bigint;
    if xid is null then
      insert into matches(title,opponent,starts_at,venue,address,map_url,format,need,memo,deadline,by_id,by_name)
      values(trim(p_d->>'title'), coalesce(p_d->>'opponent',''), (p_d->>'starts_at')::timestamptz, coalesce(p_d->>'venue',''),
        coalesce(p_d->>'address',''), coalesce(p_d->>'map_url',''), coalesce(p_d->>'format','11인제'), coalesce(nullif(p_d->>'need','')::int,11),
        coalesce(p_d->>'memo',''), nullif(p_d->>'deadline','')::timestamptz, me.id, me.name) returning id into xid;
      perform _notify(_ids(null), '경기 일정 등록', trim(p_d->>'title'), '#/match/'||xid);
    else
      update matches set title=trim(p_d->>'title'), opponent=coalesce(p_d->>'opponent',''), starts_at=(p_d->>'starts_at')::timestamptz,
        venue=coalesce(p_d->>'venue',''), address=coalesce(p_d->>'address',''), map_url=coalesce(p_d->>'map_url',''),
        format=coalesce(p_d->>'format','11인제'), need=coalesce(nullif(p_d->>'need','')::int,11), memo=coalesce(p_d->>'memo',''),
        deadline=nullif(p_d->>'deadline','')::timestamptz where id=xid;
      perform _notify(array(select member_id from attends where match_id=xid), '경기 정보 변경', trim(p_d->>'title'), '#/match/'||xid);
    end if;
    perform _vlink();  -- 경기를 나중에 등록해도 이미 올라온 영상이 붙도록
    return jsonb_build_object('id', xid);

  when 'videos' then
    return jsonb_build_object('list', coalesce((select jsonb_agg(t) from (
      select v.id, v.shot_at, v.duration, v.title, v.match_id, m.title match_title, m.opponent
      from videos v left join matches m on m.id=v.match_id
      where not v.hidden and not coalesce(v.gone,false) and (v.sign is not null or v.mp4 is not null)
        and (nullif(p_d->>'match','') is null or v.match_id = (p_d->>'match')::bigint)
      order by v.shot_at desc nulls last limit least(coalesce(nullif(p_d->>'limit','')::int, 30), 50) offset greatest(coalesce(nullif(p_d->>'offset','')::int, 0), 0)) t),'[]'::jsonb),
      'total', (select count(*) from videos v where not v.hidden and not coalesce(v.gone,false) and (v.sign is not null or v.mp4 is not null)),
      'last', (select v->>'at' from config where k='video_sync_status'),
      'requested', (select v->>'at' from config where k='sync_request'));

  when 'syncRequest' then
    if not vadm then return _err('영상 관리 권한이 없습니다 (회장에게 요청하세요)'); end if;
    insert into config values('sync_request', jsonb_build_object('at', now(), 'by', me.name))
      on conflict(k) do update set v=excluded.v;
    return jsonb_build_object('ok',true);

  when 'videoPlay' then
    return (select jsonb_build_object('mp4', case when v.mp4_until > now() + interval '10 minutes' then v.mp4 end, 'link', v.link, 'shot_at', v.shot_at, 'duration', v.duration, 'title', v.title,
        'match_id', v.match_id, 'match_title', m.title, 'opponent', m.opponent, 'starts_at', m.starts_at)
      from videos v left join matches m on m.id=v.match_id where v.id=(p_d->>'id')::bigint and not v.hidden and not coalesce(v.gone,false));

  when 'videoEdit' then
    if not vadm then return _err('영상 관리 권한이 없습니다 (회장에게 요청하세요)'); end if;
    update videos set title = coalesce(left(p_d->>'title',80), title),
      match_id = case when p_d ? 'match_id' then nullif(p_d->>'match_id','')::bigint else match_id end,
      link_manual = link_manual or (p_d ? 'match_id' and nullif(p_d->>'match_id','')::bigint is distinct from match_id),
      hidden = coalesce((p_d->>'hidden')::boolean, hidden)
      where id=(p_d->>'id')::bigint;
    return jsonb_build_object('ok',true);

  when 'syncKey' then
    if me.role not in ('회장','부회장') then return _err('회장·부회장만 설정할 수 있습니다'); end if;
    if coalesce(p_d->>'hash','') !~ '^[0-9a-f]{64}$' then return _err('잘못된 키'); end if;
    insert into config values('sync_key', jsonb_build_object('hash', p_d->>'hash', 'at', now(), 'by', me.name))
      on conflict(k) do update set v=excluded.v;
    return jsonb_build_object('ok',true);

  when 'matchDel' then
    if not staff then return _err('운영진만 삭제할 수 있습니다'); end if;
    delete from matches where id=(p_d->>'id')::bigint;
    return jsonb_build_object('ok',true);

  when 'attend' then
    if p_d->>'status' not in ('참석','불참','미정') then return _err('잘못된 선택'); end if;
    if not exists(select 1 from matches where id=(p_d->>'id')::bigint and now() < coalesce(deadline, starts_at))
      then return _err('출석 체크가 마감되었습니다'); end if;
    insert into attends(match_id,member_id,member_name,status) values((p_d->>'id')::bigint, me.id, me.name, p_d->>'status')
      on conflict(match_id,member_id) do update set status=excluded.status, member_name=excluded.member_name, at=now();
    return jsonb_build_object('ok',true);

  when 'report' then
    n := coalesce(nullif(p_d->>'year','')::int, extract(year from now() at time zone 'Asia/Shanghai')::int);
    xid := coalesce(nullif(p_d->>'month','')::int, 0);
    return (with d as (select id, type, title, category, amount, applicant, (paid_at at time zone 'Asia/Shanghai') t
                         from pays where status='지급완료' and paid_at is not null),
      r as (select make_timestamp(n, greatest(xid,1)::int, 1, 0, 0, 0) s,
              case when xid > 0 then make_timestamp(n, xid::int, 1, 0, 0, 0) + interval '1 month' else make_timestamp(n+1, 1, 1, 0, 0, 0) end e)
    select jsonb_build_object('year', n, 'month', xid,
      'carry',  coalesce((select sum(case when d.type='수입' then d.amount else -d.amount end) from d, r where d.t < r.s),0),
      'income', coalesce((select sum(d.amount) from d, r where d.type='수입' and d.t >= r.s and d.t < r.e),0),
      'spend',  coalesce((select sum(d.amount) from d, r where d.type='지출' and d.t >= r.s and d.t < r.e),0),
      'cats', coalesce((select jsonb_agg(x order by x.amt desc) from (select d.category cat, sum(d.amount) amt from d, r
                where d.type='지출' and d.t >= r.s and d.t < r.e group by d.category) x),'[]'::jsonb),
      'months', (select jsonb_agg(jsonb_build_object('m', g,
                  'in',  coalesce((select sum(d.amount) from d where d.type='수입' and extract(year from d.t)=n and extract(month from d.t)=g),0),
                  'out', coalesce((select sum(d.amount) from d where d.type='지출' and extract(year from d.t)=n and extract(month from d.t)=g),0)) order by g)
                 from generate_series(1,12) g),
      'list', coalesce((select jsonb_agg(x order by x.t) from (select d.id, d.type, d.title, d.category, d.amount, d.applicant, d.t
                from d, r where d.t >= r.s and d.t < r.e) x),'[]'::jsonb),
      'years', coalesce((select jsonb_agg(distinct extract(year from d.t)::int) from d),'[]'::jsonb)));

  when 'notiPoll' then  -- 운영진 알림 앱이 1분마다 호출 (가볍게)
    return jsonb_build_object('max', coalesce((select max(id) from notis where to_id=me.id),0),
      'list', coalesce((select jsonb_agg(t order by t.id) from (select id,title,body,link from notis
          where to_id=me.id and id > coalesce(nullif(p_d->>'after','')::bigint,0) order by id limit 20) t),'[]'::jsonb));

  when 'pays' then
    return jsonb_build_object('list', coalesce((select jsonb_agg(t) from (
      select id,type,title,category,amount,status,applicant,created_at from pays
       where coalesce(p_d->>'status','')='' or status = p_d->>'status'
       order by created_at desc limit 300) t),'[]'::jsonb));

  when 'pay' then
    select * into p from pays where id=(p_d->>'id')::bigint;
    if p.id is null then return _err('없는 항목입니다'); end if;
    return jsonb_build_object('p', to_jsonb(p));

  when 'paySave' then
    if coalesce(p_d->>'title','')='' or coalesce((p_d->>'amount')::numeric,0) <= 0 then return _err('제목과 금액을 입력하세요'); end if;
    ok := p_d->>'type' = '수입';
    if not staff then return _err('결제안은 운영진만 올릴 수 있습니다'); end if;
    if ok and me.role not in ('회장','총무') then return _err('수입은 회장·총무만 등록할 수 있습니다'); end if;
    insert into pays(type,title,category,amount,reason,receipts,status,applicant_id,applicant,history,paid_at,skip_vice)
    values(case when ok then '수입' else '지출' end, p_d->>'title', coalesce(p_d->>'category','기타'),
      (p_d->>'amount')::numeric, coalesce(p_d->>'reason',''), coalesce(p_d->'receipts','[]'),
      case when ok then '지급완료' else '회장결재' end, me.id, me.name,
      _hist(me, case when ok then '수입 등록' else '결제안 신청' end, ''), case when ok then now() end,
      not exists(select 1 from members where approved and role='부회장'))
    returning * into p;
    if not ok then perform _notify(_ids(array['회장']), '결제안 승인 요청', me.name||': '||p.title||' ¥'||p.amount, '#/pay/'||p.id); end if;
    return jsonb_build_object('id', p.id);

  when 'payAct' then
    select * into p from pays where id=(p_d->>'id')::bigint;
    if p.id is null then return _err('없는 항목입니다'); end if;
    if p_d->>'act' in ('approve','reject') then
      ok := p_d->>'act' = 'approve';
      if p.status = '회장결재' and me.role = '회장' then
        ns := case when not ok then '반려' when p.skip_vice then '지급대기' else '부회장결재' end;
      elsif p.status = '부회장결재' and (me.role = '부회장'
            or (me.role = '회장' and not exists(select 1 from members where approved and role='부회장'))) then
        ns := case when ok then '지급대기' else '반려' end;
      else return _err('지금은 결재할 수 있는 단계가 아닙니다'); end if;
      update pays set status = ns,
        reject_reason = case when ok then '' else coalesce(p_d->>'comment','') end,
        history = history || _hist(me, case when ok then '승인' else '반려' end, p_d->>'comment') where id=p.id;
      if ns = '부회장결재' then perform _notify(_ids(array['부회장']), '결제안 승인 요청', p.title||' ¥'||p.amount, '#/pay/'||p.id);
      elsif ns = '지급대기' then
        perform _notify(_ids(array['총무']), '송금 요청', p.title||' ¥'||p.amount, '#/pay/'||p.id);
        perform _notify(array[p.applicant_id], '결제안 최종 승인', p.title, '#/pay/'||p.id);
      else perform _notify(array[p.applicant_id], '결제안 반려', p.title, '#/pay/'||p.id); end if;
    elsif p_d->>'act' = 'paid' then
      if me.role <> '총무' or p.status <> '지급대기' then return _err('총무만 승인된 건을 지급완료할 수 있습니다'); end if;
      if jsonb_array_length(coalesce(p_d->'proof','[]')) = 0 then return _err('송금 캡처를 첨부하세요'); end if;
      update pays set status='지급완료', paid_at=now(), proof=p_d->'proof', history = history || _hist(me,'지급완료','') where id=p.id;
      perform _notify(array[p.applicant_id] || _ids(array['회장']), '지급 완료', p.title||' ¥'||p.amount, '#/pay/'||p.id);
    else return _err('알 수 없는 처리'); end if;
    return jsonb_build_object('ok',true);

  when 'meets' then
    return jsonb_build_object('list', coalesce((select jsonb_agg(t) from (
      select id,title,mdate,status,by_name,jsonb_array_length(files) nfiles,(minutes<>'') has_min from meets
       where staff or status='승인' or by_id=me.id order by mdate desc nulls last, id desc limit 300) t),'[]'::jsonb));

  when 'meet' then
    select * into mt from meets where id=(p_d->>'id')::bigint;
    if mt.id is null then return _err('없는 항목입니다'); end if;
    if not staff and mt.status <> '승인' and mt.by_id <> me.id then return _err('아직 확정되지 않은 회의입니다'); end if;
    return jsonb_build_object('m', to_jsonb(mt), 'polls', coalesce((select jsonb_agg(t) from (
      select pl.id, pl.title, pl.closed or (pl.deadline is not null and pl.deadline <= now()) closed,
        (select count(*) from votes v where v.poll_id=pl.id) n,
        exists(select 1 from votes v where v.poll_id=pl.id and v.member_id=me.id) voted
      from polls pl where pl.meet_id=mt.id order by pl.id) t),'[]'::jsonb));

  when 'pollSave' then
    if not staff then return _err('운영진만 투표를 만들 수 있습니다'); end if;
    select * into mt from meets where id=(p_d->>'meet_id')::bigint;
    if mt.status is distinct from '승인' then return _err('확정된 회의에서만 투표를 만들 수 있습니다'); end if;
    if coalesce(trim(p_d->>'title'),'')='' or jsonb_array_length(coalesce(p_d->'options','[]')) < 2 then
      return _err('투표 제목과 선택지(2개 이상)를 입력하세요'); end if;
    insert into polls(meet_id,title,options,deadline,by_id,by_name)
      values(mt.id, trim(p_d->>'title'), p_d->'options', nullif(p_d->>'deadline','')::timestamptz, me.id, me.name)
      returning id into xid;
    perform _notify(_ids(null), '투표 시작', trim(p_d->>'title'), '#/vote/'||xid);
    return jsonb_build_object('id', xid);

  when 'poll' then
    return (select jsonb_build_object(
      'p', to_jsonb(pl) || jsonb_build_object('ended', pl.closed or (pl.deadline is not null and pl.deadline <= now()),
            'meet_title', (select title from meets where id=pl.meet_id)),
      'votes', coalesce((select jsonb_agg(jsonb_build_object('name',v.member_name,'choice',v.choice,'at',v.at) order by v.at)
            from votes v where v.poll_id=pl.id),'[]'::jsonb),
      'mine', (select choice from votes where poll_id=pl.id and member_id=me.id),
      'missing', coalesce((select jsonb_agg(m.name order by m.id) from members m where m.approved
            and not exists(select 1 from votes v where v.poll_id=pl.id and v.member_id=m.id)),'[]'::jsonb))
      from polls pl where pl.id=(p_d->>'id')::bigint);

  when 'vote' then
    if not exists(select 1 from polls where id=(p_d->>'id')::bigint and not closed
        and (deadline is null or deadline > now())) then return _err('마감된 투표입니다'); end if;
    if (p_d->>'choice')::int < 0 or (p_d->>'choice')::int >= (select jsonb_array_length(options) from polls where id=(p_d->>'id')::bigint)
      then return _err('잘못된 선택'); end if;
    insert into votes(poll_id,member_id,member_name,choice) values((p_d->>'id')::bigint, me.id, me.name, (p_d->>'choice')::int)
      on conflict(poll_id,member_id) do update set choice=excluded.choice, member_name=excluded.member_name, at=now();
    return jsonb_build_object('ok',true);

  when 'pollClose' then
    if not staff then return _err('운영진만 마감할 수 있습니다'); end if;
    update polls set closed=true where id=(p_d->>'id')::bigint returning title into ns;
    perform _notify(_ids(null), '투표 마감', coalesce(ns,''), '#/vote/'||(p_d->>'id'));
    return jsonb_build_object('ok',true);

  when 'meetSave' then
    if not staff then return _err('회의 안건은 운영진만 올릴 수 있습니다'); end if;
    if coalesce(p_d->>'title','')='' then return _err('제목을 입력하세요'); end if;
    select count(*) into n from members where approved and role='부회장';
    insert into meets(title,mdate,agenda,files,status,skip_vice,by_id,by_name,history)
    values(p_d->>'title', nullif(p_d->>'date','')::date, coalesce(p_d->>'agenda',''), coalesce(p_d->'files','[]'),
      case when n>0 then '부회장검토' else '회장결재' end, n=0, me.id, me.name, _hist(me,'안건 상신',''))
    returning * into mt;
    perform _notify(_ids(array[case when n>0 then '부회장' else '회장' end]), '회의 안건 결재 요청', mt.title, '#/meet/'||mt.id);
    return jsonb_build_object('id', mt.id);

  when 'meetAct' then
    select * into mt from meets where id=(p_d->>'id')::bigint;
    if mt.id is null then return _err('없는 항목입니다'); end if;
    ok := p_d->>'act' = 'approve';
    if mt.status = '부회장검토' then
      if me.role <> '부회장' then return _err('부회장 결재 단계입니다'); end if;
      ns := case when ok then '회장결재' else '반려' end;
    elsif mt.status = '회장결재' then
      if me.role <> '회장' then return _err('회장 결재 단계입니다'); end if;
      ns := case when ok then '승인' else '반려' end;
    else return _err('결재할 수 없는 상태입니다'); end if;
    update meets set status=ns, history = history || _hist(me, case when ok then '승인' else '반려' end, p_d->>'comment') where id=mt.id;
    if ns='회장결재' then perform _notify(_ids(array['회장']), '회의 안건 결재 요청', mt.title, '#/meet/'||mt.id);
    elsif ns='승인' then perform _notify(_ids(null), '회의 안건 확정', mt.title, '#/meet/'||mt.id);
    else perform _notify(array[mt.by_id], '회의 안건 반려', mt.title, '#/meet/'||mt.id); end if;
    return jsonb_build_object('ok',true);

  when 'minutes' then
    if not staff then return _err('운영진만 회의록을 등록할 수 있습니다'); end if;
    select * into mt from meets where id=(p_d->>'id')::bigint;
    if mt.status is distinct from '승인' then return _err('확정된 회의에만 회의록을 등록할 수 있습니다'); end if;
    update meets set minutes=coalesce(p_d->>'minutes',''), mfiles=coalesce(p_d->'mfiles','[]') where id=mt.id;
    perform _notify(_ids(null), '회의록 등록', mt.title, '#/meet/'||mt.id);
    return jsonb_build_object('ok',true);

  when 'org' then
    return jsonb_build_object(
      'users', coalesce((select jsonb_agg(t) from (select id,name,role,position,photo from members where approved order by id) t),'[]'::jsonb),
      'rules', (select v from config where k='rules'));

  when 'setRules' then
    if me.role not in ('회장','총무') then return _err('회장·총무만 회칙을 등록할 수 있습니다'); end if;
    insert into config values('rules', jsonb_build_object('name',p_d->>'name','url',p_d->>'url','at',now(),'by',me.name))
      on conflict(k) do update set v=excluded.v;
    perform _notify(_ids(null), '회칙 갱신', coalesce(p_d->>'name','회칙'), '#/org');
    return jsonb_build_object('ok',true);

  when 'notices' then
    return jsonb_build_object('list', coalesce((select jsonb_agg(_nrow(nt, me.id, staff) order by nt.pinned desc, nt.created_at desc) from notices nt),'[]'::jsonb));

  when 'noticeSave' then
    if me.role not in ('회장','총무') then return _err('회장·총무만 공지를 쓸 수 있습니다'); end if;
    if coalesce(trim(p_d->>'title'),'') = '' then return _err('제목을 입력하세요'); end if;
    xid := nullif(p_d->>'id','')::bigint;
    if xid is null then
      insert into notices(title, body, pinned, until, by_name, kind, memo_label, signup_until)
        values(left(trim(p_d->>'title'),100), left(coalesce(p_d->>'body',''),5000), coalesce((p_d->>'pinned')::boolean,false), nullif(p_d->>'until','')::date, me.name,
          case when coalesce((p_d->>'signup')::boolean,false) then 'signup' else 'notice' end,
          nullif(left(trim(coalesce(p_d->>'memo_label','')),30),''), nullif(p_d->>'signup_until','')::timestamptz)
        returning id into xid;
    else
      update notices set title=left(trim(p_d->>'title'),100), body=left(coalesce(p_d->>'body',''),5000), pinned=coalesce((p_d->>'pinned')::boolean,false),
        until=nullif(p_d->>'until','')::date, updated_at=now(),
        memo_label=case when kind='signup' then nullif(left(trim(coalesce(p_d->>'memo_label','')),30),'') else memo_label end,
        signup_until=case when kind='signup' then nullif(p_d->>'signup_until','')::timestamptz else signup_until end
       where id=xid;
    end if;
    if coalesce((p_d->>'notify')::boolean,false) then perform _notify(_ids(null), '📢 공지', left(trim(p_d->>'title'),100), '#/notice/'||xid); end if;
    return jsonb_build_object('ok',true,'id',xid);

  when 'noticeDel' then
    if me.role not in ('회장','총무') then return _err('회장·총무만 공지를 지울 수 있습니다'); end if;
    delete from elections where id=(select election_id from notices where id=(p_d->>'id')::bigint);
    delete from notices where id=(p_d->>'id')::bigint;
    return jsonb_build_object('ok',true);

  -- ───── 참가 신청 ─────
  when 'notice' then
    return jsonb_build_object('n', (select _nrow(nt, me.id, staff) from notices nt where nt.id=(p_d->>'id')::bigint),
      'my', (select to_jsonb(s) from signups s where s.notice_id=(p_d->>'id')::bigint and s.member_id=me.id));

  when 'signup' then
    if not exists(select 1 from notices nt where nt.id=(p_d->>'id')::bigint and nt.kind='signup' and not coalesce(nt.closed,false)
                  and (nt.signup_until is null or nt.signup_until > now())) then return _err('신청이 마감되었습니다'); end if;
    insert into signups(notice_id, member_id, name, memo) values((p_d->>'id')::bigint, me.id, me.name, left(coalesce(p_d->>'memo',''),50))
      on conflict (notice_id, member_id) where member_id is not null do update set memo=excluded.memo;
    return jsonb_build_object('ok',true);

  when 'signupCancel' then
    if not exists(select 1 from notices nt where nt.id=(p_d->>'id')::bigint and not coalesce(nt.closed,false)
                  and (nt.signup_until is null or nt.signup_until > now())) then return _err('마감된 신청은 취소할 수 없습니다'); end if;
    delete from signups where notice_id=(p_d->>'id')::bigint and member_id=me.id;
    return jsonb_build_object('ok',true);

  when 'signupList' then
    if not staff then return _err('운영진만 볼 수 있습니다'); end if;
    return jsonb_build_object('n', (select _nrow(nt, me.id, staff) from notices nt where nt.id=(p_d->>'id')::bigint),
      'list', coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'memo',s.memo,'photo',m.photo,'proxy',s.member_id is null,'at',s.created_at) order by s.created_at, s.id)
        from signups s left join members m on m.id=s.member_id where s.notice_id=(p_d->>'id')::bigint),'[]'::jsonb));

  when 'signupAdd' then
    if not staff then return _err('운영진만 대리 등록할 수 있습니다'); end if;
    if coalesce(trim(p_d->>'name'),'') = '' then return _err('이름을 입력하세요'); end if;
    insert into signups(notice_id, name, memo, by_name) values((p_d->>'id')::bigint, left(trim(p_d->>'name'),30), left(coalesce(p_d->>'memo',''),50), me.name);
    return jsonb_build_object('ok',true);

  when 'signupDel' then
    if not staff then return _err('운영진만 지울 수 있습니다'); end if;
    delete from signups where id=(p_d->>'sid')::bigint;
    return jsonb_build_object('ok',true);

  when 'signupClose' then
    if not staff then return _err('운영진만 마감할 수 있습니다'); end if;
    update notices set closed=coalesce((p_d->>'closed')::boolean,true) where id=(p_d->>'id')::bigint and kind='signup';
    return jsonb_build_object('ok',true);

  -- ───── 임원 선거 ─────
  when 'electionNew' then
    if me.role <> '회장' then return _err('회장만 선거를 시작할 수 있습니다'); end if;
    if nullif(p_d->>'rec_until','') is null then return _err('추천 마감을 정하세요'); end if;
    insert into elections(title, rec_until, apply_on)
      values(coalesce(nullif(trim(p_d->>'title'),''), extract(year from now() at time zone 'Asia/Shanghai')::int + 1 || '년 임원 선거'),
             (p_d->>'rec_until')::timestamptz,
             coalesce(nullif(p_d->>'apply_on','')::date, make_date(extract(year from now() at time zone 'Asia/Shanghai')::int + 1, 1, 1)))
      returning id into xid;
    insert into notices(title, body, pinned, by_name, kind, election_id)
      values((select title from elections where id=xid),
             coalesce(nullif(trim(p_d->>'body'),''), '회장 · 부회장 · 감독 후보를 추천해 주세요. 본인을 고르면 출마입니다. 추천 내용은 회장만 봅니다.'),
             true, me.name, 'election', xid) returning id into pid;
    perform _notify(_ids(null), '🗳 임원 선거', '후보 추천이 시작됐어요', '#/election/'||xid);
    return jsonb_build_object('ok',true,'id',xid);

  when 'election' then
    return (select jsonb_build_object(
      'e', to_jsonb(e) || jsonb_build_object('phase', _ephase(e)),
      'notice', (select jsonb_build_object('id',n.id,'body',n.body) from notices n where n.election_id=e.id limit 1),
      'members', coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'photo',m.photo,'role',m.role) order by m.name) from members m where m.approved),'[]'::jsonb),
      'mine', coalesce((select jsonb_object_agg(x.position, x.candidate_id) from nominations x where x.election_id=e.id and x.member_id=me.id),'{}'::jsonb),
      'mine_reason', (select x.reason from nominations x where x.election_id=e.id and x.member_id=me.id limit 1),
      'mine_named', (select bool_or(x.named) from nominations x where x.election_id=e.id and x.member_id=me.id),
      -- 추천 현황과 추천서: 회장만
      'noms', case when me.role='회장' then coalesce((select jsonb_agg(t) from (
          select x.position, x.candidate_id, m.name, m.photo, count(*) cnt, bool_or(x.member_id = x.candidate_id) self,
                 jsonb_agg(jsonb_build_object('reason',x.reason,'by',case when x.named then r.name end,'self',x.member_id=x.candidate_id) order by x.created_at) letters
            from nominations x join members m on m.id=x.candidate_id join members r on r.id=x.member_id
           where x.election_id=e.id group by x.position, x.candidate_id, m.name, m.photo order by x.position, count(*) desc) t),'[]'::jsonb) end,
      'cands', coalesce((select jsonb_agg(jsonb_build_object('position',c.position,'id',c.candidate_id,'name',m.name,'photo',m.photo) order by c.position, m.name)
          from candidates c join members m on m.id=c.candidate_id where c.election_id=e.id and c.round=e.round),'[]'::jsonb),
      'voted', exists(select 1 from voted v where v.election_id=e.id and v.round=e.round and v.member_id=me.id),
      'turnout', (select count(*) from voted v where v.election_id=e.id and v.round=e.round),
      'total', (select count(*) from members where approved),
      'result', case when _ephase(e)='result' and e.round > 0 then _eresult(e.id) end)
      from elections e where e.id=(p_d->>'id')::bigint);

  when 'nominate' then
    select * into ok from (select _ephase(e)='rec' from elections e where e.id=(p_d->>'id')::bigint) t;
    if not coalesce(ok,false) then return _err('추천 기간이 아닙니다'); end if;
    delete from nominations where election_id=(p_d->>'id')::bigint and member_id=me.id;
    insert into nominations(election_id, member_id, position, candidate_id, reason, named)
      select (p_d->>'id')::bigint, me.id, k, v::bigint, left(coalesce(p_d->>'reason',''),300), coalesce((p_d->>'named')::boolean,false)
        from jsonb_each_text(coalesce(p_d->'picks','{}'::jsonb)) as j(k, v)
       where v ~ '^\d+$' and k in ('회장','부회장','감독') and exists(select 1 from members m where m.id=v::bigint and m.approved);
    return jsonb_build_object('ok',true);

  when 'electionStart' then
    if me.role <> '회장' then return _err('회장만 투표를 시작할 수 있습니다'); end if;
    xid := (p_d->>'id')::bigint;
    if (select _ephase(e) from elections e where e.id=xid) not in ('rec','confirm') then return _err('이미 투표가 시작되었습니다'); end if;
    if nullif(p_d->>'vote_until','') is null or (p_d->>'vote_until')::timestamptz <= now() then return _err('투표 마감을 정하세요'); end if;
    update elections set round=1 where id=xid;
    insert into candidates(election_id, round, position, candidate_id)
      select xid, 1, k, v::bigint from jsonb_each(coalesce(p_d->'include','{}'::jsonb)) as j(k, arr), jsonb_array_elements_text(arr) as v
       where k in ('회장','부회장','감독') and v ~ '^\d+$' on conflict do nothing;
    if not exists(select 1 from candidates where election_id=xid and round=1) then return _err('후보가 한 명도 없습니다'); end if;
    insert into tallies(election_id, round, position, choice)
      select xid, 1, position, candidate_id::text from candidates where election_id=xid and round=1
      union select xid, 1, position, 'abstain' from candidates where election_id=xid and round=1
      union select xid, 1, position, 'no' from candidates where election_id=xid and round=1 group by position having count(*)=1
      on conflict do nothing;
    update elections set phase='vote', vote_until=(p_d->>'vote_until')::timestamptz where id=xid;
    perform _notify(_ids(null), '🗳 임원 선거', '익명 투표가 시작됐어요', '#/election/'||xid);
    return jsonb_build_object('ok',true);

  when 'electionVote' then
    xid := (p_d->>'id')::bigint;
    select round into pid from elections e where e.id=xid and _ephase(e)='vote';
    if pid is null then return _err('투표 기간이 아닙니다'); end if;
    if exists(select 1 from voted where election_id=xid and round=pid and member_id=me.id) then return _err('이미 투표했습니다'); end if;
    -- 이번 차수 모든 직책을 골라야 함
    if exists(select 1 from (select distinct position from candidates where election_id=xid and round=pid) c
               where not exists(select 1 from tallies t where t.election_id=xid and t.round=pid and t.position=c.position and t.choice = p_d->'picks'->>c.position))
      then return _err('모든 직책을 골라 주세요'); end if;
    insert into voted values(xid, pid, me.id);
    update tallies t set n = t.n + 1 where t.election_id=xid and t.round=pid and t.choice = p_d->'picks'->>t.position;
    return jsonb_build_object('ok',true);

  when 'electionRevote' then
    if me.role <> '회장' then return _err('회장만 재투표를 시작할 수 있습니다'); end if;
    xid := (p_d->>'id')::bigint;
    if (select _ephase(e) from elections e where e.id=xid) <> 'result' then return _err('투표가 끝난 뒤에 할 수 있습니다'); end if;
    if nullif(p_d->>'vote_until','') is null or (p_d->>'vote_until')::timestamptz <= now() then return _err('재투표 마감을 정하세요'); end if;
    select round + 1 into n from elections where id=xid;
    insert into candidates(election_id, round, position, candidate_id)
      select xid, n, r->>'position', (c->>'choice')::bigint
        from jsonb_array_elements(_eresult(xid)) r, jsonb_array_elements(r->'rows') c
       where r->>'status'='tie' and c->>'choice' ~ '^\d+$'
         and (c->>'n')::int = (select max((c2->>'n')::int) from jsonb_array_elements(r->'rows') c2 where c2->>'choice' ~ '^\d+$');
    if not exists(select 1 from candidates where election_id=xid and round=n) then return _err('동점인 직책이 없습니다'); end if;
    insert into tallies(election_id, round, position, choice)
      select xid, n, position, candidate_id::text from candidates where election_id=xid and round=n
      union select xid, n, position, 'abstain' from candidates where election_id=xid and round=n
      on conflict do nothing;
    update elections set phase='vote', round=n, vote_until=(p_d->>'vote_until')::timestamptz where id=xid;
    perform _notify(_ids(null), '🗳 재투표', '동점이라 다시 투표해요', '#/election/'||xid);
    return jsonb_build_object('ok',true);

  -- ───── 코치 지정 (감독·회장) ─────
  when 'coachSet' then
    if me.role not in ('감독','회장') then return _err('감독만 코치를 지정할 수 있습니다'); end if;
    xid := (p_d->>'id')::bigint;
    if (select role from members where id=xid) not in ('회원','코치') then return _err('회원·코치만 바꿀 수 있습니다'); end if;
    update members set role = case when coalesce((p_d->>'on')::boolean,false) then '코치' else '회원' end where id=xid;
    if coalesce((p_d->>'on')::boolean,false) then perform _notify(array[xid], '역할 변경', '코치로 지정되었습니다', '#/me'); end if;
    return jsonb_build_object('ok',true);

  -- ───── 프로필 사진 ─────
  when 'setPhoto' then
    if not _photo_ok(nullif(p_d->>'url','')) then return _err('사진 주소가 올바르지 않습니다'); end if;
    update members set photo=nullif(p_d->>'url','') where id=me.id;
    return jsonb_build_object('ok',true);

  when 'setNote' then
    if me.role <> '회장' then return _err('회장만 수정할 수 있습니다'); end if;
    insert into config values('admin_note', jsonb_build_object('text',coalesce(p_d->>'text','')))
      on conflict(k) do update set v=excluded.v;
    return jsonb_build_object('ok',true);

  when 'mePage' then
    return jsonb_build_object(
      'notis', coalesce((select jsonb_agg(t) from (select id,title,body,link,read,created_at from notis
          where to_id=me.id order by created_at desc limit 50) t),'[]'::jsonb),
      'users', case when me.role='회장' then coalesce((select jsonb_agg(t) from (
          select id,name,role,position,approved,coalesce(video_admin,false) video_admin,photo from members order by approved, id) t),'[]'::jsonb) else '[]'::jsonb end,
      'note', case when me.role='회장' then (select v->>'text' from config where k='admin_note') end,
      'sync', case when me.role in ('회장','부회장') then jsonb_build_object('key_at', (select v->>'at' from config where k='sync_key'),
          'status', (select v from config where k='video_sync_status'), 'count', (select count(*) from videos where sign is not null)) end,
      'storage', case when me.role='회장' then (select coalesce(sum((o.metadata->>'size')::bigint),0) from storage.objects o where o.bucket_id='files') end);

  when 'readAll' then
    update notis set read=true where to_id=me.id and not read;
    return jsonb_build_object('ok',true);

  when 'setUser' then
    if me.role <> '회장' then return _err('회장만 회원을 관리할 수 있습니다'); end if;
    xid := (p_d->>'id')::bigint;
    if p_d ? 'approved' then
      update members set approved=true where id=xid;
      perform _notify(array[xid], '가입 승인', '축구회 가입이 승인되었습니다', '#/');
    end if;
    if p_d ? 'position' then update members set position=coalesce(p_d->>'position','') where id=xid; end if;
    if p_d ? 'video_admin' then
      update members set video_admin=coalesce((p_d->>'video_admin')::boolean,false) where id=xid;
      if coalesce((p_d->>'video_admin')::boolean,false) then
        perform _notify(array[xid], '영상 관리 권한', '경기 영상 가져오기·정리 권한이 생겼습니다', '#/videos');
      end if;
    end if;
    if p_d ? 'role' then
      if xid = me.id then return _err('본인 역할은 회장 인계로만 바꿀 수 있습니다'); end if;
      if p_d->>'role' not in ('회장','부회장','총무','감독','코치','회원') then return _err('잘못된 역할'); end if;
      update members set role=p_d->>'role' where id=xid;
      if p_d->>'role' = '회장' then update members set role='회원' where id=me.id; end if;
      perform _notify(array[xid], '역할 변경', (p_d->>'role')||'(으)로 지정되었습니다', '#/me');
    end if;
    if p_d ? 'pw' then
      if length(coalesce(p_d->>'pw','')) < 4 then return _err('비밀번호는 4자 이상'); end if;
      update members set pw=crypt(p_d->>'pw', gen_salt('bf')) where id=xid;
      delete from sessions where member_id=xid;
    end if;
    return jsonb_build_object('ok',true);

  when 'delUser' then
    if me.role <> '회장' then return _err('회장만 삭제할 수 있습니다'); end if;
    if (p_d->>'id')::bigint = me.id then return _err('본인은 삭제할 수 없습니다'); end if;
    delete from members where id=(p_d->>'id')::bigint;
    return jsonb_build_object('ok',true);

  when 'setPw' then
    if me.pw <> crypt(coalesce(p_d->>'old',''), me.pw) then return _err('현재 비밀번호가 틀립니다'); end if;
    if length(coalesce(p_d->>'new','')) < 4 then return _err('새 비밀번호는 4자 이상'); end if;
    update members set pw=crypt(p_d->>'new', gen_salt('bf')) where id=me.id;
    return jsonb_build_object('ok',true);

  when 'reqs' then
    return jsonb_build_object('list', coalesce((select jsonb_agg(t) from (
      select id,by_name,title,body,status,reply,replied_by,created_at,updated_at from reqs order by id desc limit 300) t),'[]'::jsonb));

  when 'reqSave' then
    if coalesce(trim(p_d->>'title'),'')='' then return _err('제목을 입력하세요'); end if;
    insert into reqs(by_id,by_name,title,body) values(me.id, me.name, trim(p_d->>'title'), coalesce(p_d->>'body',''))
      returning id into xid;
    perform _notify(_ids(array['회장','부회장','총무','감독','코치']), '회원 요청사항', me.name||': '||trim(p_d->>'title'), '#/req/'||xid);
    return jsonb_build_object('id', xid);

  when 'reqReply' then
    if not staff then return _err('운영진만 답변할 수 있습니다'); end if;
    update reqs set status = coalesce(nullif(p_d->>'status',''), status),
      reply = coalesce(p_d->>'reply', reply), replied_by = me.name, updated_at = now()
      where id = (p_d->>'id')::bigint returning by_id into xid;
    if xid is null then return _err('없는 항목입니다'); end if;
    perform _notify(array[xid], '요청사항 답변 ('||coalesce(p_d->>'status','')||')', coalesce(left(p_d->>'reply',30),''), '#/req/'||(p_d->>'id'));
    return jsonb_build_object('ok',true);

  when 'export' then
    return jsonb_build_object('list', coalesce((select jsonb_agg(t) from (
      select id,type,title,category,amount,status,applicant,reason,created_at,paid_at from pays order by id) t),'[]'::jsonb));

  when 'logout' then
    delete from sessions where token::text = p_token;
    return jsonb_build_object('ok',true);

  else return _err('알 수 없는 요청');
  end case;
end $$;

-- 권한: 앱이 부를 수 있는 함수는 4개뿐
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function ping(), register(text,text,text), login(text,text), api(text,text,jsonb), video_sync(text,jsonb,jsonb) to anon, authenticated;

-- 파일 저장소 (사진·회의자료·회칙, 파일당 20MB)
insert into storage.buckets(id,name,public,file_size_limit)
  values('files','files',true,20971520) on conflict(id) do nothing;
drop policy if exists "wxfc upload" on storage.objects;
create policy "wxfc upload" on storage.objects for insert to anon, authenticated with check (bucket_id='files');
-- 보안: 올릴 수 있는 파일 종류 제한 (사진·PDF·문서만, 웹페이지·실행 파일 차단)
update storage.buckets set file_size_limit = 20971520, allowed_mime_types = array[
  'image/jpeg','image/png','image/webp','image/gif','image/heic','application/pdf','text/plain','text/csv',
  'application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.ms-powerpoint','application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'application/haansofthwp','application/x-hwp','application/octet-stream'] where id = 'files';

select _vlink();  -- 이미 있는 영상도 새 기준으로 연결
select '설치 완료' as result;
