-- 영상 자동 숨김 패치 (XbotGo에서 지운 영상)
set search_path=public, extensions;
alter table videos add column if not exists missing int default 0;      -- XbotGo 목록에 연속으로 안 보인 횟수
alter table videos add column if not exists gone boolean default false;  -- 2번 연속 안 보이면 XbotGo에서 지운 것으로 보고 자동 숨김 (다시 보이면 복구)

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
    update videos set missing = 0, hidden = case when gone then false else hidden end, gone = false where doc_code in (select jsonb_array_elements_text(seen)) and (missing <> 0 or gone);
    update videos set missing = missing + 1 where doc_code not in (select jsonb_array_elements_text(seen));
    update videos set gone = true, hidden = true where missing >= 2 and not gone and not hidden;
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
select '설치 완료' as 결과;
