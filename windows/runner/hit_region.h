// 命中区：决定全屏透明窗口上的某一点是"归我"还是"穿透到桌面"。
//
// 整个应用只有一个覆盖虚拟屏幕的窗口。如果不做处理，它会吃掉桌面上的每一次
// 点击（图标双击、右键菜单全部失效）。WM_NCHITTEST 对不在任何卡片上的点返回
// HTTRANSPARENT，消息就会交给下面的窗口。
//
// 为什么不用 SetWindowRgn：那是硬边裁剪，会把卡片的柔和投影齐边切断。
// 命中区只约束输入，不影响绘制，投影得以保留。
//
// 判定数学必须与 lib/core/hit.dart 的 insideRoundedRect 完全一致，
// 否则会出现"看得见却点不着"的错位。
#ifndef RUNNER_HIT_REGION_H_
#define RUNNER_HIT_REGION_H_

#include <windows.h>

#include <mutex>
#include <vector>

struct HitRect {
  double x;
  double y;
  double w;
  double h;
  double radius;
};

class HitRegion {
 public:
  static HitRegion& Instance();

  // 由 Dart 侧在卡片位置变化时推下来（物理像素，窗口客户区坐标系）。
  void SetRects(std::vector<HitRect> rects);

  // 这里原先有 capture_all / panel_mode / keep_top 三个标志，都是为了
  // "控制面板画在磁贴这个全屏窗口里"服务的：面板打开时要整窗接收输入、
  // 要临时解除常驻最底、还要抢前台。面板已经搬进任务栏里的独立窗口
  // （panel_window.h），这三个标志随之全部作废，整组删掉。
  //
  // 顺带说一句：那段抢前台的代码正是磁贴被顶到浏览器和 QQ 上面去的根源。

  // 拖拽模式：拖动期间暂停区域裁剪。
  //
  // 每次指针移动都重设一次窗口区域（且 SetWindowRgn 会强制重绘）会与 Flutter
  // 的绘制节奏打架，拖出明显残影，卡片上边缘尤其严重。拖拽期间整窗放开，
  // 松手后再由 Dart 推一次区域恢复。
  void SetDragging(bool on);
  bool dragging() const;

  // 点是否落在任意卡片内。坐标为窗口客户区物理像素。
  bool Contains(double x, double y) const;

 private:
  HitRegion() = default;
  mutable std::mutex mutex_;
  std::vector<HitRect> rects_;
  bool dragging_ = false;
};

#endif  // RUNNER_HIT_REGION_H_
