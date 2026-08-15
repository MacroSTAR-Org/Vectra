#include "sidebar_window.h"

#include <dwmapi.h>

#include "desktop_capture.h"
#include "flutter_window.h"
#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

SidebarWindow* g_instance = nullptr;

constexpr const char kSidebarChannel[] = "vectra/sidebar";

// 侧边栏引擎也要能抓桌面（毛玻璃用）。两个引擎各自独立，主窗口那边注册的
// 通道在这边不存在——实测会报 MissingPluginException。
constexpr const char kNativeChannel[] = "vectra/native";

// 侧边栏宽度（逻辑像素）。Dart 侧也有一份可调的宽度，但窗口必须在引擎起来
// 之前就定尺寸，所以这里先用默认值，Dart 起来后可以通过通道要求改尺寸。
constexpr int kDefaultWidthLogical = 380;
constexpr int kMarginLogical = 10;

// 收起态那个小方块。必须和 Dart 里 drop_dock.dart 的常量一致，
// 否则区域裁在一处、画在另一处。
constexpr int kDockSizeLogical = 56;
// 距窗口右边 / 下边的内缩。窗口本身已经离工作区底边 kMarginLogical(10)，
// 所以下边再缩 4 才和右边的 14 对齐到工作区角落。
constexpr int kDockRightInsetLogical = 14;
constexpr int kDockBottomInsetLogical = 4;

// 刚展开后的宽限期：这段时间内的失活一律不当真（抢前台还没完成）
constexpr DWORD kGraceMs = 400;
constexpr UINT_PTR kGraceTimerId = 1;

}  // namespace

SidebarWindow* SidebarWindow::instance() { return g_instance; }

SidebarWindow::SidebarWindow(const flutter::DartProject& project)
    : project_(project) {
  // 第二个引擎跑独立入口，不会和主窗口的 main() 冲突
  project_.set_dart_entrypoint("sidebarMain");
  g_instance = this;
}

SidebarWindow::~SidebarWindow() {
  if (g_instance == this) g_instance = nullptr;
}

RECT SidebarWindow::TargetRect() const {
  RECT wa{};
  if (!SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0)) {
    wa = {0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN)};
  }
  // 工作区已排除任务栏，所以直接贴着它的右边和上下留白即可
  const UINT dpi = GetDpiForSystem();
  const double scale = dpi / 96.0;
  const int w = static_cast<int>(kDefaultWidthLogical * scale);
  const int m = static_cast<int>(kMarginLogical * scale);
  RECT r{};
  r.left = wa.right - w;
  r.top = wa.top + m;
  r.right = wa.right;
  r.bottom = wa.bottom - m;
  return r;
}

// 收起态用窗口区域裁剪，而不是把窗口缩小。
//
// 缩小窗口这条路走不通，是实测出来的：把窗口从 56x56 改回 380x892 之后，
// Flutter 的渲染表面没有跟着变——框架侧一切正常（rect/MediaQuery 都是
// 380x892、dpr 1.5、窗口 570x1338 物理像素），但屏幕上只画出了左边约 242
// 物理像素，横向被压扁、表头被顶出可视区。窗口在隐藏状态下改尺寸尤其容易
// 触发。既然 dock 关掉时那条路（窗口自始至终不改尺寸）一直好好的，
// 那就一次都别改：窗口永远是整条侧边栏那么大，收起时把区域裁成右下角
// 那个小方块。
RECT SidebarWindow::DockRect() {
  RECT r{};
  GetClientRect(GetHandle(), &r);
  const double scale = GetDpiForSystem() / 96.0;
  const int s = static_cast<int>(kDockSizeLogical * scale);
  RECT d{};
  d.right = r.right - static_cast<int>(kDockRightInsetLogical * scale);
  d.bottom = r.bottom - static_cast<int>(kDockBottomInsetLogical * scale);
  d.left = d.right - s;
  d.top = d.bottom - s;
  return d;
}

bool SidebarWindow::OnCreate() {
  if (!Win32Window::OnCreate()) return false;

  RECT frame = GetClientArea();
  controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!controller_->engine() || !controller_->view()) return false;

  RegisterPlugins(controller_->engine());
  SetChildContent(controller_->view()->GetNativeWindow());

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      controller_->engine()->messenger(), kSidebarChannel,
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "isVisible") {
      // Dart 启动时主动问一次：native 可能在 Dart 注册处理器之前就调过 Show()
      // （--ai 启动就是这种情况），那条 shown 通知会丢，_open 一直是 false，
      // 内容被滑到窗口外，但窗口还在，整块吃掉点击 —— 表现就是"按不动"。
      result->Success(flutter::EncodableValue(visible_));
      return;
    }
    if (call.method_name() == "captureBehind") {
      if (behind_.empty()) {
        result->Success();
        return;
      }
      flutter::EncodableMap out{
          {flutter::EncodableValue("w"), flutter::EncodableValue(behind_w_)},
          {flutter::EncodableValue("h"), flutter::EncodableValue(behind_h_)},
          {flutter::EncodableValue("pixels"),
           flutter::EncodableValue(behind_)},
      };
      result->Success(flutter::EncodableValue(out));
      return;
    }
    if (call.method_name() == "hide") {
      Hide();
      result->Success();
      return;
    }
    if (call.method_name() == "isPinned") {
      // 和 isVisible 同一个理由：native 可能在 Dart 注册处理器之前就把状态
      // 设好了（--ai-pin 就是），不主动问一次，界面上的图钉会和实际不符。
      result->Success(flutter::EncodableValue(pinned_));
      return;
    }
    if (call.method_name() == "setPinned") {
      // 钉住期间不因失活自动收起，否则没法从资源管理器往里拖文件
      const auto* flag = std::get_if<bool>(call.arguments());
      pinned_ = flag && *flag;
      result->Success();
      return;
    }
    if (call.method_name() == "setDock") {
      // Dart 读完配置后告诉这边：收起时是缩成右下角小方块，还是整个隐藏。
      // 启动时窗口是 SW_HIDE 的，所以开着投放点就要在这里把它摆出来。
      const auto* flag = std::get_if<bool>(call.arguments());
      const bool on = flag && *flag;
      if (on != dock_) {
        dock_ = on;
        if (!visible_) {
          if (on) {
            ShowDock();
          } else {
            SetWindowRgn(GetHandle(), nullptr, FALSE);
            ShowWindow(GetHandle(), SW_HIDE);
          }
        }
      }
      result->Success();
      return;
    }
    if (call.method_name() == "openPanel") {
      // 点齿轮：先让磁贴那个引擎把控制面板打开到 AI 页，自己再收起
      if (FlutterWindow* main = FlutterWindow::instance()) main->OpenAiPanel();
      result->Success();
      return;
    }
    if (call.method_name() == "show") {
      // 点收起态那个投放点就展开
      Show();
      result->Success();
      return;
    }
    if (call.method_name() == "resize") {
      // Dart 侧改了侧边栏宽度：重新按工作区摆一次。
      // 收起态不能动窗口尺寸，否则那个 56x56 的投放点会被撑成整条侧边栏。
      if (!visible_) {
        result->Success();
        return;
      }
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      int w = kDefaultWidthLogical;
      if (args) {
        auto it = args->find(flutter::EncodableValue("width"));
        if (it != args->end()) {
          if (const auto* d = std::get_if<double>(&it->second)) {
            w = static_cast<int>(*d);
          } else if (const auto* i = std::get_if<int32_t>(&it->second)) {
            w = *i;
          }
        }
      }
      RECT wa{};
      SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0);
      const double scale = GetDpiForSystem() / 96.0;
      const int pw = static_cast<int>(w * scale);
      const int m = static_cast<int>(kMarginLogical * scale);
      SetWindowPos(GetHandle(), nullptr, wa.right - pw, wa.top + m, pw,
                   (wa.bottom - m) - (wa.top + m),
                   SWP_NOZORDER | SWP_NOACTIVATE);
      result->Success();
      return;
    }
    if (call.method_name() == "getSystemTheme") {
      // 侧边栏引擎也要做深浅色适配，但它和主引擎不共享 isolate，
      // 系统主题得自己查。
      result->Success(flutter::EncodableValue(SystemIsLightTheme()));
      return;
    }
    result->NotImplemented();
  });

  // 复用主窗口那套通道名，但只实现侧边栏用得到的方法
  native_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          controller_->engine()->messenger(), kNativeChannel,
          &flutter::StandardMethodCodec::GetInstance());
  native_channel_->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() == "captureDesktop") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      auto geti = [&](const char* k) {
        if (!args) return 0;
        auto it = args->find(flutter::EncodableValue(k));
        if (it == args->end()) return 0;
        if (const auto* i = std::get_if<int32_t>(&it->second)) return *i;
        if (const auto* d = std::get_if<double>(&it->second))
          return static_cast<int>(*d);
        return 0;
      };
      std::vector<uint8_t> px = CaptureDesktop(geti("w"), geti("h"));
      if (px.empty()) {
        result->Success();
      } else {
        result->Success(flutter::EncodableValue(std::move(px)));
      }
      return;
    }
    // 侧边栏不需要窗口区域裁剪：它是独立窗口，整块都归自己
    if (call.method_name() == "setRegion" ||
        call.method_name() == "setDragging") {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    result->NotImplemented();
  });

  // 拖文件进侧边栏。注册在 FLUTTERVIEW 上而不是顶层窗口：光标下的窗口就是它，
  // OLE 只问那个窗口。IDropTarget 是 COM 对象，不需要碰它的窗口过程。
  HWND view = controller_->view()->GetNativeWindow();
  drop_target_ = std::make_unique<FileDropTarget>(
      // 整个窗口都收：展开时是侧边栏，收起时是右下角那个投放点
      [this](POINT) {
        if (!drop_hover_) {
          drop_hover_ = true;
          if (channel_) {
            channel_->InvokeMethod(
                "dropHover", std::make_unique<flutter::EncodableValue>(true));
          }
        }
        return true;
      },
      [this](POINT, const std::vector<std::wstring>& files) {
        std::vector<std::string> utf8;
        utf8.reserve(files.size());
        for (const auto& f : files) utf8.push_back(Utf8FromUtf16(f.c_str()));
        // 收起态收到文件就顺手展开，用户不必再按一次快捷键
        ShowWithFiles(utf8);
      },
      [this]() {
        if (!drop_hover_) return;
        drop_hover_ = false;
        if (channel_) {
          channel_->InvokeMethod(
              "dropHover", std::make_unique<flutter::EncodableValue>(false));
        }
      });
  if (!RegisterFileDrop(view, drop_target_.get())) {
    drop_target_ = nullptr;
  }

  controller_->ForceRedraw();
  return true;
}

void SidebarWindow::OnDestroy() {
  if (drop_target_ && controller_ && controller_->view()) {
    UnregisterFileDrop(controller_->view()->GetNativeWindow());
  }
  drop_target_ = nullptr;
  controller_ = nullptr;
  channel_ = nullptr;
  native_channel_ = nullptr;
  Win32Window::OnDestroy();
}

void SidebarWindow::SendFiles(const std::vector<std::string>& paths) {
  if (!channel_ || paths.empty()) return;
  flutter::EncodableList list;
  list.reserve(paths.size());
  for (const auto& p : paths) list.push_back(flutter::EncodableValue(p));
  channel_->InvokeMethod(
      "filesDropped",
      std::make_unique<flutter::EncodableValue>(std::move(list)));
}

void SidebarWindow::ShowWithFiles(const std::vector<std::string>& paths) {
  if (!visible_) Show();
  SendFiles(paths);
}

void SidebarWindow::BeginClose() {
  // 不直接 Hide：先让 Dart 播退场动画，播完它会回调 hide。
  // 直接收起的话动画根本来不及被看见。
  if (channel_) {
    channel_->InvokeMethod("requestClose",
                           std::make_unique<flutter::EncodableValue>(true));
  } else {
    Hide();
  }
}

void SidebarWindow::RequestReload() {
  if (!channel_) return;
  channel_->InvokeMethod("reload",
                         std::make_unique<flutter::EncodableValue>(true));
}

void SidebarWindow::Toggle() {
  // 通过 Dart 打日志：C++ 的 printf 到不了重定向的 stdout
  // （GUI 子系统 + AttachConsole 抢走了它），实测确认过。
  if (channel_) {
    channel_->InvokeMethod(
        "log", std::make_unique<flutter::EncodableValue>(
                   visible_ ? "hotkey -> 收起" : "hotkey -> 展开"));
  }
  if (!visible_) {
    Show();
    return;
  }
  BeginClose();
}

void SidebarWindow::ShowDock() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  // 窗口尺寸一动不动，只把区域裁成右下角那个小方块：
  // 区域之外的像素既不绘制也不接收输入，效果等同于"只剩一个小方块"，
  // 但完全不碰渲染表面。
  RECT d = DockRect();
  const double scale = GetDpiForSystem() / 96.0;
  const int r = static_cast<int>(18 * scale * 2);  // 圆角直径，与 Dart 一致
  HRGN rgn = CreateRoundRectRgn(d.left, d.top, d.right + 1, d.bottom + 1, r, r);
  SetWindowRgn(hwnd, rgn, TRUE);  // 成功后 rgn 归系统所有，不能再 DeleteObject
  // SWP_NOACTIVATE：投放点只是常驻在那儿，不该把焦点从用户正在用的程序抢走
  SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

void SidebarWindow::Show() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;

  // 每次显示都按当前工作区重新摆位：任务栏可能换了边或改了自动隐藏
  RECT r = TargetRect();

  // 先抓身后那块屏幕，再显示窗口。顺序不能反 —— 侧边栏浮在所有程序之上，
  // 它模糊的应该是背后那个程序，而不是桌面壁纸；而且窗口一旦可见就会把
  // 自己也拍进去。半分辨率足够，反正马上要高斯模糊。
  //
  // 收起态那个小方块就在侧边栏矩形里面，会被一起拍进背景图，所以先藏起来
  // 再抓。这里只隐藏、不改尺寸——改尺寸会把渲染表面搞坏（见 DockRect 上面
  // 那段实测记录）。
  if (dock_) ShowWindow(hwnd, SW_HIDE);
  SetWindowRgn(hwnd, nullptr, FALSE);  // 展开就是整窗，撤掉投放点的裁剪
  behind_w_ = (r.right - r.left) / 2;
  behind_h_ = (r.bottom - r.top) / 2;
  behind_ = CaptureScreenRegion(r.left, r.top, r.right - r.left,
                                r.bottom - r.top, behind_w_, behind_h_);
  SetWindowPos(hwnd, HWND_TOPMOST, r.left, r.top, r.right - r.left,
               r.bottom - r.top, SWP_SHOWWINDOW);

  // 抢前台。非前台进程直接调 SetForegroundWindow 会被系统拒绝，
  // 标准绕法是先把自己的输入队列附到当前前台线程上借它的资格。
  HWND fg = GetForegroundWindow();
  DWORD fg_thread = GetWindowThreadProcessId(fg, nullptr);
  DWORD my_thread = GetCurrentThreadId();
  bool attached = false;
  if (fg_thread != 0 && fg_thread != my_thread) {
    attached = AttachThreadInput(my_thread, fg_thread, TRUE) != 0;
  }
  SetForegroundWindow(hwnd);
  SetActiveWindow(hwnd);
  SetFocus(hwnd);
  if (attached) AttachThreadInput(my_thread, fg_thread, FALSE);

  visible_ = true;
  shown_at_ = GetTickCount();
  // 宽限期结束后复查一次前台是谁。
  //
  // 光靠"宽限期内忽略 WA_INACTIVE"是不够的：如果那唯一一条失活消息正好落在
  // 宽限期内（--ai 启动时磁贴窗口紧接着自己激活，就是这种情况），它被丢掉之后
  // 再也不会有第二条，侧边栏就永远展开着不收 —— 实测确认过。
  SetTimer(hwnd, kGraceTimerId, kGraceMs + 50, nullptr);
  if (channel_) {
    channel_->InvokeMethod(
        "shown", std::make_unique<flutter::EncodableValue>(true));
  }
}

void SidebarWindow::Hide() {
  if (!visible_) return;
  visible_ = false;
  KillTimer(GetHandle(), kGraceTimerId);
  // 开着投放点就不是真隐藏，而是缩成右下角那个小方块继续待着 ——
  // 它得随时能接住拖过来的文件，藏起来就接不到了。
  if (dock_) {
    ShowDock();
  } else {
    SetWindowRgn(GetHandle(), nullptr, FALSE);
    ShowWindow(GetHandle(), SW_HIDE);
  }
  if (channel_) {
    channel_->InvokeMethod(
        "shown", std::make_unique<flutter::EncodableValue>(false));
  }
}

LRESULT SidebarWindow::MessageHandler(HWND hwnd, UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  // 点到窗口外面就收起。WM_ACTIVATE 的 WA_INACTIVE 正好表示"焦点走了"，
  // 不需要额外装全局钩子，也不会误伤侧边栏内部的点击。
  // 已经收起了就不必再走一遍关闭流程（否则空转，日志里全是噪音）
  // 钉住时完全不理会失活：往里拖文件必须先点资源管理器，那一下就会失活。
  if (message == WM_ACTIVATE && LOWORD(wparam) == WA_INACTIVE && visible_ &&
      !pinned_) {
    // 刚展开的 400ms 内不理会失活：这段时间里抢前台可能还没完成，
    // 系统会先发一次 WA_INACTIVE，照单全收的话侧边栏刚弹出就自己关了。
    // 被忽略的那一条不会补发，所以 Show() 里挂了个定时器兜底复查。
    if (GetTickCount() - shown_at_ > kGraceMs) BeginClose();
    return 0;
  }

  // 宽限期结束的复查：真的不在前台就收起。
  // 这条是兜底 —— 唯一那条 WA_INACTIVE 可能整个落在宽限期里被丢掉了。
  if (message == WM_TIMER && wparam == kGraceTimerId) {
    KillTimer(hwnd, kGraceTimerId);
    if (visible_ && !pinned_ && GetForegroundWindow() != hwnd) BeginClose();
    return 0;
  }

  // 系统深浅色切换（ImmersiveColorSet）→ 通知 Dart 重新查主题。
  // 主窗口那边也有一份同样的处理，两边引擎各自通知。
  if (message == WM_SETTINGCHANGE && lparam != 0) {
    const wchar_t* setting = reinterpret_cast<const wchar_t*>(lparam);
    if (wcscmp(setting, L"ImmersiveColorSet") == 0 && channel_) {
      channel_->InvokeMethod(
          "themeChanged", std::make_unique<flutter::EncodableValue>(true));
      return 0;
    }
  }

  if (controller_) {
    std::optional<LRESULT> result =
        controller_->HandleTopLevelWindowProc(hwnd, message, wparam, lparam);
    if (result) return *result;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void SidebarWindow::OnDisplayChange() {
  HWND hwnd = GetHandle();
  if (!hwnd || !visible_) return;
  RECT r = TargetRect();
  SetWindowPos(hwnd, HWND_TOPMOST, r.left, r.top, r.right - r.left,
               r.bottom - r.top, SWP_NOACTIVATE);
  if (channel_) {
    channel_->InvokeMethod(
        "log", std::make_unique<flutter::EncodableValue>(
                   "display change -> 重摆侧边栏"));
  }
}
