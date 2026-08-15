// 抓取桌面（壁纸层）的实际像素。
//
// 为什么不直接读注册表里的壁纸文件：那只对静态壁纸成立。Wallpaper Engine、
// Lively 之类是自己画一个窗口挂在桌面层，注册表里那张图根本不是屏幕上显示的
// 东西。抓实际像素则两种情况都覆盖。
//
// 抓的是桌面窗口本身（Progman 或承载 SHELLDLL_DefView 的那个 WorkerW），
// 不是整屏截图——这样天然不会把我们自己的磁贴拍进去，也就不会出现
// "模糊图里套着上一帧的模糊图"这种自我反馈。
#ifndef RUNNER_DESKTOP_CAPTURE_H_
#define RUNNER_DESKTOP_CAPTURE_H_

#include <windows.h>

#include <cstdint>
#include <vector>

// 按 width x height 抓取并缩放桌面像素，返回 BGRA 顺序的字节。
// 失败时返回空 vector。
std::vector<uint8_t> CaptureDesktop(int width, int height);

// 抓屏幕上任意一块矩形（物理像素），缩放到 dst_w x dst_h，返回 BGRA。
//
// 和 CaptureDesktop 的区别：那个抓的是桌面窗口，适合常驻桌面层的磁贴；
// AI 侧边栏浮在所有程序之上，背后是什么程序就该糊什么，所以要抓屏幕本身。
// 调用方必须在自己的窗口显示**之前**调，否则会把自己拍进去、糊出套娃。
std::vector<uint8_t> CaptureScreenRegion(int src_x, int src_y, int src_w,
                                         int src_h, int dst_w, int dst_h);

#endif  // RUNNER_DESKTOP_CAPTURE_H_
