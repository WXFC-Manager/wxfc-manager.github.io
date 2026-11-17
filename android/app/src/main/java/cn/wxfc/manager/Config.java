package cn.wxfc.manager;

/** 앱 설정값. 공개되어도 되는 값만 둡니다 (publishable 키는 공개용). */
final class Config {
  static final String HOST = "wxfc-manager.github.io";
  static final String BASE = "https://" + HOST + "/";
  static final String SB = "https://yksmqlinnirkimwimxnh.supabase.co";
  static final String KEY = "sb_publishable_0w85YQNiY0vALbVhtX4ehg_GGp2X2z4";
  static final long POLL_MS = 60_000L;   // 1분마다 새 알림 확인
  private Config() {}
}
