#include "view_window.h"

#include <dwmapi.h>

#include <map>
#include <utility>

#include "flutter_window.h"
#include "flutter_windows.h"
#include "resource.h"

namespace {

// 无边框窗口四个角的圆角半径（逻辑像素）。Win11 走 DWM 圆角，Win10 用区域裁剪。
constexpr int kCornerRadiusLogical = 12;

// ---- 两个"已导出但没写进公开头文件"的接口 ----
//
// 见 view_window.h 顶部的说明。声明抄自引擎源码里的
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
// redraw：拖动缩放期间传 FALSE。每帧都带重绘地重设窗口区域会让整窗反复
// 擦除重画，表现就是持续闪烁；松手时再补一次 TRUE 把圆角刷干净即可。
void ApplyRoundedRegion(HWND hwnd, int w, int h, bool apply, BOOL redraw) {
  if (!apply) {
    SetWindowRgn(hwnd, nullptr, redraw);
    return;
  }
  const UINT dpi = GetDpiForWindow(hwnd);
  const int d = Scaled(kCornerRadiusLogical, dpi) * 2;
  HRGN rgn = CreateRoundRectRgn(0, 0, w + 1, h + 1, d, d);
  SetWindowRgn(hwnd, rgn, redraw);
}

// native 这边的 printf 在发布版是丢的（GUI 子系统没有控制台），统一转给 Dart
// 落进 userdata\logs\。引擎还没起来时只能丢——那阶段也没人会看。
void Log(const std::string& message) {
  if (FlutterWindow* w = FlutterWindow::instance()) w->Log(message);
}

}  // namespace

ViewWindow* ViewWindow::ForKey(const std::string& key) {
  // 进程级注册表。窗口对象一旦建立就活到进程结束，和以前函数内 static 的
  // 效果一样，只是现在可以有多个。
  static std::map<std::string, ViewWindow*>* windows =
      new std::map<std::string, ViewWindow*>();

  auto it = windows->find(key);
  if (it != windows->end()) return it->second;

  ViewWindowSpec spec{};
  if (key == "panel") {
    spec = {L"VectraPanelWindow", L"Vectra 设置", 900, 640, 720, 520};
  } else if (key == "market") {
    // 市场要同时放下卡片网格和详情页，比设置窗口宽一点
    spec = {L"VectraMarketWindow", L"Vectra 插件市场", 1000, 680, 760, 540};
  } else {
    return nullptr;
  }

  auto* w = new ViewWindow(key, spec);
  (*windows)[key] = w;
  return w;
}

ViewWindow::ViewWindow(std::string key, const ViewWindowSpec& spec)
    : key_(std::move(key)), spec_(spec) {}

LRESULT CALLBACK ViewWindow::WndProc(HWND hwnd, UINT msg, WPARAM w, LPARAM l) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCT*>(l);
    SetWindowLongPtr(hwnd, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    auto* self = static_cast<ViewWindow*>(cs->lpCreateParams);
    self->hwnd_ = hwnd;
    // 标题栏跟随系统深浅色。20 = DWMWA_USE_IMMERSIVE_DARK_MODE
    BOOL dark = TRUE;
    DwmSetWindowAttribute(hwnd, 20, &dark, sizeof(dark));
  }
  auto* self =
      reinterpret_cast<ViewWindow*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (self) return self->Handle(hwnd, msg, w, l);
  return DefWindowProc(hwnd, msg, w, l);
}

LRESULT ViewWindow::Handle(HWND hwnd, UINT msg, WPARAM w, LPARAM l) {
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
    // 整个客户区都被 Flutter 的子窗口盖着，没有一块地方需要我们擦背景。
    // 返回非 0 表示"已经擦过了"，系统就不会再拿黑色背景刷刷一遍 ——
    // 这是拖动缩放时整窗黑闪的另一半原因（另一半是 WS_CLIPCHILDREN）。
    case WM_ERASEBKGND:
      return 1;
    case WM_ENTERSIZEMOVE:
      in_size_move_ = true;
      return 0;
    case WM_EXITSIZEMOVE: {
      in_size_move_ = false;
      // 拖动期间区域是按 bRedraw=FALSE 设的，松手后补一次带重绘的，
      // 保证圆角最终是干净的
      if (!dwm_round_ok_) {
        RECT rc{};
        GetClientRect(hwnd, &rc);
        ApplyRoundedRegion(hwnd, rc.right - rc.left, rc.bottom - rc.top,
                           !IsZoomed(hwnd), TRUE);
      }
      return 0;
    }
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
        // 同理：拖动中每帧 SetWindowRgn 都带重绘的话，整窗会被反复擦亮擦暗
        ApplyRoundedRegion(hwnd, cw, ch, !IsZoomed(hwnd),
                           in_size_move_ ? FALSE : TRUE);
      }
      return 0;
    }
    case WM_GETMINMAXINFO: {
      // 先让系统填默认值，再覆盖我们关心的几项。直接返回会把 ptMaxTrackSize
      // 之类留成 0，窗口尺寸会出各种怪事。
      const LRESULT r = DefWindowProc(hwnd, msg, w, l);
      const UINT dpi = GetDpiForWindow(hwnd);
      auto* mmi = reinterpret_cast<MINMAXINFO*>(l);
      mmi->ptMinTrackSize.x = Scaled(spec_.min_width, dpi);
      mmi->ptMinTrackSize.y = Scaled(spec_.min_height, dpi);

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

int64_t ViewWindow::Create(int64_t engine_id) {
  if (hwnd_) return view_id_;  // 只建一次

  FlutterDesktopEngineRef engine = FlutterDesktopEngineForId(engine_id);
  if (!engine) {
    Log(key_ + " 窗口：拿不到引擎");
    return -1;
  }

  WNDCLASSEX wc{};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = ViewWindow::WndProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = spec_.class_name;
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
  const int w = Scaled(spec_.width, dpi);
  const int h = Scaled(spec_.height, dpi);
  RECT wa{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0);
  const int x = wa.left + ((wa.right - wa.left) - w) / 2;
  const int y = wa.top + ((wa.bottom - wa.top) - h) / 2;

  // WS_CLIPCHILDREN：界面全部由 Flutter 的子窗口画，父窗口不该再往那块地方
  // 涂东西。不加的话每次 WM_SIZE 父窗口都会把整个客户区先擦一遍（背景刷是
  // 黑的），子窗口随后才重画，拖动缩放时就是整窗一直黑闪。
  const DWORD ex_style = WS_EX_APPWINDOW;
  hwnd_ = CreateWindowEx(ex_style, spec_.class_name, spec_.title,
                         WS_POPUP | WS_CLIPCHILDREN, x, y, w, h, nullptr,
                         nullptr, wc.hInstance, this);
  if (!hwnd_) {
    Log(key_ + " 窗口：建窗口失败 err=" + std::to_string(GetLastError()));
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
  ApplyRoundedRegion(hwnd_, cw, ch, !dwm_round_ok_ && !IsZoomed(hwnd_), TRUE);

  FlutterDesktopViewControllerProperties props{};
  props.width = cw;
  props.height = ch;

  auto* controller = FlutterDesktopEngineCreateViewController(engine, &props);
  if (!controller) {
    Log(key_ + " 窗口：建视图失败");
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

  Log(key_ + " 窗口：视图已建立 viewId=" + std::to_string(view_id_) +
      " 客户区=" + std::to_string(props.width) + "x" +
      std::to_string(props.height));
  return view_id_;
}

void ViewWindow::Show() {
  if (!hwnd_) return;
  // 已最小化就还原，否则只是把它提到前面
  if (IsIconic(hwnd_)) {
    ShowWindow(hwnd_, SW_RESTORE);
  } else {
    ShowWindow(hwnd_, SW_SHOW);
  }
  SetForegroundWindow(hwnd_);
  if (child_) SetFocus(child_);
}

void ViewWindow::Hide() {
  if (hwnd_) ShowWindow(hwnd_, SW_HIDE);
}

bool ViewWindow::visible() const {
  return hwnd_ && IsWindowVisible(hwnd_);
}

// 无边框窗口的标题栏拖动。不能用 WM_NCHITTEST 的 HTCAPTION（Flutter 窗口命中
// 测试失效，见 flutter_window.cpp 里 setRegion 的实测记录），改用经典方案：
// ReleaseCapture + 主动发一条 WM_NCLBUTTONDOWN(HTCAPTION)，系统随即接管鼠标、
// 进入窗口移动循环。由 Flutter 标题栏的指针按下事件触发。
void ViewWindow::DragMove() {
  if (!hwnd_) return;
  ReleaseCapture();
  SendMessage(hwnd_, WM_NCLBUTTONDOWN, HTCAPTION, 0);
}

// 无边框窗口的缩放，和上面的拖动是同一个套路。
//
// 这个窗口没有 WS_THICKFRAME（加了会在 Win10 上画出一圈约 7px 的可见边框），
// 而且就算加了也没用：Flutter 的子窗口铺满整个客户区，鼠标消息全被它吃掉，
// 父窗口的 WM_NCHITTEST 压根不会为客户区内的点触发，系统缩放边缘点不到。
//
// 所以缩放改由 Flutter 侧发起：那边在窗口四周放一圈透明手柄，指针按下时
// 把对应的命中码传过来，这里补一发 WM_NCLBUTTONDOWN，系统随即接管鼠标、
// 进入标准的窗口缩放循环——最小尺寸、贴边、多显示器都由系统照常处理，
// 我们不用自己算一行几何。
void ViewWindow::ResizeFrom(int edge) {
  if (!hwnd_) return;
  // 最大化状态下拖边缘缩放，系统行为是原地把窗口拉变形却仍标记为最大化，
  // 后面点"还原"会跳回一个和屏幕无关的尺寸。直接忽略更干净。
  if (IsZoomed(hwnd_)) return;
  // 只认这八个合法命中码，别让上层随手传个数字进来就发出去
  switch (edge) {
    case HTLEFT:
    case HTRIGHT:
    case HTTOP:
    case HTBOTTOM:
    case HTTOPLEFT:
    case HTTOPRIGHT:
    case HTBOTTOMLEFT:
    case HTBOTTOMRIGHT:
      break;
    default:
      return;
  }
  ReleaseCapture();
  SendMessage(hwnd_, WM_NCLBUTTONDOWN, static_cast<WPARAM>(edge), 0);
}

void ViewWindow::Minimize() {
  if (hwnd_) ShowWindow(hwnd_, SW_MINIMIZE);
}

void ViewWindow::ToggleMaximize() {
  if (!hwnd_) return;
  ShowWindow(hwnd_, IsZoomed(hwnd_) ? SW_RESTORE : SW_MAXIMIZE);
}
