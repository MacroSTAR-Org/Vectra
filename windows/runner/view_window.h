// 次级窗口：任务栏里有自己按钮的无边框窗口，界面由 Flutter 画。
//
// 设置窗口和插件市场都是这种窗口，除了标题、类名和默认尺寸之外没有任何区别，
// 所以共用这一个类，按 key 取实例（见 forKey）。
//
// 之所以不给每个窗口复制一份实现：这个文件里真正花时间的不是"建个窗口"，而是
// 那些踩出来的细节——Win10/Win11 两套圆角、拖动缩放时的黑闪、无边框窗口最大化
// 会盖住任务栏、多显示器下最大化跑到主屏。复制一份就意味着以后每个坑都要修两遍，
// 而漏修的那一份不会有人发现。
//
// 它和磁贴窗口**共用同一个 Flutter 引擎**（也就是同一个 Dart isolate），
// 只是多了一个视图。这一点是整个设计的关键：控制面板要就地修改
// AppSettings / AiSettings / 每张卡片的 size 和 settings，改完 AppRoot 还要
// 把同一个对象读回去（注册快捷键读 state.ai、添加卡片读 state.cards 和桌面
// 的 MediaQuery）。如果面板跑在另一个引擎里，这些共享对象就全断了，得改成
// 二十几个字段的双向同步协议，而 state.json 现在有十一个写入点、每次又是
// 整份重写，两边各持一份状态必然互相覆盖。
//
// 怎么做到一个引擎多个视图：
//   引擎内部本来就是多视图的（views_ 表、next_view_id_、AddView），
//   但 C++ 包装层的 FlutterViewController 只有"顺便新建一个引擎"那一个构造
//   函数。真正需要的 FlutterDesktopEngineCreateViewController 在
//   flutter_windows.dll 里**导出了**，只是没写进随包发布的 flutter_windows.h
//   （它在引擎源码的 flutter_windows_internal.h 里，注释写着"in-progress，
//   完成后会进公开 API"）。所以这里自己声明原型，符号在 .lib 里能链上。
//
// 风险与代价：这是官方标注 in-progress 的接口，升级 Flutter SDK 时它可能改
// 签名或消失。本工程锁在 3.44.9；将来升级时这里是第一个要复验的地方，且
// **所有**次级窗口会一起受影响。官方那套 RegularWindowController 代码虽然也在
// 3.44.9 里，但被 isWindowingEnabled 硬锁在 master 通道，stable 上用不了。
#ifndef RUNNER_VIEW_WINDOW_H_
#define RUNNER_VIEW_WINDOW_H_

#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdint>
#include <string>

// 一个次级窗口的规格。逻辑像素，建窗口时按 DPI 缩放。
struct ViewWindowSpec {
  const wchar_t* class_name;
  const wchar_t* title;
  int width;
  int height;
  int min_width;
  int min_height;
};

class ViewWindow {
 public:
  // 按 key 取窗口对象；key 不认识返回 nullptr。
  //
  // 第一次调用只是把对象建出来（还没有 HWND），真正建窗口在 Create()。
  // 对象一旦建立就活到进程结束——和以前那个函数内 static 的效果一样。
  static ViewWindow* ForKey(const std::string& key);

  // 建窗口 + 在 engine_id 指向的引擎上开一个视图。
  // 返回视图 id；失败返回 -1。窗口建好后是隐藏的。重复调用直接返回已有视图。
  int64_t Create(int64_t engine_id);

  void Show();
  void Hide();
  bool visible() const;

  // 自绘标题栏用：拖动窗口 / 最小化 / 最大化切换（Flutter 那边调用）
  void DragMove();
  void Minimize();
  void ToggleMaximize();

  // 从窗口边缘开始缩放。传的是 Win32 命中码（HTLEFT 那一套）。
  void ResizeFrom(int edge);

  HWND handle() const { return hwnd_; }

 private:
  ViewWindow(std::string key, const ViewWindowSpec& spec);

  static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM w, LPARAM l);
  LRESULT Handle(HWND hwnd, UINT msg, WPARAM w, LPARAM l);

  // 日志前缀，也是 forKey 的键
  std::string key_;
  ViewWindowSpec spec_;

  HWND hwnd_ = nullptr;
  HWND child_ = nullptr;  // Flutter 视图的 HWND，跟着窗口大小走
  void* controller_ = nullptr;  // FlutterDesktopViewControllerRef
  int64_t view_id_ = -1;

  bool dwm_round_ok_ = false;
  bool in_size_move_ = false;
};

#endif  // RUNNER_VIEW_WINDOW_H_
