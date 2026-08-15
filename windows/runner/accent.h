// 亚克力模糊：user32 的未公开接口 SetWindowCompositionAttribute。
//
// Windows 10 1803 起、Fluent Design 时代的做法，flutter_acrylic 在旧系统上也走
// 这条路径。之所以不用 Win11 的 DWMWA_SYSTEMBACKDROP_TYPE：后者按整个窗口矩形
// 绘制、不受 SetWindowRgn 裁剪（实测整屏发灰），见 flutter_window.cpp 里
// setBackdrop 的实测记录。
//
// 磁贴窗口用不上它（全屏透明窗口 + 区域裁剪，亚克力会把整屏糊掉，所以那边
// 固定调用 ApplyAccentBlur(hwnd, false) 关掉）；设置窗口是普通任务栏窗口，
// 用它做真正的"糊身后内容"的玻璃。
#ifndef RUNNER_ACCENT_H_
#define RUNNER_ACCENT_H_

#include <windows.h>

#include <cstddef>

enum AccentState {
  kAccentDisabled = 0,
  kAccentEnableAcrylicBlurBehind = 4,
};

struct AccentPolicy {
  int state;
  int flags;
  unsigned int gradient_color;  // AABBGGRR
  int animation_id;
};

struct WindowCompositionAttribData {
  int attrib;  // WCA_ACCENT_POLICY = 19
  void* data;
  size_t size;
};

using SetWindowCompositionAttributeFn =
    BOOL(WINAPI*)(HWND, WindowCompositionAttribData*);

// 开启/关闭窗口的亚克力模糊。[tint] 是 AABBGGRR 格式的染色，默认 0x40 的黑色
// —— 纯模糊之上的文字对比度不够，必须带一点染色才能读。返回是否设置成功
// （Win10 1803 以下没有这个接口，会失败，调用方自行决定怎么回退）。
inline bool ApplyAccentBlur(HWND hwnd, bool enable,
                            unsigned int tint = 0x40000000) {
  HMODULE user32 = GetModuleHandleW(L"user32.dll");
  if (!user32) return false;
  auto fn = reinterpret_cast<SetWindowCompositionAttributeFn>(
      GetProcAddress(user32, "SetWindowCompositionAttribute"));
  if (!fn) return false;

  AccentPolicy policy{};
  policy.state = enable ? kAccentEnableAcrylicBlurBehind : kAccentDisabled;
  // flags=2 表示 gradient_color 生效
  policy.flags = 2;
  policy.gradient_color = tint;
  policy.animation_id = 0;

  WindowCompositionAttribData data{};
  data.attrib = 19;  // WCA_ACCENT_POLICY
  data.data = &policy;
  data.size = sizeof(policy);
  return fn(hwnd, &data) != FALSE;
}

#endif  // RUNNER_ACCENT_H_
