package cn.wxfc.manager;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.ContentValues;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.net.Uri;
import android.net.http.SslError;
import android.os.Build;
import android.os.Bundle;
import android.os.PowerManager;
import android.provider.MediaStore;
import android.provider.Settings;
import android.webkit.JavascriptInterface;
import android.webkit.SslErrorHandler;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.regex.Pattern;

/** 사이트(wxfc-manager.github.io)를 보여주는 화면. 다른 주소는 앱 안에서 열지 않습니다. */
public class MainActivity extends Activity {
  private static final int REQ_FILE = 1, REQ_NOTI = 2;
  private static final Pattern TOKEN = Pattern.compile("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$");
  private static final Pattern LINK = Pattern.compile("^#/[A-Za-z0-9/_-]{0,64}$");
  // 받을 수 있는 파일 이름: WXFC_로 시작, .csv 또는 .json 만
  private static final Pattern FNAME = Pattern.compile("^WXFC_[\\p{L}\\p{N}._-]{1,80}\\.(csv|json)$");
  private WebView web;
  private ValueCallback<Uri[]> fileCb;
  private volatile String curUrl = "";

  static boolean validLink(String l) { return l != null && LINK.matcher(l).matches(); }

  private static boolean isOurs(Uri u) {
    return u != null && "https".equals(u.getScheme()) && Config.HOST.equals(u.getHost());
  }

  @SuppressLint({"SetJavaScriptEnabled", "AddJavascriptInterface"})
  @Override protected void onCreate(Bundle b) {
    super.onCreate(b);
    WebView.setWebContentsDebuggingEnabled(false);
    web = new WebView(this);
    setContentView(web);

    WebSettings s = web.getSettings();
    s.setJavaScriptEnabled(true);
    s.setDomStorageEnabled(true);
    s.setAllowFileAccess(false);
    s.setAllowContentAccess(false);
    s.setAllowFileAccessFromFileURLs(false);
    s.setAllowUniversalAccessFromFileURLs(false);
    s.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
    s.setGeolocationEnabled(false);
    s.setSupportMultipleWindows(false);
    s.setJavaScriptCanOpenWindowsAutomatically(false);
    s.setUserAgentString(s.getUserAgentString() + " WXFCApp/1");

    web.addJavascriptInterface(new Bridge(), "WXFCApp");
    web.setWebViewClient(new WebViewClient() {
      @Override public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest r) {
        Uri u = r.getUrl();
        if (isOurs(u)) return false;   // 우리 사이트만 앱 안에서
        openExternal(u);               // 나머지(고덕지도, 첨부파일 등)는 외부 브라우저로
        return true;
      }
      @Override public void onPageStarted(WebView v, String url, Bitmap f) { curUrl = url == null ? "" : url; }
      @Override public void onReceivedSslError(WebView v, SslErrorHandler h, SslError e) { h.cancel(); } // 인증서 오류는 절대 무시하지 않음
    });
    web.setWebChromeClient(new WebChromeClient() {
      @Override public boolean onShowFileChooser(WebView v, ValueCallback<Uri[]> cb, FileChooserParams p) {
        if (fileCb != null) fileCb.onReceiveValue(null);
        fileCb = cb;
        try {
          Intent i = p.createIntent();
          i.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, p.getMode() == FileChooserParams.MODE_OPEN_MULTIPLE);
          startActivityForResult(i, REQ_FILE);
          return true;
        } catch (Exception e) { fileCb = null; return false; }
      }
    });
    web.setDownloadListener((url, ua, cd, mime, len) -> {
      Uri u = Uri.parse(url);
      if ("https".equals(u.getScheme())) openExternal(u);
      else Toast.makeText(this, "앱을 최신 버전으로 업데이트해 주세요", Toast.LENGTH_LONG).show();
    });

    String link = getIntent().getStringExtra("link");
    web.loadUrl(Config.BASE + (validLink(link) ? link : ""));
    askPermissions();
    if (Store.token(this) != null) PollService.start(this);
  }

  @Override protected void onNewIntent(Intent i) {
    super.onNewIntent(i);
    setIntent(i);
    String link = i.getStringExtra("link");
    if (validLink(link)) web.loadUrl(Config.BASE + link);
  }

  private void openExternal(Uri u) {
    String sc = u == null ? null : u.getScheme();
    if (!"https".equals(sc) && !"http".equals(sc)) return;   // intent:, javascript:, file: 등은 차단
    try { startActivity(new Intent(Intent.ACTION_VIEW, u).addCategory(Intent.CATEGORY_BROWSABLE)); } catch (Exception ignored) { }
  }

  private void askPermissions() {
    if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
      requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, REQ_NOTI);
    }
    PowerManager pm = getSystemService(PowerManager.class);
    if (pm != null && !pm.isIgnoringBatteryOptimizations(getPackageName()) && !Store.flag(this, "asked_battery")) {
      Store.setFlag(this, "asked_battery");
      try {
        @SuppressLint("BatteryLife")
        Intent i = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + getPackageName()));
        startActivity(i);
      } catch (Exception ignored) { }
    }
  }

  @Override protected void onActivityResult(int req, int res, Intent data) {
    super.onActivityResult(req, res, data);
    if (req != REQ_FILE || fileCb == null) return;
    Uri[] out = null;
    if (res == RESULT_OK && data != null) {
      if (data.getClipData() != null) {
        int n = Math.min(data.getClipData().getItemCount(), 10);
        out = new Uri[n];
        for (int k = 0; k < n; k++) out[k] = data.getClipData().getItemAt(k).getUri();
      } else if (data.getData() != null) out = new Uri[]{data.getData()};
    }
    fileCb.onReceiveValue(out);
    fileCb = null;
  }

  @Override public void onBackPressed() {
    if (web != null && web.canGoBack()) web.goBack(); else super.onBackPressed();
  }

  @Override protected void onDestroy() {
    if (web != null) { web.destroy(); web = null; }
    super.onDestroy();
  }

  /** 사이트가 로그인/로그아웃할 때 토큰을 넘겨받는 통로. 우리 사이트에서 온 호출만 받습니다. */
  final class Bridge {
    @JavascriptInterface public void setToken(String t) {
      if (!isOurs(Uri.parse(curUrl))) return;
      if (t == null || t.isEmpty()) {
        Store.clear(MainActivity.this);
        runOnUiThread(() -> PollService.stop(MainActivity.this));
        return;
      }
      if (!TOKEN.matcher(t).matches()) return;
      if (!t.equals(Store.token(MainActivity.this))) Store.setToken(MainActivity.this, t);
      runOnUiThread(() -> PollService.start(MainActivity.this));
    }

    /** 백업(.json)·엑셀(.csv)을 휴대폰 '다운로드/WXFC' 폴더에 저장하고 보내기 창을 띄움. 우리 사이트에서 온 호출만 받습니다. */
    @JavascriptInterface public boolean saveFile(String name, String text) {
      if (!isOurs(Uri.parse(curUrl)) || name == null || text == null || !FNAME.matcher(name).matches() || text.length() > 30_000_000) return false;
      String mime = name.endsWith(".csv") ? "text/csv" : "application/json";
      if (Build.VERSION.SDK_INT < 29) {
        runOnUiThread(() -> Toast.makeText(MainActivity.this, "안드로이드 10 이상에서만 앱 저장이 됩니다. 브라우저에서 받아 주세요", Toast.LENGTH_LONG).show());
        return false;
      }
      try {
        ContentValues v = new ContentValues();
        v.put(MediaStore.Downloads.DISPLAY_NAME, name);
        v.put(MediaStore.Downloads.MIME_TYPE, mime);
        v.put(MediaStore.Downloads.RELATIVE_PATH, "Download/WXFC");
        Uri u = getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, v);
        if (u == null) throw new Exception("insert");
        try (OutputStream o = getContentResolver().openOutputStream(u)) { o.write(text.getBytes(StandardCharsets.UTF_8)); }
        runOnUiThread(() -> {
          Toast.makeText(MainActivity.this, "저장했습니다: 다운로드/WXFC/" + name, Toast.LENGTH_LONG).show();
          try {
            Intent send = new Intent(Intent.ACTION_SEND).setType(mime).putExtra(Intent.EXTRA_STREAM, u).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            startActivity(Intent.createChooser(send, "파일 보내기 (위챗 등) · 닫으면 저장만"));
          } catch (Exception ignored) { }
        });
        return true;
      } catch (Exception e) {
        runOnUiThread(() -> Toast.makeText(MainActivity.this, "저장하지 못했습니다", Toast.LENGTH_LONG).show());
        return false;
      }
    }
  }
}
