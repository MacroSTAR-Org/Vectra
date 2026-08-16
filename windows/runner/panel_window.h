// 设置窗口：一个普通的 Windows 窗口，在任务栏里有自己的按钮。
//
// 它和磁贴窗口**共用同一个 Flutter 引擎**（也就是同一个 Dart isolate），
// 只是多了一个视图。这一点是整个设计的关键：控制面板要就地修改
// AppSettings / AiSettings / 每张卡片的 size 和 settings，改完 AppRoot 还要
// 把同一个对象读回去（注册快捷键读 state.ai、添加卡片读 state.cards 和桌面
// 的 MediaQuery）。如果面板跑在另一个引擎里，这些共享对象就全断了，得改成
// 二十几个字段的双向同步协议，而 state.json 现在有十一个写入点、每次又是
// 整份重写，两边各持一份状态必然互相覆盖。
//
// 怎么做到一个引擎两个视图：
//   引擎内部本来就是多视图的（views_ 表、next_view_id_、AddView），
//   但 C++ 包装层的 FlutterViewController 只有"顺便新建一个引擎"那一个构造
//   函数。真正需要的 FlutterDesktopEngineCreateViewController 在
//   flutter_windows.dll 里**导出了**，只是没写进随包发布的 flutter_windows.h
//   （它在引擎源码的 flutter_windows_internal.h 里，注释写着"in-progress，
//   完成后会进公开 API"）。所以这里自己声明原型，符号在 .lib 里能链上。
//
// 风险与代价：这是官方标注 in-progress 的接口，升级 Flutter SDK 时它可能改
// 签名或消失。本工程锁在 3.44.9；将来升级时这里是第一个要复验的地方。
// 官方那套 RegularWindowController 代码虽然也在 3.44.9 里，但被
// isWindowingEnabled 硬锁在 master 通道，stable 上用不了。
#ifndef RUNNER_PANEL_WINDOW_H_
#define RUNNER_PANEL_WINDOW_H_

#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdint>
#include <string>

class PanelWindow {
 public:
  static PanelWindow* instance();

  PanelWindow();
  ~PanelWindow();

  // 建窗口 + 在 engine_id 指向的引擎上开第二个视图。
  // 返回视图 id；失败返回 -1。窗口建好后是隐藏的。
  int64_t Create(int64_t engine_id);

  void Show();
  void Hide();
  bool visible() const;
  HWND handle() const { return hwnd_; }

  // 自绘标题栏用：拖动窗口 / 最小化 / 最大化切换（Flutter 那边调用）
  void DragMove();
  void Minimize();
  void ToggleMaximize();

  // 从窗口边缘开始缩放。edge 用 Win32 的 HTLEFT/HTTOPRIGHT 等命中码，
  // 由 Flutter 侧的边缘手柄在指针按下时传进来（缘由见 .cpp 里 ResizeFrom 的注释）。
  void ResizeFrom(int edge);

 private:
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM w, LPARAM l);
  LRESULT Handle(HWND hwnd, UINT msg, WPARAM w, LPARAM l);

  HWND hwnd_ = nullptr;
  HWND child_ = nullptr;  // Flutter 视图的 HWND，跟着窗口大小走
  void* controller_ = nullptr;  // FlutterDesktopViewControllerRef
  int64_t view_id_ = -1;

  // Win11 上 DWM 圆角设置是否生效。生效就走 DWM（区域会盖掉它，两者不能共存），
  // 否则用 SetWindowRgn 裁剪模拟圆角（Win10 没有 DWM 圆角）。
  bool dwm_round_ok_ = false;

  // 是否正处在系统的窗口拖动/缩放模态循环里（WM_ENTERSIZEMOVE ~ WM_EXITSIZEMOVE）。
  // 这期间刻意不带重绘地更新子窗口和窗口区域，否则整窗会一直闪。
  bool in_size_move_ = false;
};

#endif  // RUNNER_PANEL_WINDOW_H_
