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
create table if not exists reqs(
  id bigint generated always as identity primary key,
  by_id bigint, by_name text, title text, body text, status text default '접수',
  reply text default '', replied_by text default '', created_at timestamptz default now(), updated_at timestamptz);
alter table pays add column if not exists skip_vice boolean default false;
create table if not exists polls(
  id bigint generated always as identity primary key,
  meet_id bigint references meets(id) on delete cascade, title text, options jsonb,
  closed boolean default false, deadline timestamptz, by_id bigint, by_name text, created_at timestamptz default now());
create table if not exists matches(
  id bigint generated always as identity primary key,
  title text, opponent text default '', starts_at timestamptz, venue text default '', address text default '', map_url text default '',
  format text default '11인제', need int default 11, memo text default '', deadline timestamptz,
  by_id bigint, by_name text, created_at timestamptz default now());
create table if not exists attends(
  match_id bigint references matches(id) on delete cascade, member_id bigint references members(id) on delete cascade,
  member_name text, status text, at timestamptz default now(), primary key(match_id, member_id));
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
alter table matches enable row level security;
alter table attends enable row level security;

create or replace function _hist(m members, a text, c text) returns jsonb language sql stable as $$
  select jsonb_build_array(jsonb_build_object('who',m.name,'role',m.role,'act',a,'comment',coalesce(c,''),'at',now())) $$;
create or replace function _ids(roles text[]) returns bigint[] language sql stable security definer set search_path=public as $$
  select coalesce(array_agg(id),'{}') from members where approved and (roles is null or role = any(roles)) $$;
create or replace function _notify(ids bigint[], t text, b text, l text) returns void language sql security definer set search_path=public as $$
  insert into notis(to_id,title,body,link) select distinct x,t,b,l from unnest(ids) x where x is not null $$;
create or replace function _err(m text) returns jsonb language sql immutable as $$ select jsonb_build_object('err',m) $$;

create or replace function ping() returns text language sql as $$ select 'ok' $$;

create or replace function register(p_name text, p_pw text) returns jsonb
language plpgsql security definer set search_path=public, extensions as $$
declare n int; m members;
begin
  p_name := trim(coalesce(p_name,''));
  if p_name = '' or length(coalesce(p_pw,'')) < 4 then return _err('이름과 비밀번호(4자 이상)를 입력하세요'); end if;
  if exists(select 1 from members where name = p_name) then return _err('이미 등록된 이름입니다'); end if;
  select count(*) into n from members;
  insert into members(name,pw,role,approved)
    values(p_name, crypt(p_pw, gen_salt('bf')), case when n=0 then '회장' else '회원' end, n=0) returning * into m;
  if n > 0 then perform _notify(_ids(array['회장']), '가입 신청', m.name||'님이 가입을 신청했습니다', '#/me'); end if;
  return jsonb_build_object('ok',true,'approved',m.approved);
end $$;

create or replace function login(p_name text, p_pw text) returns jsonb
language plpgsql security definer set search_path=public, extensions as $$
declare m members; t uuid;
begin
  select * into m from members where name = trim(coalesce(p_name,''));
  if m.id is null or m.pw <> crypt(coalesce(p_pw,''), m.pw) then return _err('이름 또는 비밀번호가 틀립니다'); end if;
  if not m.approved then return _err('회장 승인 대기 중입니다'); end if;
  -- 중복 로그인 방지: 다른 기기의 로그인은 자동 해제
  if exists(select 1 from sessions where member_id = m.id) then
    delete from sessions where member_id = m.id;
    perform _notify(array[m.id], '새 기기에서 로그인됨', '이전 기기는 자동 로그아웃되었습니다. 본인이 아니라면 바로 비밀번호를 바꾸세요', '#/me');
  end if;
  insert into sessions(member_id) values(m.id) returning token into t;
  return jsonb_build_object('token',t);
end $$;

create or replace function api(p_token text, p_action text, p_d jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=public, extensions as $$
declare me members; p pays; mt meets; ok boolean; n int; xid bigint; ns text; staff boolean;
begin
  select m.* into me from sessions s join members m on m.id = s.member_id
   where s.token::text = p_token and m.approved;
  if me.id is null then return jsonb_build_object('err','다른 기기에서 로그인했거나 로그인이 해제되었습니다. 다시 로그인해 주세요','auth',true); end if;
  staff := me.role in ('회장','부회장','총무','감독','코치');
  p_d := coalesce(p_d,'{}');

  case p_action
  when 'me' then
    return jsonb_build_object('me', to_jsonb(me)-'pw', 'unread', (select count(*) from notis where to_id=me.id and not read));

  when 'home' then
    return jsonb_build_object(
      'income', coalesce((select sum(amount) from pays where status='지급완료' and type='수입'),0),
      'spend',  coalesce((select sum(amount) from pays where status='지급완료' and type='지출'),0),
      'notice', (select v->>'text' from config where k='notice'),
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
      'unread', (select count(*) from notis where to_id=me.id and not read));

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
      perform _notify(_ids(null), '경기 일정 등록 · 출석 체크', trim(p_d->>'title'), '#/match/'||xid);
    else
      update matches set title=trim(p_d->>'title'), opponent=coalesce(p_d->>'opponent',''), starts_at=(p_d->>'starts_at')::timestamptz,
        venue=coalesce(p_d->>'venue',''), address=coalesce(p_d->>'address',''), map_url=coalesce(p_d->>'map_url',''),
        format=coalesce(p_d->>'format','11인제'), need=coalesce(nullif(p_d->>'need','')::int,11), memo=coalesce(p_d->>'memo',''),
        deadline=nullif(p_d->>'deadline','')::timestamptz where id=xid;
      perform _notify(array(select member_id from attends where match_id=xid), '경기 정보 변경', trim(p_d->>'title'), '#/match/'||xid);
    end if;
    return jsonb_build_object('id', xid);

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
      'users', coalesce((select jsonb_agg(t) from (select id,name,role,position from members where approved order by id) t),'[]'::jsonb),
      'rules', (select v from config where k='rules'));

  when 'setRules' then
    if me.role not in ('회장','총무') then return _err('회장·총무만 회칙을 등록할 수 있습니다'); end if;
    insert into config values('rules', jsonb_build_object('name',p_d->>'name','url',p_d->>'url','at',now(),'by',me.name))
      on conflict(k) do update set v=excluded.v;
    perform _notify(_ids(null), '회칙 갱신', coalesce(p_d->>'name','회칙'), '#/org');
    return jsonb_build_object('ok',true);

  when 'setNotice' then
    if me.role not in ('회장','총무') then return _err('회장·총무만 공지를 수정할 수 있습니다'); end if;
    insert into config values('notice', jsonb_build_object('text',coalesce(p_d->>'text','')))
      on conflict(k) do update set v=excluded.v;
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
      'notice', (select v->>'text' from config where k='notice'),
      'users', case when me.role='회장' then coalesce((select jsonb_agg(t) from (
          select id,name,role,position,approved from members order by approved, id) t),'[]'::jsonb) else '[]'::jsonb end,
      'note', case when me.role='회장' then (select v->>'text' from config where k='admin_note') end);

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
grant execute on function ping(), register(text,text), login(text,text), api(text,text,jsonb) to anon, authenticated;

-- 파일 저장소 (사진·회의자료·회칙, 파일당 20MB)
insert into storage.buckets(id,name,public,file_size_limit)
  values('files','files',true,20971520) on conflict(id) do nothing;
drop policy if exists "wxfc upload" on storage.objects;
create policy "wxfc upload" on storage.objects for insert to anon, authenticated with check (bucket_id='files');

select '설치 완료' as result;
