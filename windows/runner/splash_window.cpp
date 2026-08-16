#include "splash_window.h"

#include <windows.h>

#include <algorithm>
#include <cmath>

// gdiplus.h 里用的是不带 std:: 前缀的 min/max。Windows 头文件在定义了
// NOMINMAX 时不会给出那两个宏，得先把 std 的引进来，否则编译不过。
using std::max;
using std::min;

#include <objidl.h>
// clang-format off
#include <gdiplus.h>
// clang-format on

#include "resource.h"

#pragma comment(lib, "gdiplus.lib")

namespace {

constexpr const wchar_t kClassName[] = L"VectraSplashWindow";

// 逻辑尺寸（96 DPI 下的像素），实际按 DPI 缩放
constexpr int kWidth = 400;
constexpr int kHeight = 280;
constexpr int kRadius = 16;

// 最短展示时长：加载特别快的时候也别让它一闪而过，那样只会看到一道白光。
constexpr DWORD kMinShowMs = 1200;

// 兜底超时：万一某个插件永远产不出首帧（死循环被预算杀掉、清单损坏等），
// 幕布不能就这么一直挂着。Dart 侧也有一层兜底，这里是最后一道。
constexpr DWORD kTimeoutMs = 4000;

// 自定义消息：主线程只通过它们和 splash 线程通信，不直接碰这边的 GDI 对象
constexpr UINT kMsgProgress = WM_APP + 1;
constexpr UINT kMsgFinish = WM_APP + 2;

constexpr UINT_PTR kTimerId = 1;

int Scaled(int v, double s) { return static_cast<int>(v * s + 0.5); }

// 系统当前是不是浅色主题。
//
// 幕布起得比 Flutter 引擎还早，那会儿 Dart 侧的主题设置根本读不到，所以这里
// 直接问系统（和 win32_window.cpp 判断标题栏深浅用的是同一个键）。
// 读不到就当浅色 —— Windows 默认就是浅色，猜错的代价也只是白底配深字。
bool SystemUsesLightTheme() {
  DWORD value = 0;
  DWORD size = sizeof(value);
  const LSTATUS st = RegGetValueW(
      HKEY_CURRENT_USER,
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
      L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &value, &size);
  if (st != ERROR_SUCCESS) return true;
  return value != 0;
}

// 幕布的一套配色。深浅两版只有取值不同，绘制代码完全共用。
struct Palette {
  Gdiplus::Color base;      // 卡片底
  Gdiplus::Color gloss;     // 顶部高光的起始色（末端一律透明）
  Gdiplus::Color edge;      // 描边
  Gdiplus::Color title;     // 品牌名
  Gdiplus::Color subtitle;  // 副标题
  Gdiplus::Color status;    // 状态文字
  Gdiplus::Color track;     // 进度条轨道
  Gdiplus::Color fill;      // 进度条填充
};

Palette MakePalette(bool light) {
  if (light) {
    return Palette{
        Gdiplus::Color(250, 246, 247, 250),
        // 浅色底上再打白光就糊成一片了，这里改成从上往下压一层极淡的暗，
        // 让顶边有收口感
        Gdiplus::Color(10, 0, 0, 0),
        Gdiplus::Color(38, 0, 0, 0),
        Gdiplus::Color(238, 26, 29, 35),
        Gdiplus::Color(140, 26, 29, 35),
        Gdiplus::Color(110, 26, 29, 35),
        Gdiplus::Color(30, 0, 0, 0),
        // 浅色下天蓝太飘，用面板浅色主题那档更深的蓝
        Gdiplus::Color(255, 21, 101, 192),
    };
  }
  return Palette{
      Gdiplus::Color(250, 18, 21, 26),
      Gdiplus::Color(26, 255, 255, 255),
      Gdiplus::Color(30, 255, 255, 255),
      Gdiplus::Color(240, 255, 255, 255),
      Gdiplus::Color(120, 255, 255, 255),
      Gdiplus::Color(90, 255, 255, 255),
      Gdiplus::Color(36, 255, 255, 255),
      Gdiplus::Color(255, 124, 199, 255),
  };
}

// 圆角矩形路径。GDI+ 没有现成的，四个角各画一段 90° 弧再连起来。
void AddRoundRect(Gdiplus::GraphicsPath* path, Gdiplus::RectF r, float d) {
  path->AddArc(r.X, r.Y, d, d, 180.0f, 90.0f);
  path->AddArc(r.GetRight() - d, r.Y, d, d, 270.0f, 90.0f);
  path->AddArc(r.GetRight() - d, r.GetBottom() - d, d, d, 0.0f, 90.0f);
  path->AddArc(r.X, r.GetBottom() - d, d, d, 90.0f, 90.0f);
  path->CloseFigure();
}

SplashWindow* g_instance = nullptr;

}  // namespace

SplashWindow* SplashWindow::instance() {
  if (!g_instance) g_instance = new SplashWindow();
  return g_instance;
}

void SplashWindow::Start(HINSTANCE instance) {
  if (thread_) return;
  instance_ = instance;

  // 等窗口真正建好再返回：后面 SetProgress/Finish 都靠 PostMessage 投到
  // 这个 hwnd 上，窗口没建好就投会把消息丢掉 —— Finish 一旦丢了，
  // 幕布就再也不会消失。
  HANDLE ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  ready_event_ = ready;

  thread_ = CreateThread(nullptr, 0, &SplashWindow::ThreadMain, this, 0,
                         &thread_id_);
  if (!thread_) {
    if (ready) CloseHandle(ready);
    ready_event_ = nullptr;
    return;
  }
  if (ready) {
    WaitForSingleObject(ready, 2000);
    CloseHandle(ready);
    ready_event_ = nullptr;
  }
}

void SplashWindow::SetProgress(int ready, int total) {
  if (!hwnd_ || !alive_.load()) return;
  PostMessageW(hwnd_, kMsgProgress, static_cast<WPARAM>(ready),
               static_cast<LPARAM>(total));
}

void SplashWindow::Finish() {
  if (!hwnd_ || !alive_.load()) return;
  PostMessageW(hwnd_, kMsgFinish, 0, 0);
}

DWORD WINAPI SplashWindow::ThreadMain(LPVOID param) {
  auto* self = static_cast<SplashWindow*>(param);

  Gdiplus::GdiplusStartupInput input;
  Gdiplus::GdiplusStartup(&self->gdiplus_token_, &input, nullptr);

  WNDCLASSEXW wc{};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = &SplashWindow::WndProc;
  wc.hInstance = self->instance_;
  wc.lpszClassName = kClassName;
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  RegisterClassExW(&wc);

  self->light_ = SystemUsesLightTheme();

  // DPI：splash 固定居中在主显示器上，跟着主屏的缩放走
  const UINT dpi = GetDpiForSystem();
  self->scale_ = dpi / 96.0;
  self->w_px_ = Scaled(kWidth, self->scale_);
  self->h_px_ = Scaled(kHeight, self->scale_);

  RECT wa{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0);
  const int x = wa.left + ((wa.right - wa.left) - self->w_px_) / 2;
  const int y = wa.top + ((wa.bottom - wa.top) - self->h_px_) / 2;

  // WS_EX_LAYERED：整窗按像素带 alpha 合成，圆角和半透明才有干净边缘。
  // WS_EX_NOACTIVATE：不抢焦点，用户在别处打字不会被打断。
  // WS_EX_TOOLWINDOW：不进任务栏和 Alt+Tab —— 它只活几百毫秒，
  //                   在任务栏里闪一下反而像出了什么毛病。
  self->hwnd_ = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
      kClassName, L"Vectra", WS_POPUP, x, y, self->w_px_, self->h_px_, nullptr,
      nullptr, self->instance_, self);

  if (!self->hwnd_) {
    Gdiplus::GdiplusShutdown(self->gdiplus_token_);
    if (self->ready_event_) SetEvent(self->ready_event_);
    return 0;
  }

  self->start_tick_ = GetTickCount();
  self->alive_.store(true);

  // 先画满一帧再显示。
  //
  // 这一帧必须是"完整可见"的样子，不能从透明淡入：紧接着主线程就会去构造
  // Flutter 引擎并阻塞几百毫秒，那期间 splash 线程虽然还在跑，但用户第一眼
  // 看到的就是这一帧。淡入动画放在这儿只会让人先看到一片空白。
  self->Render();
  ShowWindow(self->hwnd_, SW_SHOWNOACTIVATE);

  SetTimer(self->hwnd_, kTimerId, 16, nullptr);
  if (self->ready_event_) SetEvent(self->ready_event_);

  self->RunMessageLoop();

  KillTimer(self->hwnd_, kTimerId);
  Gdiplus::GdiplusShutdown(self->gdiplus_token_);
  self->alive_.store(false);
  self->hwnd_ = nullptr;
  return 0;
}

void SplashWindow::RunMessageLoop() {
  MSG msg;
  while (GetMessageW(&msg, nullptr, 0, 0)) {
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }
}

LRESULT CALLBACK SplashWindow::WndProc(HWND hwnd, UINT msg, WPARAM w,
                                       LPARAM l) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(l);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
  }
  auto* self =
      reinterpret_cast<SplashWindow*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (!self) return DefWindowProcW(hwnd, msg, w, l);

  switch (msg) {
    case kMsgProgress: {
      self->ready_ = static_cast<int>(w);
      self->total_ = static_cast<int>(l);
      self->target_ =
          self->total_ > 0
              ? static_cast<double>(self->ready_) / self->total_
              : 0.0;
      return 0;
    }
    case kMsgFinish:
      self->target_ = 1.0;
      self->finishing_ = true;
      return 0;
    case WM_TIMER:
      self->Tick();
      return 0;
    case WM_DESTROY:
      PostQuitMessage(0);
      return 0;
    default:
      break;
  }
  return DefWindowProcW(hwnd, msg, w, l);
}

void SplashWindow::Tick() {
  const DWORD elapsed = GetTickCount() - start_tick_;

  // 兜底：等太久就自己收尾，别把幕布永远挂在那儿
  if (!finishing_ && elapsed > kTimeoutMs) {
    target_ = 1.0;
    finishing_ = true;
  }

  // 显示值向目标缓动。直接跳格会让进度条一格一格地蹦，
  // 插件多起来之后尤其明显。
  //
  // 收到"全部就绪"之后换成更快的系数：这时磁贴已经显示出来了，幕布还慢悠悠
  // 地把进度条推到头就成了纯粹的等待 —— 用户看到的是"东西都出来了，这个框
  // 还挡着"。冲满即退更利落。
  shown_ += (target_ - shown_) * (finishing_ ? 0.45 : 0.18);
  if (shown_ > 0.999) shown_ = 1.0;

  // 收尾要同时满足三件事才开始淡出：已经收到完成通知、进度条确实走到了头、
  // 展示时长够了。少任何一条都会让人觉得"还没读完就没了"。
  if (finishing_ && shown_ >= 0.995 && elapsed >= kMinShowMs) {
    // 拉开的同一刻让磁贴现身，两件事一起发生
    if (!reveal_sent_) {
      reveal_sent_ = true;
      if (reveal_target_) {
        PostMessageW(reveal_target_, kSplashRevealMessage, 0, 0);
      }
    }
    fade_ -= 0.06;
    if (fade_ <= 0.0) {
      DestroyWindow(hwnd_);
      return;
    }
  }

  Render();
}

void SplashWindow::Render() {
  if (!hwnd_) return;

  HDC screen = GetDC(nullptr);
  HDC mem = CreateCompatibleDC(screen);

  BITMAPINFO bi{};
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = w_px_;
  bi.bmiHeader.biHeight = -h_px_;  // 负数 = 自上而下，和 GDI+ 的坐标一致
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HBITMAP dib =
      CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
  HGDIOBJ old = SelectObject(mem, dib);

  {
    // 关键：用 PARGB 包住 DIB 的内存直接画。
    //
    // UpdateLayeredWindow 要的是**预乘 alpha** 的位图（每个颜色分量已经乘过
    // 自己的 alpha），而 GDI+ 默认按普通 ARGB 出图。直接把没预乘的位图推上去，
    // 半透明的地方颜色会偏亮 —— 高光和描边尤其明显，看着像过曝。
    // 指定 PixelFormat32bppPARGB 之后 GDI+ 就按预乘规则合成，省掉自己再遍历
    // 一遍像素去乘。
    Gdiplus::Bitmap surface(w_px_, h_px_, w_px_ * 4, PixelFormat32bppPARGB,
                            static_cast<BYTE*>(bits));
    Gdiplus::Graphics g(&surface);
    g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    // 文字用灰度抗锯齿而不是 ClearType：ClearType 是子像素渲染，
    // 画到带 alpha 的位图上会在字边留下彩色脏边。
    g.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAlias);
    g.Clear(Gdiplus::Color(0, 0, 0, 0));

    const float s = static_cast<float>(scale_);
    const float d = kRadius * 2.0f * s;
    Gdiplus::RectF card(0.5f, 0.5f, w_px_ - 1.0f, h_px_ - 1.0f);

    Gdiplus::GraphicsPath path;
    AddRoundRect(&path, card, d);

    const Palette pal = MakePalette(light_);

    // 磨砂底：这台机器上系统级毛玻璃靠不住（WCA 亚克力实测会把整窗渲染成
    // 透明还拖慢合成），所以不去碰它，自绘一块底色 + 顶部高光。
    //
    // 底色压到接近不透明是有意的：真毛玻璃靠的是"模糊 + 半透明"，模糊那一半
    // 我们做不了，只留半透明的话，后面的窗口内容会**清清楚楚**透上来（实测
    // 能读出背后终端里的每一行字），那不是磨砂，是脏。所以这里只留一丝很淡的
    // 通透，质感交给高光渐变和描边去撑。
    Gdiplus::SolidBrush base(pal.base);
    g.FillPath(&base, &path);

    // 顶部高光：一层从上往下散掉的白，模拟光从上方打过来。
    // 没有它，纯色块看着就是一张死板的深色卡片。
    {
      Gdiplus::RectF hi(0.0f, 0.0f, static_cast<float>(w_px_), h_px_ * 0.55f);
      const Gdiplus::Color gloss_end(0, pal.gloss.GetR(), pal.gloss.GetG(),
                                     pal.gloss.GetB());
      Gdiplus::LinearGradientBrush gloss(hi, pal.gloss, gloss_end,
                                         Gdiplus::LinearGradientModeVertical);
      Gdiplus::Region clip(&path);
      g.SetClip(&clip);
      g.FillRectangle(&gloss, hi);
      g.ResetClip();
    }

    // 描边：亮一点的细线，把卡片从桌面上"抬"起来
    Gdiplus::Pen edge(pal.edge, 1.0f * s);
    g.DrawPath(&edge, &path);

    // ---- Logo ----
    const int icon_px = Scaled(64, scale_);
    HICON icon = static_cast<HICON>(
        LoadImageW(instance_, MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
                   icon_px, icon_px, LR_DEFAULTCOLOR));
    if (icon) {
      Gdiplus::Bitmap bmp(icon);
      g.DrawImage(&bmp, (w_px_ - icon_px) / 2.0f, 44.0f * s,
                  static_cast<float>(icon_px), static_cast<float>(icon_px));
      DestroyIcon(icon);
    }

    Gdiplus::StringFormat center;
    center.SetAlignment(Gdiplus::StringAlignmentCenter);

    // ---- 品牌名 ----
    {
      Gdiplus::Font font(L"Segoe UI", 26.0f * s, Gdiplus::FontStyleBold,
                         Gdiplus::UnitPixel);
      Gdiplus::SolidBrush brush(pal.title);
      Gdiplus::RectF box(0.0f, 128.0f * s, static_cast<float>(w_px_),
                         40.0f * s);
      g.DrawString(L"Vectra", -1, &font, box, &center, &brush);
    }

    // ---- 副标题 ----
    {
      Gdiplus::Font font(L"Microsoft YaHei UI", 12.0f * s,
                         Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
      Gdiplus::SolidBrush brush(pal.subtitle);
      Gdiplus::RectF box(0.0f, 170.0f * s, static_cast<float>(w_px_),
                         24.0f * s);
      g.DrawString(L"桌面磁贴小组件", -1, &font, box, &center, &brush);
    }

    // ---- 进度条 ----
    const float bar_w = 240.0f * s;
    const float bar_h = 4.0f * s;
    const float bar_x = (w_px_ - bar_w) / 2.0f;
    const float bar_y = 214.0f * s;
    {
      Gdiplus::GraphicsPath track;
      AddRoundRect(&track, Gdiplus::RectF(bar_x, bar_y, bar_w, bar_h), bar_h);
      Gdiplus::SolidBrush track_brush(pal.track);
      g.FillPath(&track_brush, &track);

      if (total_ <= 0) {
        // 还没收到任何真实进度：Dart 侧要先把用户数据读出来、把插件清单扫完，
        // 才知道总共有几张卡片。这中间少则几百毫秒，首次启动要迁移旧数据时
        // 能到两秒 —— 期间进度条如果一直是空的、画面纹丝不动，看着就像卡死了。
        //
        // 这里画一段来回扫的光带（不确定态），只表示"在忙"，不谎报完成度。
        const double t = (GetTickCount() - start_tick_) / 1000.0;
        double phase = fmod(t * 0.6, 2.0);
        if (phase > 1.0) phase = 2.0 - phase;  // 三角波：走到头再折回来
        const float seg = bar_w * 0.32f;
        const float sx = bar_x + (bar_w - seg) * static_cast<float>(phase);
        Gdiplus::GraphicsPath ind;
        AddRoundRect(&ind, Gdiplus::RectF(sx, bar_y, seg, bar_h), bar_h);
        Gdiplus::SolidBrush ind_brush(Gdiplus::Color(160, pal.fill.GetR(), pal.fill.GetG(), pal.fill.GetB()));
        g.FillPath(&ind_brush, &ind);
      }

      const float filled = bar_w * static_cast<float>(shown_);
      // 太窄的时候圆角画不出来，宽度不够就先不画，免得出现一个小方块
      if (total_ > 0 && filled > bar_h) {
        Gdiplus::GraphicsPath fill;
        AddRoundRect(&fill, Gdiplus::RectF(bar_x, bar_y, filled, bar_h), bar_h);
        // 品牌天蓝，和磁贴、面板的强调色是同一个
        Gdiplus::SolidBrush fill_brush(pal.fill);
        g.FillPath(&fill_brush, &fill);
      }
    }

    // ---- 状态文字 ----
    {
      wchar_t text[64];
      if (total_ > 0) {
        swprintf_s(text, L"正在加载组件 %d / %d", min(ready_, total_), total_);
      } else {
        wcscpy_s(text, L"正在启动…");
      }
      Gdiplus::Font font(L"Microsoft YaHei UI", 11.0f * s,
                         Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
      Gdiplus::SolidBrush brush(pal.status);
      Gdiplus::RectF box(0.0f, 232.0f * s, static_cast<float>(w_px_),
                         22.0f * s);
      g.DrawString(text, -1, &font, box, &center, &brush);
    }
  }

  POINT src{0, 0};
  SIZE size{w_px_, h_px_};
  BLENDFUNCTION blend{};
  blend.BlendOp = AC_SRC_OVER;
  blend.SourceConstantAlpha =
      static_cast<BYTE>(max(0.0, min(1.0, fade_)) * 255);
  blend.AlphaFormat = AC_SRC_ALPHA;

  UpdateLayeredWindow(hwnd_, screen, nullptr, &size, mem, &src, 0, &blend,
                      ULW_ALPHA);

  SelectObject(mem, old);
  DeleteObject(dib);
  DeleteDC(mem);
  ReleaseDC(nullptr, screen);
}
