#include "panel_window.h"

#include <dwmapi.h>

#include <cstdio>

#include "flutter_windows.h"
#include "resource.h"

namespace {

PanelWindow* g_instance = nullptr;

constexpr const wchar_t kClassName[] = L"VectraPanelWindow";
constexpr const wchar_t kTitle[] = L"Vectra 设置";

// 逻辑像素；实际创建时按窗口所在显示器的 DPI 缩放
constexpr int kWidth = 900;
constexpr int kHeight = 640;
constexpr int kMinWidth = 720;
constexpr int kMinHeight = 520;

// 无边框窗口四个角的圆角半径（逻辑像素）。Win11 走 DWM 圆角，Win10 用区域裁剪。
constexpr int kCornerRadiusLogical = 12;

// ---- 两个"已导出但没写进公开头文件"的接口 ----
//
// 见 panel_window.h 顶部的说明。声明抄自引擎源码里的
// flutter_windows_internal.h，符号在 flutter_windows.dll.lib 中。
extern "C" {

struct FlutterDesktopViewControllerProperties {
  int width;
  int height;
};

// 在**已有的**引擎上再开一个视图。与公开的 FlutterDesktopViewControllerCreate
// 的区别只有一条：那个会接管引擎的所有权，这个不会。
FLUTTER_EXPORT FlutterDesktopViewControllerRef
FlutterDesktopEngineCreateViewController(
    FlutterDesktopEngineRef engine,
    const FlutterDesktopViewControllerProperties* properties);

// 按 Dart 侧 PlatformDispatcher.instance.engineId 找回引擎。
// C++ 这边拿不到 flutter::FlutterEngine 内部那个 ref（是私有的），
// 所以绕一圈：Dart 把自己的 engineId 报上来，这里换成引擎指针。
FLUTTER_EXPORT FlutterDesktopEngineRef FlutterDesktopEngineForId(
    int64_t engine_id);

}  // extern "C"

int Scaled(int logical, UINT dpi) {
  return MulDiv(logical, static_cast<int>(dpi), 96);
}

// 无边框窗口的圆角。Win11 用 DWM 圆角（dwm_round_ok_ 时**不要**区域裁剪——
// SetWindowRgn 会把 DWM 的圆角盖掉，两者不能共存）；Win10 用区域裁剪模拟。
// 最大化时铺满屏幕不留圆角。SetWindowRgn 成功后 region 归系统所有。
void ApplyRoundedRegion(HWND hwnd, int w, int h, bool apply) {
  if (!apply) {
    SetWindowRgn(hwnd, nullptr, TRUE);
    return;
  }
  const UINT dpi = GetDpiForWindow(hwnd);
  const int d = Scaled(kCornerRadiusLogical, dpi) * 2;
  HRGN rgn = CreateRoundRectRgn(0, 0, w + 1, h + 1, d, d);
  SetWindowRgn(hwnd, rgn, TRUE);
}

}  // namespace

PanelWindow* PanelWindow::instance() { return g_instance; }

PanelWindow::PanelWindow() { g_instance = this; }

PanelWindow::~PanelWindow() {
  if (g_instance == this) g_instance = nullptr;
}

LRESULT CALLBACK PanelWindow::WndProc(HWND hwnd, UINT msg, WPARAM w,
                                      LPARAM l) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCT*>(l);
    SetWindowLongPtr(hwnd, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    auto* self = static_cast<PanelWindow*>(cs->lpCreateParams);
    self->hwnd_ = hwnd;
    // 标题栏跟随系统深浅色。20 = DWMWA_USE_IMMERSIVE_DARK_MODE
    BOOL dark = TRUE;
    DwmSetWindowAttribute(hwnd, 20, &dark, sizeof(dark));
  }
  auto* self = reinterpret_cast<PanelWindow*>(
      GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (self) return self->Handle(hwnd, msg, w, l);
  return DefWindowProc(hwnd, msg, w, l);
}

LRESULT PanelWindow::Handle(HWND hwnd, UINT msg, WPARAM w, LPARAM l) {
  // 先给 Flutter 处理（DPI 变化、辅助功能等）
  if (controller_) {
    LRESULT result = 0;
    if (FlutterDesktopViewControllerHandleTopLevelWindowProc(
            static_cast<FlutterDesktopViewControllerRef>(controller_), hwnd,
            msg, w, l, &result)) {
      return result;
    }
  }

  switch (msg) {
    case WM_SIZE: {
      // 子视图铺满客户区；缩放后 Win10 的区域圆角要按新尺寸重算
      RECT rc{};
      GetClientRect(hwnd, &rc);
      const int cw = rc.right - rc.left;
      const int ch = rc.bottom - rc.top;
      if (child_) {
        MoveWindow(child_, 0, 0, cw, ch, TRUE);
      }
      if (!dwm_round_ok_) {
        ApplyRoundedRegion(hwnd, cw, ch, !IsZoomed(hwnd));
      }
      return 0;
    }
    case WM_GETMINMAXINFO: {
      // 先让系统填默认值，再覆盖我们关心的几项。直接返回会把 ptMaxTrackSize
      // 之类留成 0，窗口尺寸会出各种怪事。
      const LRESULT r = DefWindowProc(hwnd, msg, w, l);
      const UINT dpi = GetDpiForWindow(hwnd);
      auto* mmi = reinterpret_cast<MINMAXINFO*>(l);
      mmi->ptMinTrackSize.x = Scaled(kMinWidth, dpi);
      mmi->ptMinTrackSize.y = Scaled(kMinHeight, dpi);

      // 最大化范围必须自己算。
      //
      // 这是个无边框窗口（WS_POPUP，没有 WS_CAPTION / WS_THICKFRAME），
      // DefWindowProc 对这类窗口给出的 ptMaxSize 是**整块屏幕**，而不是排除
      // 任务栏后的工作区——普通 WS_OVERLAPPEDWINDOW 窗口才会自动避开任务栏。
      // 不改的话点最大化就变成盖住任务栏的"全屏"。
      //
      // ptMaxPosition 是相对**窗口所在那块显示器**的原点，不是屏幕原点，
      // 所以要减掉 rcMonitor 的左上角，否则多显示器下会跑到主屏去。
      HMONITOR mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      MONITORINFO mi{};
      mi.cbSize = sizeof(mi);
      if (GetMonitorInfo(mon, &mi)) {
        mmi->ptMaxPosition.x = mi.rcWork.left - mi.rcMonitor.left;
        mmi->ptMaxPosition.y = mi.rcWork.top - mi.rcMonitor.top;
        mmi->ptMaxSize.x = mi.rcWork.right - mi.rcWork.left;
        mmi->ptMaxSize.y = mi.rcWork.bottom - mi.rcWork.top;
        // ptMaxTrackSize 保持系统给的值：它限制的是手动拖拽能拉多大，
        // 压到单屏工作区会让窗口没法横跨两块屏。
      }
      return r;
    }
    case WM_CLOSE:
      // 点 X 只收起，不退出——托盘还在，磁贴也还在跑。
      // 真正的退出走托盘菜单。
      Hide();
      return 0;
    case WM_ACTIVATE:
      if (LOWORD(w) != WA_INACTIVE && child_) SetFocus(child_);
      return 0;
    case WM_DESTROY:
      hwnd_ = nullptr;
      return 0;
    default:
      break;
  }
  return DefWindowProc(hwnd, msg, w, l);
}

int64_t PanelWindow::Create(int64_t engine_id) {
  if (hwnd_) return view_id_;  // 只建一次

  FlutterDesktopEngineRef engine = FlutterDesktopEngineForId(engine_id);
  if (!engine) {
    printf("[panel] 拿不到引擎 id=%lld\n", static_cast<long long>(engine_id));
    fflush(stdout);
    return -1;
  }

  WNDCLASSEX wc{};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = PanelWindow::WndProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = kClassName;
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  // 无边框窗口的缩放边缘（非客户区）露出来的底色用黑的，跟深色界面一致
  wc.hbrBackground = reinterpret_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  wc.hIcon = LoadIcon(wc.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
  RegisterClassEx(&wc);

  // 无边框自绘窗口：
  //   WS_POPUP            去掉系统标题栏/边框（标题栏由 Flutter 自绘）
  //   WS_EX_APPWINDOW     WS_POPUP 默认不进任务栏/Alt+Tab，这个样式强制有按钮
  //
  // 不加 WS_THICKFRAME：它在 Win10 上会在窗口四周画出约 7px 的可见边框线
  // （左侧和上方最明显）。它本来的作用是提供系统缩放边缘，但 Flutter 窗口的
  // WM_NCHITTEST 失效（见 flutter_window.cpp 的实测记录），缩放边缘根本点不到
  // —— 只换来一圈丑边框，没有缩放收益，所以直接不缩放，砍掉它。
  const UINT dpi = GetDpiForSystem();
  const int w = Scaled(kWidth, dpi);
  const int h = Scaled(kHeight, dpi);
  RECT wa{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0);
  const int x = wa.left + ((wa.right - wa.left) - w) / 2;
  const int y = wa.top + ((wa.bottom - wa.top) - h) / 2;

  const DWORD ex_style = WS_EX_APPWINDOW;
  hwnd_ = CreateWindowEx(ex_style, kClassName, kTitle, WS_POPUP,
                         x, y, w, h, nullptr, nullptr, wc.hInstance, this);
  if (!hwnd_) {
    printf("[panel] 建窗口失败 err=%lu\n", GetLastError());
    fflush(stdout);
    return -1;
  }

  // ---- 圆角：Win11 走 DWM，Win10 走区域裁剪 ----
  // 33 = DWMWA_WINDOW_CORNER_PREFERENCE，2 = DWMWCP_ROUND
  int corner = 2;
  dwm_round_ok_ =
      SUCCEEDED(DwmSetWindowAttribute(hwnd_, 33, &corner, sizeof(corner)));

  // 玻璃不走 native：WCA 亚克力在这台 Win10 上渲染成整窗透明、还拖慢合成。
  // 和磁贴卡片一样，模糊由 Flutter 侧直接画那张预模糊壁纸（见 panel_app.dart），
  // 这里就是一块普通不透明窗口 + 区域圆角。
  RECT rc{};
  GetClientRect(hwnd_, &rc);
  const int cw = rc.right - rc.left;
  const int ch = rc.bottom - rc.top;
  ApplyRoundedRegion(hwnd_, cw, ch, !dwm_round_ok_ && !IsZoomed(hwnd_));
  FlutterDesktopViewControllerProperties props{};
  props.width = cw;
  props.height = ch;

  auto* controller = FlutterDesktopEngineCreateViewController(engine, &props);
  if (!controller) {
    printf("[panel] 建视图失败\n");
    fflush(stdout);
    DestroyWindow(hwnd_);
    hwnd_ = nullptr;
    return -1;
  }
  controller_ = controller;
  view_id_ = FlutterDesktopViewControllerGetViewId(controller);

  child_ = FlutterDesktopViewGetHWND(
      FlutterDesktopViewControllerGetView(controller));
  // 照抄 Win32Window::SetChildContent 的做法：只 SetParent + MoveWindow。
  // 自己再去改 WS_CHILD 是多余的，Flutter 建出来的视图窗口本来就是子窗口。
  SetParent(child_, hwnd_);
  MoveWindow(child_, 0, 0, props.width, props.height, TRUE);
  SetFocus(child_);

  printf("[panel] 视图已建立 viewId=%lld 客户区=%dx%d\n",
         static_cast<long long>(view_id_), props.width, props.height);
  fflush(stdout);
  return view_id_;
}

void PanelWindow::Show() {
  if (!hwnd_) return;
  RECT before{};
  GetWindowRect(hwnd_, &before);
  printf("[panel] Show 之前 iconic=%d rect=%ld,%ld %ldx%ld\n", IsIconic(hwnd_),
         before.left, before.top, before.right - before.left,
         before.bottom - before.top);
  // 已最小化就还原，否则只是把它提到前面
  if (IsIconic(hwnd_)) {
    ShowWindow(hwnd_, SW_RESTORE);
  } else {
    ShowWindow(hwnd_, SW_SHOW);
  }
  SetForegroundWindow(hwnd_);
  if (child_) SetFocus(child_);
  RECT after{};
  GetWindowRect(hwnd_, &after);
  printf("[panel] Show 之后 iconic=%d visible=%d rect=%ld,%ld %ldx%ld\n",
         IsIconic(hwnd_), IsWindowVisible(hwnd_), after.left, after.top,
         after.right - after.left, after.bottom - after.top);
  fflush(stdout);
}

void PanelWindow::Hide() {
  if (hwnd_) ShowWindow(hwnd_, SW_HIDE);
}

bool PanelWindow::visible() const {
  return hwnd_ && IsWindowVisible(hwnd_);
}

// 无边框窗口的标题栏拖动。不能用 WM_NCHITTEST 的 HTCAPTION（Flutter 窗口命中
// 测试失效，见 flutter_window.cpp 里 setRegion 的实测记录），改用经典方案：
// ReleaseCapture + 主动发一条 WM_NCLBUTTONDOWN(HTCAPTION)，系统随即接管鼠标、
// 进入窗口移动循环。由 Flutter 标题栏的指针按下事件触发。
void PanelWindow::DragMove() {
  if (!hwnd_) return;
  ReleaseCapture();
  SendMessage(hwnd_, WM_NCLBUTTONDOWN, HTCAPTION, 0);
}

void PanelWindow::Minimize() {
  if (hwnd_) ShowWindow(hwnd_, SW_MINIMIZE);
}

void PanelWindow::ToggleMaximize() {
  if (!hwnd_) return;
  ShowWindow(hwnd_, IsZoomed(hwnd_) ? SW_RESTORE : SW_MAXIMIZE);
}
