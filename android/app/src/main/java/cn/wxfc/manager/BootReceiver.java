package cn.wxfc.manager;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** 휴대폰을 다시 켜거나 앱이 업데이트되면 알림 확인을 자동으로 다시 시작합니다. */
public class BootReceiver extends BroadcastReceiver {
  @Override public void onReceive(Context c, Intent i) {
    String a = i == null ? null : i.getAction();
    if (!Intent.ACTION_BOOT_COMPLETED.equals(a) && !Intent.ACTION_MY_PACKAGE_REPLACED.equals(a)) return; // 다른 방송은 무시
    if (Store.token(c) == null) return;
    try { PollService.start(c); } catch (Exception ignored) { }
  }
}
