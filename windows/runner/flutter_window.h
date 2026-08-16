#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

#include "win32_window.h"

// 系统当前是否浅色主题（注册表 AppsUseLightTheme，1=浅色）。
// 主引擎和侧边栏引擎都要用，所以放在头文件里共享。
bool SystemIsLightTheme();

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // 进程内单例：侧边栏那个引擎要请求打开控制面板，只能穿过 native 传话
  // ——两个 Flutter 引擎不共享 isolate，Dart 之间没有直接通路。
  static FlutterWindow* instance();

  // 让磁贴那个引擎打开控制面板并定位到 AI 页
  void OpenAiPanel();

  // 揭幕：把磁贴窗口显示出来。
  //
  // 磁贴窗口原本在 Flutter 第一帧就显示，但那时插件才刚开始编译，卡片是空的，
  // 用户会看着它们一张张往外蹦 —— 启动幕布盖的只是屏幕中间一小块，四周的
  // 卡片全露在外面。所以改成等 Dart 报告全部就绪（splashFinish）再显示，
  // 幕布落下时底下已经是完整的桌面。
  void RevealTiles();

  // 把一行日志转给 Dart，由那边统一落进 userdata\logs\。
  //
  // C++ 这边的 printf 在发布版是丢的：GUI 子系统没有控制台，
  // main.cpp 只在有父控制台或调试器时才 attach（实测 sidebar_window
  // 里早就因此改走 Dart 通道了）。日志系统统一收口后，native 也走这条。
  void Log(const std::string& message);

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Dart 推送命中区矩形的通道。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      method_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
