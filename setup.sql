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

-- 테이블 직접 접근 금지 (모든 처리는 아래 함수로만)
alter table members enable row level security;
alter table sessions enable row level security;
alter table pays enable row level security;
alter table meets enable row level security;
alter table notis enable row level security;
alter table config enable row level security;

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
  insert into sessions(member_id) values(m.id) returning token into t;
  return jsonb_build_object('token',t);
end $$;

create or replace function api(p_token text, p_action text, p_d jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=public, extensions as $$
declare me members; p pays; mt meets; ok boolean; n int; xid bigint; ns text; staff boolean;
begin
  select m.* into me from sessions s join members m on m.id = s.member_id
   where s.token::text = p_token and m.approved;
  if me.id is null then return jsonb_build_object('err','다시 로그인해 주세요','auth',true); end if;
  staff := me.role in ('회장','부회장','총무');
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
           where (me.role='회장' and status='승인대기') or (me.role='총무' and status='승인')
          union all
          select 'meet', id, title, status from meets
           where (me.role='부회장' and status='부회장검토') or (me.role='회장' and status='회장결재')) t),'[]'::jsonb),
      'meets', coalesce((select jsonb_agg(t) from (select id,title,mdate from meets where status='승인'
          order by mdate desc nulls last, id desc limit 3) t),'[]'::jsonb),
      'recent', coalesce((select jsonb_agg(t) from (select id,title,amount,category,applicant from pays
          where status='지급완료' and type='지출' order by paid_at desc limit 3) t),'[]'::jsonb),
      'unread', (select count(*) from notis where to_id=me.id and not read));

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
    if ok and me.role not in ('회장','총무') then return _err('수입은 회장·총무만 등록할 수 있습니다'); end if;
    insert into pays(type,title,category,amount,reason,receipts,status,applicant_id,applicant,history,paid_at)
    values(case when ok then '수입' else '지출' end, p_d->>'title', coalesce(p_d->>'category','기타'),
      (p_d->>'amount')::numeric, coalesce(p_d->>'reason',''), coalesce(p_d->'receipts','[]'),
      case when ok then '지급완료' else '승인대기' end, me.id, me.name,
      _hist(me, case when ok then '수입 등록' else '결제안 신청' end, ''), case when ok then now() end)
    returning * into p;
    if not ok then perform _notify(_ids(array['회장']), '결제안 승인 요청', me.name||': '||p.title||' ¥'||p.amount, '#/pay/'||p.id); end if;
    return jsonb_build_object('id', p.id);

  when 'payAct' then
    select * into p from pays where id=(p_d->>'id')::bigint;
    if p.id is null then return _err('없는 항목입니다'); end if;
    if p_d->>'act' in ('approve','reject') then
      if me.role <> '회장' or p.status <> '승인대기' then return _err('회장만 승인대기 건을 처리할 수 있습니다'); end if;
      ok := p_d->>'act' = 'approve';
      update pays set status = case when ok then '승인' else '반려' end,
        reject_reason = case when ok then '' else coalesce(p_d->>'comment','') end,
        history = history || _hist(me, case when ok then '승인' else '반려' end, p_d->>'comment') where id=p.id;
      perform _notify(array[p.applicant_id], case when ok then '결제안 승인' else '결제안 반려' end, p.title, '#/pay/'||p.id);
      if ok then perform _notify(_ids(array['총무']), '송금 요청', p.title||' ¥'||p.amount, '#/pay/'||p.id); end if;
    elsif p_d->>'act' = 'paid' then
      if me.role <> '총무' or p.status <> '승인' then return _err('총무만 승인된 건을 지급완료할 수 있습니다'); end if;
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
    return jsonb_build_object('m', to_jsonb(mt));

  when 'meetSave' then
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
      if p_d->>'role' not in ('회장','부회장','총무','회원') then return _err('잘못된 역할'); end if;
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
