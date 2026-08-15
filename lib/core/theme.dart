/// 深浅色：系统主题检测 + 生效明暗计算。
///
/// native 读注册表 AppsUseLightTheme，WM_SETTINGCHANGE(ImmersiveColorSet)
/// 时刷新。auto 设置跟随系统，light/dark 由用户在面板里显式指定。
library;

import 'package:flutter/material.dart';

import '../model/settings.dart';
import '../native/native_bridge.dart';

/// 系统当前深浅色。native 推过来时更新。
final ValueNotifier<Brightness> systemBrightness =
    ValueNotifier(Brightness.dark);

/// 生效的明暗：auto 跟随系统，否则用用户选择。
Brightness effectiveBrightness(AppSettings s) {
  if (s.theme == 'light') return Brightness.light;
  if (s.theme == 'dark') return Brightness.dark;
  return systemBrightness.value;
}

/// 启动时读一次系统主题，并挂上变化通知。
void initSystemTheme() {
  void apply() {
    NativeBridge.getSystemTheme().then((light) {
      systemBrightness.value = light ? Brightness.light : Brightness.dark;
    }).catchError((_) {});
  }

  apply();
  NativeBridge.onThemeChanged(apply);
}
