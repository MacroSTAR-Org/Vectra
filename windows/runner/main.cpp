#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <ole2.h>
#include <windows.h>

#include "flutter_window.h"
#include "sidebar_window.h"
#include "smtc.h"
#include "splash_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  //
  // 用 OleInitialize 而不是原来的 CoInitializeEx：它内部就是
  // CoInitializeEx(APARTMENTTHREADED)，额外把 OLE 子系统也起起来。
  // RegisterDragDrop 硬性要求 OLE 已初始化，只 CoInitializeEx 的话
  // 拖放注册会失败（返回 CO_E_NOTINITIALIZED）。
  ::OleInitialize(nullptr);

  // 启动幕布要赶在引擎之前立起来。
  //
  // 下面 FlutterWindow::CreateOverlay 会去构造 FlutterViewController，那一步
  // 阻塞几百毫秒；而磁贴窗口本身要等 Flutter 第一帧才显示。这中间屏幕上什么
  // 都没有，用户只能干等。幕布跑在自己的线程上，这段时间照样能动。
  SplashWindow::instance()->Start(instance);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // 先留一份副本：set_dart_entrypoint_arguments 会把原 vector move 走，
  // 之后再遍历它就是空的（实测 --ai 因此完全没生效）。
  const std::vector<std::string> args_copy = command_line_arguments;

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  // 覆盖整个虚拟屏幕，而不是主显示器：多显示器下卡片可以放到任意一块屏上。
  // SM_XVIRTUALSCREEN / SM_YVIRTUALSCREEN 可能为负（副屏在主屏左侧或上方）。
  const int vx = ::GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int vy = ::GetSystemMetrics(SM_YVIRTUALSCREEN);
  const int vw = ::GetSystemMetrics(SM_CXVIRTUALSCREEN);
  const int vh = ::GetSystemMetrics(SM_CYVIRTUALSCREEN);

  // --raise：让磁贴窗口浮到最前，只为了能截到图。
  //
  // 磁贴常驻 Z 序最底是它的本分，代价是任何屏幕截图都只会拍到压在上面的程序；
  // 而 PrintWindow 对 Flutter 的 DirectComposition 表面只返回全黑（实测），
  // 所以验证磁贴长什么样时需要这么一个开关。平时绝不要用。
  bool raise = false;
  for (const auto& a : args_copy) {
    if (a == "--raise") raise = true;
  }

  FlutterWindow window(project);
  if (!window.CreateOverlay(L"Vectra", vx, vy, vw, vh, /*topmost=*/raise)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // 幕布拉开时要让磁贴同时现身，把窗口句柄给它
  SplashWindow::instance()->SetRevealTarget(window.GetHandle());

  // AI 侧边栏独立成窗口：磁贴常驻最底、侧边栏常驻最前，一个窗口做不到两件事。
  // 它跑第二个 Flutter 引擎（入口 sidebarMain），创建后先隐藏，等快捷键唤出。
  SidebarWindow sidebar(project);
  RECT wa{};
  if (!::SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0)) {
    wa = {0, 0, ::GetSystemMetrics(SM_CXSCREEN), ::GetSystemMetrics(SM_CYSCREEN)};
  }
  const double scale = ::GetDpiForSystem() / 96.0;
  const int sw = static_cast<int>(380 * scale);
  const int sm = static_cast<int>(10 * scale);
  if (!sidebar.CreateOverlay(L"VectraSidebar", wa.right - sw,
                             wa.top + sm, sw, (wa.bottom - sm) - (wa.top + sm),
                             /*topmost=*/true)) {
    return EXIT_FAILURE;
  }
  ::ShowWindow(sidebar.GetHandle(), SW_HIDE);

  // --ai：启动即展开侧边栏。用于验证——合成键鼠会打断用户操作，
  // 需要一个不碰键鼠的入口。
  //
  // --ai-pin：展开并钉住。磁贴窗口在首帧回调里会自己激活一下，侧边栏因此
  // 立刻失去前台、按正常逻辑就该收起；想留着它看一眼就得钉住。
  for (const auto& a : args_copy) {
    if (a == "--ai" || a == "--ai-pin") {
      if (a == "--ai-pin") sidebar.SetPinned(true);
      sidebar.Show();
      break;
    }
  }

  // --test-openpanel：走一遍"侧边栏点齿轮 -> 打开控制面板 AI 页"的跨引擎链路。
  //
  // 为什么要这个开关：这条链路横跨两个 Flutter 引擎（侧边栏 Dart -> 侧边栏通道
  // -> C++ -> 磁贴通道 -> 磁贴 Dart），中间任何一环断了都只表现为"点了没反应"。
  // 而给 IconButton 投合成点击消息实测不生效（DropDock 那种 GestureDetector
  // 可以，Material 的 IconButton 不行），没有这个开关就只能靠人手点。
  for (const auto& a : args_copy) {
    if (a == "--test-openpanel") {
      ::SetTimer(window.GetHandle(), 0x5150, 3000, nullptr);
      break;
    }
  }

  // --smtc-dump：把系统媒体控件里各播放器实际给出的字段原样打到 stdout。
  // 不同播放器给的东西差别很大（浏览器往往没有歌手），得先看真实数据再决定
  // 歌词怎么搜，不能照着文档想当然。
  for (const auto& a : args_copy) {
    if (a == "--smtc-dump") {
      Smtc::DumpOnce();
      break;
    }
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::OleUninitialize();
  return EXIT_SUCCESS;
}
