package cn.wxfc.manager;

import android.Manifest;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import javax.net.ssl.HttpsURLConnection;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * 중국에서는 구글 푸시(FCM)가 막혀 있어서, 앱이 1분마다 서버에 새 알림이 있는지 직접 확인합니다.
 * 휴대폰이 앱을 끄지 않도록 '알림 대기 중' 표시를 띄운 채(포그라운드 서비스) 동작합니다.
 */
public class PollService extends Service {
  static final String CH_RUN = "wxfc_run", CH_ALERT = "wxfc_alert";
  static final int ID_RUN = 1, ID_RELOGIN = 999_999;
  private static final int MAX_BODY = 1 << 20;  // 응답 최대 1MB (비정상 응답 방지)
  private Thread worker;
  private volatile boolean running;

  static void start(Context c) {
    Intent i = new Intent(c, PollService.class);
    if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(i); else c.startService(i);
  }
  static void stop(Context c) { c.stopService(new Intent(c, PollService.class)); }

  @Override public void onCreate() { super.onCreate(); channels(this); }

  @Override public int onStartCommand(Intent intent, int flags, int startId) {
    Notification n = new Notification.Builder(this, CH_RUN)
        .setSmallIcon(R.drawable.ic_stat)
        .setContentTitle("WXFC 알림 대기 중")
        .setContentText("새 결재·요청이 오면 알려 드립니다")
        .setOngoing(true)
        .setContentIntent(open(this, null, 0))
        .build();
    if (Build.VERSION.SDK_INT >= 34) startForeground(ID_RUN, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
    else startForeground(ID_RUN, n);
    if (Store.token(this) == null) { stopSelf(); return START_NOT_STICKY; }
    if (worker == null || !worker.isAlive()) {
      running = true;
      worker = new Thread(this::loop, "wxfc-poll");
      worker.start();
    }
    return START_STICKY;
  }

  private void loop() {
    while (running) {
      try { pollOnce(); } catch (Exception ignored) { /* 네트워크 오류는 다음 주기에 다시 시도 */ }
      try { Thread.sleep(Config.POLL_MS); } catch (InterruptedException e) { return; }
    }
  }

  @Override public void onDestroy() {
    running = false;
    if (worker != null) worker.interrupt();
    super.onDestroy();
  }

  @Override public IBinder onBind(Intent i) { return null; }

  private void pollOnce() throws Exception {
    String tok = Store.token(this);
    if (tok == null) { running = false; stopSelf(); return; }
    long last = Store.last(this);

    JSONObject body = new JSONObject()
        .put("p_token", tok)
        .put("p_action", "notiPoll")
        .put("p_d", new JSONObject().put("after", Math.max(last, 0)));
    HttpsURLConnection c = (HttpsURLConnection) new URL(Config.SB + "/rest/v1/rpc/api").openConnection();
    String txt;
    try {
      c.setConnectTimeout(15_000);
      c.setReadTimeout(20_000);
      c.setInstanceFollowRedirects(false);
      c.setRequestMethod("POST");
      c.setDoOutput(true);
      c.setRequestProperty("apikey", Config.KEY);
      c.setRequestProperty("Authorization", "Bearer " + Config.KEY);
      c.setRequestProperty("Content-Type", "application/json");
      try (OutputStream o = c.getOutputStream()) { o.write(body.toString().getBytes(StandardCharsets.UTF_8)); }
      if (c.getResponseCode() != 200) return;
      try (InputStream in = c.getInputStream()) { txt = readAll(in); }
    } finally { c.disconnect(); }

    JSONObject r = new JSONObject(txt);
    if (r.has("err")) {
      if (r.optBoolean("auth")) {  // 다른 기기에서 로그인 → 토큰 폐기 후 안내
        Store.clear(this);
        alert(this, ID_RELOGIN, "WXFC 다시 로그인 필요", "다른 곳에서 로그인되어 알림이 멈췄습니다. 앱을 열어 다시 로그인하세요.", null);
        running = false;
        stopSelf();
      }
      return;
    }
    long max = r.optLong("max", 0);
    if (last < 0) { Store.setLast(this, max); return; }  // 첫 확인: 기준점만 저장
    JSONArray list = r.optJSONArray("list");
    long hi = last;
    if (list != null) {
      for (int i = 0; i < list.length(); i++) {
        JSONObject n = list.getJSONObject(i);
        long id = n.optLong("id");
        if (id <= last) continue;
        hi = Math.max(hi, id);
        alert(this, (int) (id % 900_000) + 10, clip(n.optString("title", "WXFC"), 60), clip(n.optString("body", ""), 300), n.optString("link", null));
      }
    }
    if (hi > last) Store.setLast(this, hi);
  }

  private static String clip(String s, int n) { return s.length() > n ? s.substring(0, n) + "…" : s; }

  private static String readAll(InputStream in) throws IOException {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    byte[] buf = new byte[8192];
    int r, total = 0;
    while ((r = in.read(buf)) != -1) {
      total += r;
      if (total > MAX_BODY) throw new IOException("response too large");
      out.write(buf, 0, r);
    }
    return out.toString("UTF-8");
  }

  static void alert(Context c, int id, String title, String body, String link) {
    if (Build.VERSION.SDK_INT >= 33 && c.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return;
    Notification n = new Notification.Builder(c, CH_ALERT)
        .setSmallIcon(R.drawable.ic_stat)
        .setContentTitle(title)
        .setContentText(body)
        .setStyle(new Notification.BigTextStyle().bigText(body))
        .setCategory(Notification.CATEGORY_MESSAGE)
        .setVisibility(Notification.VISIBILITY_PRIVATE)   // 잠금 화면에서는 내용 숨김
        .setPublicVersion(new Notification.Builder(c, CH_ALERT).setSmallIcon(R.drawable.ic_stat).setContentTitle("WXFC 새 알림").build())
        .setAutoCancel(true)
        .setContentIntent(open(c, link, id))
        .build();
    c.getSystemService(NotificationManager.class).notify(id, n);
  }

  static PendingIntent open(Context c, String link, int req) {
    Intent i = new Intent(c, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
    if (MainActivity.validLink(link)) i.putExtra("link", link);
    return PendingIntent.getActivity(c, req, i, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
  }

  static void channels(Context c) {
    NotificationManager nm = c.getSystemService(NotificationManager.class);
    NotificationChannel run = new NotificationChannel(CH_RUN, "알림 대기 (항상 표시)", NotificationManager.IMPORTANCE_MIN);
    run.setShowBadge(false);
    nm.createNotificationChannel(run);
    NotificationChannel al = new NotificationChannel(CH_ALERT, "결재·요청 알림", NotificationManager.IMPORTANCE_HIGH);
    al.enableVibration(true);
    al.setLockscreenVisibility(Notification.VISIBILITY_PRIVATE);
    nm.createNotificationChannel(al);
  }
}
