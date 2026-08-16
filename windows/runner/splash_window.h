#ifndef RUNNER_SPLASH_WINDOW_H_
#define RUNNER_SPLASH_WINDOW_H_

#include <windows.h>

#include <atomic>

// 启动加载遮罩。
//
// 这不是"仪式感动画"，是一块盖在启动过程上的幕布：磁贴窗口要等 Flutter 首帧
// 才显示，而首帧之后每张卡片还要各自编译插件、跑出第一棵 UI 树。没有它，
// 用户看到的是先黑一会儿、然后卡片一张张往外蹦。
//
// 为什么用 native 独立窗口，而不是在 Flutter 里画：
//   1. 磁贴窗口被 SetWindowRgn 裁成"所有卡片矩形的并集"，画在区域外的东西
//      看不见；要盖住整屏就得临时放开区域 —— 那正是当年 setPanelMode 把磁贴
//      顶到别人窗口上面去的坑。
//   2. Flutter 引擎起来之前那几百毫秒，Dart 侧根本没法画任何东西。
//
// 为什么单独开一个线程：
//   FlutterViewController 的构造会阻塞主线程几百毫秒，那期间主线程不泵消息，
//   动画会僵在原地 —— 而这恰恰是启动里最长的一段空窗。放到自己的线程上，
//   进度条在引擎初始化期间照样是活的。主线程只负责投递消息，不碰这边的 GDI。
// 幕布决定开始拉开时，往磁贴窗口投这条消息，让它同时现身。
//
// 时机交给幕布而不是"一收到全部就绪就显示"：卡片可能一秒内就绪，而幕布还有
// 最短展示时长要走完，那样桌面会先冒出来、幕布再孤零零地挂一会儿 ——
// 用户看到的是"东西都出来了这框还挡着"。同时进行才像幕布拉开。
constexpr UINT kSplashRevealMessage = WM_APP + 10;

class SplashWindow {
 public:
  static SplashWindow* instance();

  // 建窗并显示，立刻返回（窗口跑在自己的线程上）。
  void Start(HINSTANCE instance);

  // 幕布拉开时要一起现身的那个窗口（磁贴主窗口）
  void SetRevealTarget(HWND target) { reveal_target_ = target; }

  // 上报加载进度。ready/total 是"已就绪的卡片数 / 总卡片数"。
  void SetProgress(int ready, int total);

  // 全部就绪：淡出并销毁。不足最短展示时长的话会自动等够再走。
  void Finish();

  // 还活着吗（进程退出时用来判断要不要收拾）
  bool alive() const { return alive_.load(); }

 private:
  static DWORD WINAPI ThreadMain(LPVOID param);
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM w, LPARAM l);

  void RunMessageLoop();
  void Render();
  void Tick();

  HINSTANCE instance_ = nullptr;
  HWND hwnd_ = nullptr;
  HANDLE thread_ = nullptr;
  DWORD thread_id_ = 0;

  // Start() 用它等窗口建好再返回，免得随后的 PostMessage 投了个空
  HANDLE ready_event_ = nullptr;

  // GDI+ 的 token，只在 splash 线程里用
  ULONG_PTR gdiplus_token_ = 0;

  // 窗口像素尺寸（已按 DPI 缩放）
  int w_px_ = 0;
  int h_px_ = 0;
  double scale_ = 1.0;

  // 目标进度与实际显示的进度。显示值向目标值缓动，避免"啪"地跳一格。
  double target_ = 0.0;
  double shown_ = 0.0;
  int ready_ = 0;
  int total_ = 0;

  // 收尾阶段的整体不透明度（1 -> 0）
  double fade_ = 1.0;
  bool finishing_ = false;

  // 揭幕只发一次
  HWND reveal_target_ = nullptr;
  bool reveal_sent_ = false;

  DWORD start_tick_ = 0;
  std::atomic<bool> alive_{false};
};

#endif  // RUNNER_SPLASH_WINDOW_H_
