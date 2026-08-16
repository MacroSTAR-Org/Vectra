#include "desktop_capture.h"

#include <cstdio>

namespace {

// Windows 把壁纸画在哪个窗口上，取决于是否触发过"显示桌面"预览：
//   - 常规情况：Progman 自己画
//   - 触发过之后：explorer 会新建一个 WorkerW，壁纸画在它上面，
//     而图标所在的 SHELLDLL_DefView 留在 Progman 或另一个 WorkerW 里
// 这里先找承载 SHELLDLL_DefView 的那个顶层窗口，它就是"看得见的桌面"。
struct FindResult {
  HWND desktop = nullptr;
};

BOOL CALLBACK FindDesktopProc(HWND hwnd, LPARAM lparam) {
  auto* out = reinterpret_cast<FindResult*>(lparam);
  if (FindWindowExW(hwnd, nullptr, L"SHELLDLL_DefView", nullptr) != nullptr) {
    out->desktop = hwnd;
    return FALSE;  // 找到就停
  }
  return TRUE;
}

HWND FindDesktopWindow() {
  // 壁纸实际画在 Progman（或"显示桌面"预览后新建的 WorkerW）上，覆盖整个
  // 虚拟屏。带 SHELLDLL_DefView 的那个窗口是图标层，双屏下可能只盖一块屏
  // （实测得到 -354,450 1371x1217，而虚拟屏是 -354,0 2034x1667），抓它会
  // 把半屏壁纸拉伸成整屏，模糊全错位。所以优先用覆盖虚拟屏的 Progman。
  const int vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
  const int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  const int vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  RECT vr = {vx, vy, vx + vw, vy + vh};

  HWND progman = FindWindowW(L"Progman", nullptr);
  if (progman) {
    RECT rc{};
    if (GetWindowRect(progman, &rc)) {
      // 允许几像素误差
      if (rc.left <= vr.left + 1 && rc.top <= vr.top + 1 &&
          rc.right >= vr.right - 1 && rc.bottom >= vr.bottom - 1) {
        return progman;
      }
    }
  }

  // 退回原来的：找承载 SHELLDLL_DefView 的顶层窗口
  FindResult r;
  EnumWindows(FindDesktopProc, reinterpret_cast<LPARAM>(&r));
  if (r.desktop) return r.desktop;
  return progman;
}

// 缓存 GDI 对象。高刷新率下每帧新建再销毁一张 2560x1440 的兼容位图（约 14MB）
// 开销很可观，而尺寸几乎从不变化。
struct CaptureCache {
  HDC full_dc = nullptr;
  HBITMAP full_bmp = nullptr;
  HGDIOBJ full_old = nullptr;
  int full_w = 0, full_h = 0;

  HDC small_dc = nullptr;
  HBITMAP small_bmp = nullptr;
  HGDIOBJ small_old = nullptr;
  void* small_bits = nullptr;
  int small_w = 0, small_h = 0;
};

CaptureCache& Cache() {
  static CaptureCache c;
  return c;
}

}  // namespace

std::vector<uint8_t> CaptureDesktop(int width, int height) {
  std::vector<uint8_t> out;
  if (width <= 0 || height <= 0) return out;

  HWND desktop = FindDesktopWindow();
  if (!desktop) return out;

  RECT rc{};
  if (!GetWindowRect(desktop, &rc)) return out;
  const int src_w = rc.right - rc.left;
  const int src_h = rc.bottom - rc.top;
  if (src_w <= 0 || src_h <= 0) return out;

  HDC screen_dc = GetDC(nullptr);
  if (!screen_dc) return out;

  // 先按原始尺寸抓一份，再缩放到目标尺寸：PrintWindow 不支持直接缩放。
  // 这两块 GDI 资源跨调用复用，尺寸变了才重建 —— 高刷新率下每帧新建再销毁
  // 一张 2560x1440 的兼容位图（约 14MB）是白白烧掉的时间。
  CaptureCache& cache = Cache();
  if (cache.full_w != src_w || cache.full_h != src_h || !cache.full_dc) {
    if (cache.full_dc) {
      if (cache.full_old) SelectObject(cache.full_dc, cache.full_old);
      DeleteDC(cache.full_dc);
    }
    if (cache.full_bmp) DeleteObject(cache.full_bmp);
    cache.full_dc = CreateCompatibleDC(screen_dc);
    cache.full_bmp = CreateCompatibleBitmap(screen_dc, src_w, src_h);
    cache.full_old = SelectObject(cache.full_dc, cache.full_bmp);
    cache.full_w = src_w;
    cache.full_h = src_h;
  }
  HDC full_dc = cache.full_dc;

  // 先清成黑色再让窗口往里画：PrintWindow 对不处理 WM_PRINT 的窗口会什么都不
  // 画。不清的话缓存位图里会残留上一帧的旧内容，黑屏反而检测不出来。
  PatBlt(full_dc, 0, 0, src_w, src_h, BLACKNESS);

  // PW_RENDERFULLCONTENT = 2，让 DirectX 内容也能被渲染出来（动态壁纸需要）
  BOOL ok = PrintWindow(desktop, full_dc, 2);
  if (!ok) {
    // 退一步：直接从屏幕对应区域取。此时若有窗口盖在桌面上会被一起拍进来，
    // 但磁贴只在桌面露出时才可见，这种情况下屏幕上本来就是桌面。
    ok = BitBlt(full_dc, 0, 0, src_w, src_h, screen_dc, rc.left, rc.top,
                SRCCOPY);
  }

  if (ok) {
    if (cache.small_w != width || cache.small_h != height || !cache.small_dc) {
      if (cache.small_dc) {
        if (cache.small_old) SelectObject(cache.small_dc, cache.small_old);
        DeleteDC(cache.small_dc);
      }
      if (cache.small_bmp) DeleteObject(cache.small_bmp);

      BITMAPINFO bi{};
      bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
      bi.bmiHeader.biWidth = width;
      // 负高度 = 自上而下，省得再翻转一遍
      bi.bmiHeader.biHeight = -height;
      bi.bmiHeader.biPlanes = 1;
      bi.bmiHeader.biBitCount = 32;
      bi.bmiHeader.biCompression = BI_RGB;

      cache.small_dc = CreateCompatibleDC(screen_dc);
      cache.small_bmp = CreateDIBSection(screen_dc, &bi, DIB_RGB_COLORS,
                                         &cache.small_bits, nullptr, 0);
      cache.small_old = cache.small_bmp
                            ? SelectObject(cache.small_dc, cache.small_bmp)
                            : nullptr;
      cache.small_w = width;
      cache.small_h = height;
    }
    HDC small_dc = cache.small_dc;
    void* bits = cache.small_bits;
    if (small_dc && bits) {
      // COLORONCOLOR 而不是 HALFTONE：后者做加权重采样，实测是整条链路里
      // 最慢的一环之一，而这张图马上要被高斯模糊，重采样质量毫无意义。
      SetStretchBltMode(small_dc, COLORONCOLOR);

      // 通用自适应：桌面窗口的宽高比不一定等于请求尺寸（壁纸画在副屏/多屏
      // 虚拟屏时尤其常见）。直接 StretchBlt 会把整张图拉伸变形，所以先按目标
      // 宽高比做中心裁剪（cover 语义），再缩放——输出比例永远等于请求比例。
      const double target_aspect = static_cast<double>(width) / height;
      const double src_aspect = static_cast<double>(src_w) / src_h;
      RECT crop{};
      if (src_aspect > target_aspect) {
        // 源太宽：裁左右，取满高
        const int cw = static_cast<int>(src_h * target_aspect);
        crop.left = (src_w - cw) / 2;
        crop.right = crop.left + cw;
        crop.top = 0;
        crop.bottom = src_h;
      } else {
        // 源太高：裁上下，取满宽
        const int ch = static_cast<int>(src_w / target_aspect);
        crop.top = (src_h - ch) / 2;
        crop.bottom = crop.top + ch;
        crop.left = 0;
        crop.right = src_w;
      }
      StretchBlt(small_dc, 0, 0, width, height, full_dc, crop.left, crop.top,
                 crop.right - crop.left, crop.bottom - crop.top, SRCCOPY);
      GdiFlush();

      out.resize(static_cast<size_t>(width) * height * 4);
      memcpy(out.data(), bits, out.size());

      // GDI 抓出来的 alpha 全是 0，不补成 255 的话整张图会被当成全透明。
      // 放在这里做而不是回到 Dart 里做：高刷新率下 Dart 侧那一遍循环
      // 要额外拷贝并遍历 1.6MB，是纯浪费。
      for (size_t i = 3; i < out.size(); i += 4) {
        out[i] = 255;
      }

      // PrintWindow 在 Windows 10 上对桌面窗口经常返回 TRUE 但什么都没画——
      // DWM 合成出来的壁纸不会渲染进 DC（壁纸画在另一个 WorkerW 上时尤其
      // 常见），于是拿到一整块黑/纯色。这种"成功了的黑图"比失败更隐蔽：
      // 旧逻辑只在 PrintWindow 返回 FALSE 时才回退，黑图会被直接拿去模糊，
      // 卡片只剩一层深色、完全没有玻璃质感。
      //
      // 这里算亮度的均值与方差，内容近乎纯色就判定抓屏失败：返回空交给
      // Dart 回退读壁纸文件（静态壁纸那条路确定可靠）。误判也无害——真·纯色
      // 壁纸从文件读回来也是同一块颜色。
      // 32 位 BI_RGB 的 DIB 在内存里是 BGRA，不是 RGBA（Dart 那边也正是按
      // PixelFormat.bgra8888 解码这块缓冲的）。所以 out[i] 是蓝、out[i+2] 是红，
      // Rec.709 的红蓝权重要跟着换过来，否则红/蓝为主的壁纸亮度会算歪：
      // 深红壁纸的真实亮度约 0.2126*R，按错的算只剩 0.0722*R，容易掉到
      // mean < 8 的门槛以下，把一帧本来抓得好好的桌面误判成"纯色帧"丢掉。
      const double n = static_cast<double>(width) * height;
      double sum = 0.0, sumsq = 0.0;
      for (size_t i = 0; i < out.size(); i += 4) {
        const double y = 0.0722 * out[i] + 0.7152 * out[i + 1] +
                         0.2126 * out[i + 2];
        sum += y;
        sumsq += y * y;
      }
      const double mean = sum / n;
      const double variance = sumsq / n - mean * mean;
      if (variance < 16.0 || mean < 8.0) {
        std::fprintf(stderr,
                     "[desktop_capture] PrintWindow 抓到纯色帧 "
                     "(mean=%.1f/255 var=%.1f)，判定失败，回退读壁纸文件\n",
                     mean, variance);
        out.clear();
      }
    }
  }

  // full_dc / small_dc 是缓存的，这里不销毁；只还掉临时借的屏幕 DC。
  ReleaseDC(nullptr, screen_dc);
  return out;
}

std::vector<uint8_t> CaptureScreenRegion(int src_x, int src_y, int src_w,
                                         int src_h, int dst_w, int dst_h) {
  std::vector<uint8_t> out;
  if (src_w <= 0 || src_h <= 0 || dst_w <= 0 || dst_h <= 0) return out;

  HDC screen_dc = GetDC(nullptr);
  if (!screen_dc) return out;

  HDC mem_dc = CreateCompatibleDC(screen_dc);
  BITMAPINFO bi{};
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = dst_w;
  bi.bmiHeader.biHeight = -dst_h;  // 负高度 = 自上而下
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HBITMAP bmp =
      CreateDIBSection(screen_dc, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (bmp && bits) {
    HGDIOBJ old = SelectObject(mem_dc, bmp);
    SetStretchBltMode(mem_dc, COLORONCOLOR);
    StretchBlt(mem_dc, 0, 0, dst_w, dst_h, screen_dc, src_x, src_y, src_w,
               src_h, SRCCOPY);
    GdiFlush();

    out.resize(static_cast<size_t>(dst_w) * dst_h * 4);
    memcpy(out.data(), bits, out.size());
    // GDI 抓出来的 alpha 是 0，不补成 255 整张图会被当成全透明
    for (size_t i = 3; i < out.size(); i += 4) out[i] = 255;

    SelectObject(mem_dc, old);
    DeleteObject(bmp);
  }
  DeleteDC(mem_dc);
  ReleaseDC(nullptr, screen_dc);
  return out;
}
