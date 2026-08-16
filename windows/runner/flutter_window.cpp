#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <dwmapi.h>
#include <shellapi.h>  // ShellExecuteW（打开日志目录）
#include <windowsx.h>  // GET_X_LPARAM / GET_Y_LPARAM

#include <cstdio>

#include <memory>
#include <optional>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "accent.h"
#include "desktop_capture.h"
#include "hit_region.h"
#include "panel_window.h"
#include "sidebar_window.h"
#include "smtc.h"
#include "utils.h"

namespace {

constexpr const char kChannelName[] = "vectra/native";

// 全局快捷键的标识。只用一个，改快捷键时先注销再重注册。
constexpr int kHotkeyId = 1;

// 开机自启走 HKCU 的 Run 键：不需要管理员权限，也不用装计划任务。
constexpr const wchar_t kRunKeyPath[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr const wchar_t kRunValueName[] = L"Vectra";

std::wstring CurrentExePath() {
  wchar_t buf[MAX_PATH]{};
  const DWORD n = ::GetModuleFileNameW(nullptr, buf, MAX_PATH);
  return std::wstring(buf, n);
}

// Dart 传过来的字符串都是 UTF-8，Win32 的 W 版 API 要 UTF-16。
// utils.h 里只有反方向的 Utf8FromUtf16，这里补上正方向。
std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  const int n = ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                      static_cast<int>(utf8.size()), nullptr, 0);
  if (n <= 0) return std::wstring();
  std::wstring out(static_cast<size_t>(n), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        out.data(), n);
  return out;
}

// 读 Run 键里登记的命令行；没有则返回空串。
std::wstring ReadRunValue() {
  HKEY key = nullptr;
  if (::RegOpenKeyExW(HKEY_CURRENT_USER, kRunKeyPath, 0, KEY_READ, &key) !=
      ERROR_SUCCESS) {
    return L"";
  }
  wchar_t buf[1024]{};
  DWORD size = sizeof(buf);
  DWORD type = 0;
  const LSTATUS st = ::RegQueryValueExW(key, kRunValueName, nullptr, &type,
                                        reinterpret_cast<LPBYTE>(buf), &size);
  ::RegCloseKey(key);
  if (st != ERROR_SUCCESS || type != REG_SZ) return L"";
  return std::wstring(buf, size / sizeof(wchar_t) > 0
                               ? (size / sizeof(wchar_t)) - 1
                               : 0);
}

// 登记的路径两端有引号（路径含空格时必须加），比对前先剥掉。
std::wstring StripQuotes(const std::wstring& s) {
  if (s.size() >= 2 && s.front() == L'"' && s.back() == L'"') {
    return s.substr(1, s.size() - 2);
  }
  return s;
}

bool WriteRunValue(const std::wstring& command) {
  HKEY key = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, kRunKeyPath, 0, nullptr, 0,
                        KEY_WRITE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
    return false;
  }
  const LSTATUS st = ::RegSetValueExW(
      key, kRunValueName, 0, REG_SZ,
      reinterpret_cast<const BYTE*>(command.c_str()),
      static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  ::RegCloseKey(key);
  return st == ERROR_SUCCESS;
}

bool DeleteRunValue() {
  HKEY key = nullptr;
  if (::RegOpenKeyExW(HKEY_CURRENT_USER, kRunKeyPath, 0, KEY_WRITE, &key) !=
      ERROR_SUCCESS) {
    return true;  // 键都不在，等于已经关了
  }
  const LSTATUS st = ::RegDeleteValueW(key, kRunValueName);
  ::RegCloseKey(key);
  return st == ERROR_SUCCESS || st == ERROR_FILE_NOT_FOUND;
}

// 把窗口区域设成所有卡片圆角矩形的并集。区域之外的部分既不绘制也不接收输入。
void ApplyWindowRegion(HWND hwnd, const std::vector<HitRect>& rects) {
  HRGN combined = CreateRectRgn(0, 0, 0, 0);
  for (const auto& r : rects) {
    const int d = static_cast<int>(r.radius * 2);
    // CreateRoundRectRgn 的右/下边界是开区间，要 +1 才能覆盖到最后一列/行
    HRGN one = CreateRoundRectRgn(
        static_cast<int>(r.x), static_cast<int>(r.y),
        static_cast<int>(r.x + r.w) + 1, static_cast<int>(r.y + r.h) + 1, d, d);
    CombineRgn(combined, combined, one, RGN_OR);
    DeleteObject(one);
  }
  // SetWindowRgn 成功后由系统接管 combined 的生命周期，不能再 DeleteObject
  SetWindowRgn(hwnd, combined, TRUE);
}

// Dart 每次卡片位置变化时推下一批矩形；C++ 侧只负责存和查，不做业务判断。
void HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result,
    HWND hwnd) {
  if (call.method_name() == "setRegion") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (!args) {
      result->Error("bad_args", "expected a map with cards/extra");
      return;
    }
    auto parse = [](const flutter::EncodableValue& value) {
      std::vector<HitRect> out;
      const auto* list = std::get_if<flutter::EncodableList>(&value);
      if (!list) return out;
      out.reserve(list->size());
      for (const auto& item : *list) {
        const auto* map = std::get_if<flutter::EncodableMap>(&item);
        if (!map) continue;
        auto number = [&](const char* key, double fallback) -> double {
          auto it = map->find(flutter::EncodableValue(key));
          if (it == map->end()) return fallback;
          if (const auto* d = std::get_if<double>(&it->second)) return *d;
          if (const auto* i = std::get_if<int32_t>(&it->second)) return *i;
          if (const auto* i64 = std::get_if<int64_t>(&it->second))
            return static_cast<double>(*i64);
          return fallback;
        };
        out.push_back(HitRect{number("x", 0), number("y", 0), number("w", 0),
                              number("h", 0), number("radius", 26)});
      }
      return out;
    };

    auto find = [&](const char* key) -> flutter::EncodableValue {
      auto it = args->find(flutter::EncodableValue(key));
      return it == args->end() ? flutter::EncodableValue() : it->second;
    };

    std::vector<HitRect> cards = parse(find("cards"));
    // extra 只进窗口区域、不进命中判定：拖拽辅助线要看得见，但点上去
    // 应该穿透到桌面，而不是被这条 2px 的细线接住。
    std::vector<HitRect> extra = parse(find("extra"));

    std::vector<HitRect> region = cards;
    region.insert(region.end(), extra.begin(), extra.end());

    // WM_NCHITTEST 在 Flutter 的窗口结构下不生效：顶层和 FLUTTERVIEW 子窗口
    // 两处都返回 HTTRANSPARENT，桌面依然收不到点击（已用"强制永远穿透"的控制
    // 实验确认）。改用 SetWindowRgn —— 区域之外的像素在系统看来不属于本窗口，
    // 命中与消息路由都会自然落到下层。
    ApplyWindowRegion(hwnd, region);
    HitRegion::Instance().SetRects(std::move(cards));
    result->Success();
    return;
  }

  // 这里原先有 setPanelMode：控制面板画在磁贴这个全屏窗口里时，需要临时
  // 解除窗口区域裁剪、把窗口顶到最前、还要用 AttachThreadInput 抢前台。
  // 面板已经搬进任务栏里的独立窗口（见 panel_window.h），这段整块删除——
  // 那段抢前台的代码正是磁贴被顶到浏览器和 QQ 上面去的根源。

  if (call.method_name() == "setBackdrop") {
    // Windows 11 的系统背景材质。窗口区域已被裁成卡片形状，所以材质会
    // 恰好只出现在卡片里 —— 正是"每张磁贴是一块毛玻璃"想要的效果。
    //
    // DWMWA_SYSTEMBACKDROP_TYPE = 38，取值：
    //   0 AUTO / 1 NONE / 2 MAINWINDOW(云母) / 3 TRANSIENTWINDOW(亚克力)
    // 需要 Windows 11 22621+。旧系统上调用会失败，把结果回传给 Dart，
    // 由 Dart 回退到不透明底色，而不是留下一张全黑的卡片。
    const auto* v = std::get_if<int32_t>(call.arguments());
    int type = v ? *v : 1;

    // 实测记录（两条都失败，别再走回头路）：
    //   1. DwmExtendFrameIntoClientArea(-1)：把窗口框架玻璃铺满整个窗口矩形，
    //      框架不受 SetWindowRgn 约束 —— 整个桌面糊成一片灰。
    //   2. DWMWA_SYSTEMBACKDROP_TYPE（云母/亚克力）：同样按整个窗口矩形绘制，
    //      去掉上面那句之后依然整屏发灰。它和区域裁剪天生不兼容。
    //
    // 改用 Win10 时代的 SetWindowCompositionAttribute 亚克力模糊：
    // 它画的是窗口自身的背景，受窗口区域裁剪。
    int backdrop_none = 1;  // DWMSBT_NONE，先确保系统材质是关的
    DwmSetWindowAttribute(hwnd, 38, &backdrop_none, sizeof(backdrop_none));

    const bool ok = ApplyAccentBlur(hwnd, type != 1);
    result->Success(flutter::EncodableValue(ok));
    return;
  }

  if (call.method_name() == "captureDesktop") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    auto geti = [&](const char* k, int def) {
      if (!args) return def;
      auto it = args->find(flutter::EncodableValue(k));
      if (it == args->end()) return def;
      if (const auto* i = std::get_if<int32_t>(&it->second)) return *i;
      if (const auto* d = std::get_if<double>(&it->second))
        return static_cast<int>(*d);
      return def;
    };
    const int w = geti("w", 0);
    const int h = geti("h", 0);
    std::vector<uint8_t> pixels = CaptureDesktop(w, h);
    if (pixels.empty()) {
      result->Success();  // 交给 Dart 回退到读壁纸文件
    } else {
      result->Success(flutter::EncodableValue(std::move(pixels)));
    }
    return;
  }

  if (call.method_name() == "setDragging") {
    const auto* flag = std::get_if<bool>(call.arguments());
    const bool on = flag && *flag;
    HitRegion::Instance().SetDragging(on);
    if (on) {
      // 整窗放开，拖拽期间不再有任何 SetWindowRgn
      SetWindowRgn(hwnd, nullptr, TRUE);
    }
    // 关闭时什么都不做：Dart 会在 _endDrag 里推一次 setRegion 恢复
    result->Success();
    return;
  }

  if (call.method_name() == "registerHotkey") {
    // 全局快捷键。RegisterHotKey 把 WM_HOTKEY 投递到指定窗口，
    // 所以不需要装钩子，也不需要额外线程。
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    auto geti = [&](const char* k, int def) {
      if (!args) return def;
      auto it = args->find(flutter::EncodableValue(k));
      if (it == args->end()) return def;
      if (const auto* i = std::get_if<int32_t>(&it->second)) return *i;
      if (const auto* d = std::get_if<double>(&it->second))
        return static_cast<int>(*d);
      return def;
    };
    // 先注销旧的，否则改快捷键之后两个都会生效
    UnregisterHotKey(hwnd, kHotkeyId);
    const int mods = geti("mods", 0);
    const int vk = geti("vk", 0);
    if (vk == 0) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    // MOD_NOREPEAT：按住不放时只触发一次
    const BOOL ok = RegisterHotKey(hwnd, kHotkeyId, mods | 0x4000, vk);
    result->Success(flutter::EncodableValue(ok != FALSE));
    return;
  }

  // 这里原先有 setTopmost：AI 侧边栏还和磁贴共用一个窗口时用它把窗口顶起来。
  // 侧边栏拆成独立窗口之后 Dart 侧再没调过，是死代码，删除。

  if (call.method_name() == "getWorkArea") {
    // 主显示器的工作区：屏幕范围减去任务栏等应用栏。
    // 侧边栏用它决定上下边界，免得压在任务栏上面。
    RECT wa{};
    if (!SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0)) {
      result->Success();
      return;
    }
    flutter::EncodableMap area{
        {flutter::EncodableValue("x"), flutter::EncodableValue(static_cast<int32_t>(wa.left))},
        {flutter::EncodableValue("y"), flutter::EncodableValue(static_cast<int32_t>(wa.top))},
        {flutter::EncodableValue("w"), flutter::EncodableValue(static_cast<int32_t>(wa.right - wa.left))},
        {flutter::EncodableValue("h"), flutter::EncodableValue(static_cast<int32_t>(wa.bottom - wa.top))},
    };
    result->Success(flutter::EncodableValue(area));
    return;
  }

  if (call.method_name() == "smtcState") {
    // 首次调用才起工作线程：没装歌词插件的用户不该白白多一条线程 + 每 250ms
    // 一次 WinRT 调用。Start() 是幂等的。
    Smtc::Instance().Start();
    const SmtcSnapshot s = Smtc::Instance().Snapshot();
    auto str = [](const std::string& v) { return flutter::EncodableValue(v); };
    auto i64 = [](int64_t v) { return flutter::EncodableValue(v); };
    flutter::EncodableMap out{
        {flutter::EncodableValue("available"), flutter::EncodableValue(s.available)},
        {flutter::EncodableValue("app"), str(s.app)},
        {flutter::EncodableValue("title"), str(s.title)},
        {flutter::EncodableValue("artist"), str(s.artist)},
        {flutter::EncodableValue("album"), str(s.album)},
        {flutter::EncodableValue("status"), flutter::EncodableValue(s.status)},
        {flutter::EncodableValue("canPlay"), flutter::EncodableValue(s.can_play)},
        {flutter::EncodableValue("canPause"), flutter::EncodableValue(s.can_pause)},
        {flutter::EncodableValue("canNext"), flutter::EncodableValue(s.can_next)},
        {flutter::EncodableValue("canPrev"), flutter::EncodableValue(s.can_prev)},
        {flutter::EncodableValue("canSeek"), flutter::EncodableValue(s.can_seek)},
        {flutter::EncodableValue("position"), i64(s.position_ms)},
        {flutter::EncodableValue("duration"), i64(s.duration_ms)},
        {flutter::EncodableValue("positionAge"), i64(s.position_age_ms)},
        {flutter::EncodableValue("updatedAt"), i64(s.updated_at_ms)},
        {flutter::EncodableValue("artId"), flutter::EncodableValue(s.art_id)},
    };
    result->Success(flutter::EncodableValue(out));
    return;
  }

  if (call.method_name() == "smtcArt") {
    // 封面字节按版本号取：号对不上说明调用方拿的是过期版本，返回空让它重取。
    // 这样封面每首歌只搬一次，而不是每次轮询都搬十几万字节。
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    int want = -1;
    if (args) {
      auto it = args->find(flutter::EncodableValue("id"));
      if (it != args->end()) {
        if (const auto* i = std::get_if<int32_t>(&it->second)) want = *i;
      }
    }
    std::vector<uint8_t> bytes = Smtc::Instance().Art(want);
    if (bytes.empty()) {
      result->Success();
    } else {
      result->Success(flutter::EncodableValue(std::move(bytes)));
    }
    return;
  }

  if (call.method_name() == "smtcControl") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    std::string cmd;
    int64_t pos = 0;
    if (args) {
      auto it = args->find(flutter::EncodableValue("cmd"));
      if (it != args->end()) {
        if (const auto* s = std::get_if<std::string>(&it->second)) cmd = *s;
      }
      auto p = args->find(flutter::EncodableValue("posMs"));
      if (p != args->end()) {
        if (const auto* v = std::get_if<int64_t>(&p->second)) {
          pos = *v;
        } else if (const auto* v32 = std::get_if<int32_t>(&p->second)) {
          pos = *v32;
        } else if (const auto* d = std::get_if<double>(&p->second)) {
          pos = static_cast<int64_t>(*d);
        }
      }
    }
    if (cmd.empty()) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    Smtc::Instance().Start();
    result->Success(flutter::EncodableValue(Smtc::Instance().Control(cmd, pos)));
    return;
  }

  if (call.method_name() == "createPanelView") {
    // Dart 把自己的 engineId 报上来，这边据此在**同一个引擎**上再开一个视图。
    // 之所以要 Dart 报：C++ 拿不到 flutter::FlutterEngine 内部那个
    // FlutterDesktopEngineRef（私有成员，只有 FlutterViewController 是友元）。
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    int64_t engine_id = 0;
    if (args) {
      auto it = args->find(flutter::EncodableValue("engineId"));
      if (it != args->end()) {
        if (const auto* v = std::get_if<int64_t>(&it->second)) {
          engine_id = *v;
        } else if (const auto* v32 = std::get_if<int32_t>(&it->second)) {
          engine_id = *v32;
        }
      }
    }
    if (engine_id == 0) {
      result->Success(flutter::EncodableValue(static_cast<int64_t>(-1)));
      return;
    }
    static PanelWindow panel;
    result->Success(flutter::EncodableValue(panel.Create(engine_id)));
    return;
  }

  if (call.method_name() == "showPanelWindow") {
    if (PanelWindow* p = PanelWindow::instance()) p->Show();
    result->Success();
    return;
  }

  if (call.method_name() == "hidePanelWindow") {
    if (PanelWindow* p = PanelWindow::instance()) p->Hide();
    result->Success();
    return;
  }

  // 自绘标题栏：Flutter 侧把指针事件发过来，native 这边操作窗口
  if (call.method_name() == "panelDragMove") {
    if (PanelWindow* p = PanelWindow::instance()) p->DragMove();
    result->Success();
    return;
  }
  if (call.method_name() == "panelMinimize") {
    if (PanelWindow* p = PanelWindow::instance()) p->Minimize();
    result->Success();
    return;
  }
  if (call.method_name() == "panelToggleMaximize") {
    if (PanelWindow* p = PanelWindow::instance()) p->ToggleMaximize();
    result->Success();
    return;
  }
  if (call.method_name() == "panelResize") {
    const auto* edge = std::get_if<int32_t>(call.arguments());
    if (!edge) {
      result->Error("bad_args", "expected an int hit-test code");
      return;
    }
    if (PanelWindow* p = PanelWindow::instance()) p->ResizeFrom(*edge);
    result->Success();
    return;
  }

  if (call.method_name() == "reloadSidebar") {
    // 控制面板改完 AI 配置：叫侧边栏那个引擎重新读一遍 state.json。
    // 两个引擎不共享 isolate，配置靠磁盘交接，得有人说"文件变了"。
    if (SidebarWindow* sb = SidebarWindow::instance()) sb->RequestReload();
    result->Success();
    return;
  }

  // 在资源管理器里打开日志目录（面板"关于"页那个按钮）。
  //
  // 目录不存在也照开：ShellExecute 会弹一个"找不到"的框，比"点了没反应"
  // 清楚。真正的日志目录在第一条日志写下去时就建好了，正常不会缺。
  if (call.method_name() == "openLogDir") {
    const auto* dir = std::get_if<std::string>(call.arguments());
    if (!dir || dir->empty()) {
      result->Error("bad_args", "openLogDir 需要目录路径");
      return;
    }
    const std::wstring wdir = Utf8ToWide(*dir);
    ::ShellExecuteW(nullptr, L"open", wdir.c_str(), nullptr, nullptr,
                    SW_SHOWNORMAL);
    result->Success();
    return;
  }

  if (call.method_name() == "getWindowRect") {
    RECT rect{};
    ::GetWindowRect(hwnd, &rect);
    flutter::EncodableMap out{
        {flutter::EncodableValue("x"), flutter::EncodableValue(static_cast<int32_t>(rect.left))},
        {flutter::EncodableValue("y"), flutter::EncodableValue(static_cast<int32_t>(rect.top))},
        {flutter::EncodableValue("w"), flutter::EncodableValue(static_cast<int32_t>(rect.right - rect.left))},
        {flutter::EncodableValue("h"), flutter::EncodableValue(static_cast<int32_t>(rect.bottom - rect.top))},
    };
    result->Success(flutter::EncodableValue(out));
    return;
  }

  // 系统是否浅色主题。深浅色适配用。
  if (call.method_name() == "getSystemTheme") {
    result->Success(flutter::EncodableValue(SystemIsLightTheme()));
    return;
  }

  // 是否已登记开机自启。
  //
  // 便携版会被整个文件夹搬走，搬完之后 Run 键里还指着老路径，自启就悄悄失效了。
  // 所以这里发现登记的路径和当前 exe 对不上时顺手改成当前路径——用户的意图是
  // 「开机启动 Vectra」，不是「开机启动某个特定路径」。
  if (call.method_name() == "isAutoStart") {
    const std::wstring recorded = StripQuotes(ReadRunValue());
    if (recorded.empty()) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    const std::wstring current = CurrentExePath();
    if (::_wcsicmp(recorded.c_str(), current.c_str()) != 0) {
      WriteRunValue(L"\"" + current + L"\"");
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }

  // 开关开机自启。返回写完之后的实际状态，Dart 侧据此回填开关。
  if (call.method_name() == "setAutoStart") {
    const auto* on = std::get_if<bool>(call.arguments());
    if (!on) {
      result->Error("bad_args", "expected a bool");
      return;
    }
    const bool ok =
        *on ? WriteRunValue(L"\"" + CurrentExePath() + L"\"") : DeleteRunValue();
    if (!ok) {
      result->Error("registry_failed", "无法写入注册表 Run 键");
      return;
    }
    result->Success(flutter::EncodableValue(*on));
    return;
  }

  // 当前所有显示器的物理矩形 + 设备名。多显示器适配用：Dart 靠它判断每张
  // 卡片在哪块屏上、拔掉屏时往哪迁移。
  if (call.method_name() == "getMonitors") {
    flutter::EncodableList list;
    auto cb = [](HMONITOR mon, HDC, LPRECT rc, LPARAM lparam) -> BOOL {
      auto* out = reinterpret_cast<flutter::EncodableList*>(lparam);
      MONITORINFOEXW mi{};
      mi.cbSize = sizeof(mi);
      if (GetMonitorInfoW(mon, &mi)) {
        flutter::EncodableMap m{
            {flutter::EncodableValue("id"),
             flutter::EncodableValue(Utf8FromUtf16(mi.szDevice))},
            {flutter::EncodableValue("x"),
             flutter::EncodableValue(static_cast<int32_t>(mi.rcMonitor.left))},
            {flutter::EncodableValue("y"),
             flutter::EncodableValue(static_cast<int32_t>(mi.rcMonitor.top))},
            {flutter::EncodableValue("w"),
             flutter::EncodableValue(static_cast<int32_t>(
                 mi.rcMonitor.right - mi.rcMonitor.left))},
            {flutter::EncodableValue("h"),
             flutter::EncodableValue(static_cast<int32_t>(
                 mi.rcMonitor.bottom - mi.rcMonitor.top))},
        };
        out->push_back(flutter::EncodableValue(std::move(m)));
      }
      return TRUE;
    };
    EnumDisplayMonitors(nullptr, nullptr, cb,
                        reinterpret_cast<LPARAM>(&list));
    result->Success(flutter::EncodableValue(list));
    return;
  }

  result->NotImplemented();
}

}  // namespace

// 系统当前是否浅色主题（注册表 AppsUseLightTheme，1=浅色）。
// 深浅色适配用：卡片文字/描边按"底子明暗"翻转，保证可读性。
// 侧边栏引擎也要查（sidebar_window.cpp），所以不能留在匿名 namespace 里。
bool SystemIsLightTheme() {
  HKEY key;
  DWORD v = 0, size = sizeof(v);
  if (RegOpenKeyExW(HKEY_CURRENT_USER,
                    L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\"
                    L"Personalize",
                    0, KEY_READ, &key) == ERROR_SUCCESS) {
    RegQueryValueExW(key, L"AppsUseLightTheme", nullptr, nullptr,
                     reinterpret_cast<LPBYTE>(&v), &size);
    RegCloseKey(key);
  }
  return v != 0;
}

namespace {
FlutterWindow* g_main_window = nullptr;
}  // namespace

FlutterWindow* FlutterWindow::instance() { return g_main_window; }

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {
  g_main_window = this;
}

FlutterWindow::~FlutterWindow() {
  if (g_main_window == this) g_main_window = nullptr;
}

void FlutterWindow::Log(const std::string& message) {
  // 引擎还没起来时（OnCreate 之前）通道是空的，那阶段的日志只能丢——
  // 但那之前 native 也确实没什么可说的。
  if (!method_channel_) return;
  method_channel_->InvokeMethod(
      "log", std::make_unique<flutter::EncodableValue>(message));
}

void FlutterWindow::OpenAiPanel() {
  // 侧边栏点齿轮时走这条。两个 Flutter 引擎不共享 isolate，Dart 之间没有
  // 直接通路，只能穿过 native 传话。
  if (!method_channel_) return;
  method_channel_->InvokeMethod(
      "openPanel", std::make_unique<flutter::EncodableValue>("ai"));
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  HWND hwnd = GetHandle();
  method_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  method_channel_->SetMethodCallHandler(
      [hwnd](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result), hwnd);
      });

  // 磁贴窗口刻意不接受文件拖放：它常驻 Z 序最底，被任何窗口盖住就够不到，
  // 做了也只是时灵时不灵。投放点在 AI 侧边栏那个置顶窗口上（见 sidebar_window）。

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 全局快捷键：RegisterHotKey 注册的组合被按下时，系统把 WM_HOTKEY 投到本窗口。
  // 直接切换侧边栏窗口 —— 主窗口自己完全不参与置顶，磁贴永远待在桌面层。
  //
  // 必须放在交给 Flutter 之前：HandleTopLevelWindowProc 可能把消息消费掉。
  // --test-openpanel 的定时器：模拟侧边栏点齿轮，走一遍跨引擎打开面板的链路
  if (message == WM_TIMER && wparam == 0x5150) {
    KillTimer(hwnd, 0x5150);
    Log("触发跨引擎打开面板（--test-openpanel）");
    OpenAiPanel();
    return 0;
  }

  if (message == WM_HOTKEY && static_cast<int>(wparam) == kHotkeyId) {
    if (SidebarWindow* sb = SidebarWindow::instance()) {
      sb->Toggle();
    }
    return 0;
  }

  // 显示器插拔：磁贴窗口重新覆盖新的虚拟屏，再通知 Dart 迁移卡片、刷新壁纸。
  // 放在交给 Flutter 之前，避免被 HandleTopLevelWindowProc 消费掉。
  if (message == WM_DISPLAYCHANGE) {
    const int vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
    const int vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
    const int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    const int vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    {
      char buf[128];
      std::snprintf(buf, sizeof(buf),
                    "WM_DISPLAYCHANGE 新虚拟屏=%d,%d %dx%d", vx, vy, vw, vh);
      Log(buf);
    }
    SetWindowPos(hwnd, HWND_BOTTOM, vx, vy, vw, vh, SWP_NOACTIVATE);
    if (method_channel_) {
      method_channel_->InvokeMethod(
          "displayChanged", std::make_unique<flutter::EncodableValue>(true));
    }
    // 侧边栏贴屏幕右侧，屏变了要重摆
    if (SidebarWindow* sb = SidebarWindow::instance()) sb->OnDisplayChange();
    return 0;
  }

  // 系统设置变化：深浅色切换时（ImmersiveColorSet）通知 Dart。
  // 注意要在交给 Flutter 之前处理，避免被消费掉。
  if (message == WM_SETTINGCHANGE && lparam != 0) {
    const wchar_t* setting = reinterpret_cast<const wchar_t*>(lparam);
    if (wcscmp(setting, L"ImmersiveColorSet") == 0) {
      if (method_channel_) {
        method_channel_->InvokeMethod(
            "themeChanged", std::make_unique<flutter::EncodableValue>(true));
      }
      return 0;
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
