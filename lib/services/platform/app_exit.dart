import 'dart:io';

import 'package:kazumi/request/clients/direct_http_client.dart';
import 'package:kazumi/services/platform/tray_service.dart';

class AppExit {
  AppExit._();

  static Future<Never> quit() async {
    try {
      // 本地 CONNECT 隧道按 App 生命周期存活，进程退出前必须注销原生 NetworkCallback，
      // 否则宿主的同进程回调配额只减不增。
      await DirectHttpClient.stopLocalProxy();
    } catch (_) {
      // 退出路径不因清理失败而卡住。
    }
    try {
      await TrayService.dispose();
    } finally {
      exit(0);
    }
  }
}
