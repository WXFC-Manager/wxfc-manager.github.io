package cn.wxfc.manager;

import android.content.Context;
import android.content.SharedPreferences;
import androidx.security.crypto.EncryptedSharedPreferences;
import androidx.security.crypto.MasterKeys;

/** 로그인 토큰을 Android Keystore로 암호화해 저장합니다. */
final class Store {
  private static SharedPreferences sp;
  private Store() {}

  static synchronized SharedPreferences get(Context c) {
    if (sp == null) {
      Context app = c.getApplicationContext();
      try {
        String mk = MasterKeys.getOrCreate(MasterKeys.AES256_GCM_SPEC);
        sp = EncryptedSharedPreferences.create("wxfc_secure", mk, app,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM);
      } catch (Exception e) {
        // 일부 기기에서 Keystore 오류가 나면 앱 전용 저장소(다른 앱은 접근 불가)로 대체
        sp = app.getSharedPreferences("wxfc_private", Context.MODE_PRIVATE);
      }
    }
    return sp;
  }
  static String token(Context c) { return get(c).getString("token", null); }
  /** 새 토큰 저장. last=-1 은 '아직 기준점 없음' (과거 알림을 한꺼번에 띄우지 않기 위함). */
  static void setToken(Context c, String t) { get(c).edit().putString("token", t).putLong("last", -1L).apply(); }
  static void clear(Context c) { get(c).edit().remove("token").apply(); }
  static long last(Context c) { return get(c).getLong("last", -1L); }
  static void setLast(Context c, long v) { get(c).edit().putLong("last", v).apply(); }
  static boolean flag(Context c, String k) { return get(c).getBoolean(k, false); }
  static void setFlag(Context c, String k) { get(c).edit().putBoolean(k, true).apply(); }
}
