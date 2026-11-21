// XbotGo → WXFC 경기 영상 자동 연동 (GitHub Actions에서 하루 2번 실행)
// 필요한 GitHub 금고(Secrets): XBOTGO_PHONE, XBOTGO_PW_MD5 (비밀번호 MD5 대문자 32자리. 없으면 XBOTGO_PASSWORD), WXFC_SYNC_KEY
// 보안: 토큰·서명·비밀번호는 절대 로그에 남기지 않습니다. 상태 파일에는 숫자와 오류 요약만 기록합니다.
import crypto from 'node:crypto';
import fs from 'node:fs';

const API = 'https://cloud.xbotgo.net/api';
const SB = 'https://yksmqlinnirkimwimxnh.supabase.co';
const SB_KEY = 'sb_publishable_0w85YQNiY0vALbVhtX4ehg_GGp2X2z4';
const H = { 'BLINK-APP-MODEL': 'WEB', 'BLINK-APP-LANG': 'zh_CN', 'Accept': 'application/json' };
const env = k => (process.env[k] || '').trim();
const md5 = s => crypto.createHash('md5').update(s, 'utf8').digest('hex');
const sha256 = s => crypto.createHash('sha256').update(s, 'utf8').digest('hex');
const status = { ok: false, step: 'start', found: 0, ready: 0, new: 0, linked: 0, fields: [], error: '' };
const clean = s => String(s || '').replace(/[A-Za-z0-9_-]{24,}/g, '***').slice(0, 200);   // 혹시 모를 토큰 노출 방지

async function call(method, path, { params, body, token } = {}) {
  const u = new URL(API + '/' + path.replace(/^\//, ''));
  for (const [k, v] of Object.entries(params || {})) u.searchParams.set(k, String(v));
  const headers = { ...H, ...(token ? { authToken: token } : {}), ...(body ? { 'Content-Type': 'application/json' } : {}) };
  const r = await fetch(u, { method, headers, body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(20000) });
  const j = await r.json().catch(() => ({}));
  if (j.code !== 200) throw new Error(`${path} 실패 (code ${j.code ?? r.status}: ${clean(j.msg)})`);
  return j.data;
}

async function sync(items, st) {
  const r = await fetch(SB + '/rest/v1/rpc/video_sync', {
    method: 'POST', signal: AbortSignal.timeout(20000),
    headers: { apikey: SB_KEY, Authorization: 'Bearer ' + SB_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_key: env('WXFC_SYNC_KEY'), p_items: items, p_status: st }) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || j.err) throw new Error('사이트 저장 실패: ' + clean(j.err || j.message || r.status));
  return j;
}

// 촬영 시각 "2026-11-15 09:18:29" (중국 시간) → ISO
const toIso = s => { const m = String(s || '').match(/^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}(?::\d{2})?)/); return m ? `${m[1]}T${m[2].length == 5 ? m[2] + ':00' : m[2]}+08:00` : '' };
const signOf = u => { try { const x = new URL(u); return x.searchParams.get('sign') || x.searchParams.get('s') || '' } catch (e) { return '' } };
const shape = (raw, url, sign) => { let h = '', path = '', keys = []; try { const x = new URL(url); h = x.host; path = x.pathname.replace(/[A-Za-z0-9_-]{12,}/g, '*'); keys = [...x.searchParams.keys()] } catch (e) {}
  return { type: typeof raw, objKeys: raw && typeof raw === 'object' ? Object.keys(raw).slice(0, 10) : [], host: h, path, params: keys, hasSign: !!sign, len: String(url || '').length } };
const pick = (o, ...ks) => { for (const k of ks) { const v = k.split('.').reduce((a, x) => a && a[x], o); if (v != null && v !== '') return v } return '' };

async function main() {
  const phone = env('XBOTGO_PHONE').replace(/^\+?86/, '').replace(/\D/g, '');
  const pwMd5 = (env('XBOTGO_PW_MD5') || (env('XBOTGO_PASSWORD') ? md5(env('XBOTGO_PASSWORD')) : '')).toUpperCase();
  if (!phone || !/^[0-9A-F]{32}$/.test(pwMd5) || env('WXFC_SYNC_KEY').length < 24) throw new Error('GitHub 금고 값(XBOTGO_PHONE / XBOTGO_PW_MD5 / WXFC_SYNC_KEY)이 비었거나 형식이 다릅니다');

  status.step = 'key';
  const known = new Set((await sync([], null)).known || []);       // 동기화 키 확인 + 이미 등록된 영상

  status.step = 'login';
  const salt = await call('GET', 'user/api/salt', { params: { accountType: 'phone', identifier: phone, phoneRegionCode: '+86' } });
  const credential = sha256(sha256(pwMd5 + salt.salt) + salt.timestamp);
  const login = await call('POST', 'user/api/login/submit', { body: { accountType: 'phone', identifier: phone, credential, sign: salt.sign, timestamp: salt.timestamp, phoneRegionCode: '+86' } });
  const token = login && login.authToken;
  if (!token) throw new Error('로그인 응답에 토큰이 없습니다');

  status.step = 'list';
  const all = []; let complete = false;
  for (let page = 1; page <= 10; page++) {
    const d = await call('GET', 'cloud-drive/api/docs/cloud/docs', { params: { pageNo: page, pageSize: 50, orderBy: 'desc' }, token });
    const list = (d && d.resultList) || [];
    if (page == 1 && list[0]) status.fields = Object.keys(list[0]).slice(0, 30);
    all.push(...list);
    if (list.length < 50 || all.length >= ((d && d.totalRecord) || 0)) { complete = true; break; }
  }
  status.found = all.length;
  const ready = all.filter(v => v && v.docCode && (v.videoStatus == null || v.videoStatus === 1));
  status.ready = ready.length;

  status.step = 'links';
  const items = [];
  for (const v of ready) {
    const base = { doc_code: String(v.docCode), shot_at: toIso(pick(v, 'shootingInfo.shootingTimeStr', 'shootingTimeStr', 'createTime')),
      duration: String(pick(v, 'duration', 'videoDuration', 'shootingInfo.duration') || ''), title: String(pick(v, 'name', 'docName', 'fileName', 'title') || '') };
    // 재생용 MP4 주소(24시간 유효)를 매번 새로 받아 둠 → 사이트 재생기가 바로 사용
    try {
      const vv = await call('POST', 'cloud-drive/api/docs/videoView', { body: { docCode: v.docCode }, token });
      const m = vv && vv.mp4Links && vv.mp4Links[0] && vv.mp4Links[0].url;
      if (m && /^https:\/\//.test(m)) {
        const st = decodeURIComponent(new URL(m).searchParams.get('sign') || '').match(/q-sign-time=(\d+);(\d+)/);
        base.mp4 = m; base.mp4_until = new Date((st ? Number(st[2]) : Date.now() / 1000 + 6 * 3600) * 1000).toISOString();
        status.mp4 = (status.mp4 || 0) + 1;
      }
      if (!base.duration && vv && vv.duration) base.duration = String(vv.duration);
    } catch (e) { status.mp4Err = clean(e.message) }
    if (known.has(base.doc_code)) { items.push(base); continue; }         // 이미 영구 링크 있음 → 재생 주소·정보만 갱신
    const link = await call('GET', 'core/api/docs/perennial/url', { params: { docCode: v.docCode }, token });   // XbotGo '링크 복사'와 같은 영구 링크
    let url = typeof link === 'string' ? link : pick(link || {}, 'url', 'link', 'longLink', 'shortLink');
    let sign = signOf(url);
    if (!sign && /^https?:\/\//.test(url)) {      // 짧은 주소면 따라가서 실제 주소의 sign 확인
      try { const r = await fetch(url, { redirect: 'follow', signal: AbortSignal.timeout(15000) }); sign = signOf(r.url); if (sign) url = r.url; } catch (e) {}
    }
    if (!status.linkShape) status.linkShape = shape(link, url, sign);   // 진단용: 형태만 기록 (값은 기록 안 함)
    if (!sign && !base.mp4) continue;
    items.push({ ...base, sign: sign || null, link: url });
    status.new++;
  }

  status.step = 'save';
  status.ok = true;
  // 전체 목록(영상 코드만)을 함께 보내 XbotGo에서 지운 영상을 사이트에서도 숨기게 함 — 목록을 끝까지 받았을 때만
  const seen = complete ? all.filter(v => v && v.docCode).map(v => String(v.docCode)) : [];
  const r = await sync(items, { ok: true, found: status.found, ready: status.ready, new: status.new, complete, seen });
  status.removed = (r && r.removed) || 0;
  status.linked = r.saved;
  status.step = 'done';
}

if (!env('XBOTGO_PHONE')) { console.log('GitHub 금고가 아직 설정되지 않아 건너뜁니다'); process.exit(0); }
// 10분마다 도는 '확인' 모드: 사이트에서 [새 영상 가져오기] 요청이 있을 때만 실제로 가져옴
if (env('SYNC_MODE') === 'check') {
  const r = await sync([], null).catch(e => ({ err: e.message }));
  if (!r || !r.requested) { console.log('가져오기 요청 없음'); process.exit(0); }
  console.log('가져오기 요청 있음 → 진행');
}
main().catch(async e => {
  status.error = clean(e.message);
  try { await sync([], { ok: false, step: status.step, error: status.error }) } catch (x) {}
  process.exitCode = 1;
}).finally(() => {
  const out = { at: new Date().toISOString(), ...status };
  fs.mkdirSync('sync', { recursive: true });
  fs.writeFileSync('sync/status.json', JSON.stringify(out, null, 1) + '\n');
  console.log(`결과: ${status.ok ? '성공' : '실패'} · 단계 ${status.step} · 영상 ${status.found}개(준비 ${status.ready}, 신규 ${status.new}) ${status.error}`);
});
