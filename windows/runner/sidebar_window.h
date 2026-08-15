// AI 侧边栏的独立窗口。
//
// 为什么必须独立成窗口：磁贴要常驻 Z 序最底（桌面小组件），侧边栏要浮在
// 所有程序之上。一个窗口不可能同时满足两者——之前共用一个窗口时，侧边栏
// 一置顶，磁贴就跟着飘到 QQ、浏览器上面去了。
//
// 它跑第二个 Flutter 引擎，入口是 Dart 侧的 sidebarMain()。两个引擎各自
// 独立，不共享 isolate；状态通过磁盘文件交接（设置由主引擎写，侧边栏只读，
// 聊天记录归侧边栏自己）。
#ifndef RUNNER_SIDEBAR_WINDOW_H_
#define RUNNER_SIDEBAR_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "file_drop.h"
#include "win32_window.h"

class SidebarWindow : public Win32Window {
 public:
  explicit SidebarWindow(const flutter::DartProject& project);
  virtual ~SidebarWindow();

  // 按工作区右侧摆放并展开；已展开时再调一次就收起。
  void Toggle();
  void Show();

  // 收起。开了投放点就缩成右下角那个小方块（窗口仍然存在、仍然置顶），
  // 关了就整个 SW_HIDE。
  void Hide();
  bool visible() const { return visible_; }

  // 展开并把一批文件（UTF-8 路径）交给 Dart 当附件。
  // 拖文件到收起态的投放点上时走这条路。
  void ShowWithFiles(const std::vector<std::string>& paths);

  // 控制面板改完 AI 配置后叫一声，让侧边栏那个引擎重新读一遍 state.json。
  // 两个引擎不共享 isolate，配置只能靠磁盘交接，得有人说"文件变了"。
  void RequestReload();

  // 钉住（不因失活自动收起）。--ai-pin 启动参数用它。
  void SetPinned(bool on) { pinned_ = on; }

  // 显示器插拔：侧边栏贴屏幕右侧，屏变了要按新工作区重摆
  void OnDisplayChange();

  // 进程内单例：全局快捷键在主窗口那边收，需要跨过来切换本窗口。
  static SidebarWindow* instance();

 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // 按主显示器工作区算出侧边栏该占的矩形（物理像素）
  RECT TargetRect() const;

  // 收起态那个小方块的矩形：工作区右下角（物理像素）
  RECT DockRect();

  // 把窗口缩到投放点大小并显示（不抢焦点）
  void ShowDock();

  // 请求收起：先让 Dart 播退场动画，播完它回调 hide
  void BeginClose();

  // 把一批 UTF-8 路径投给 Dart
  void SendFiles(const std::vector<std::string>& paths);

  flutter::DartProject project_;
  std::unique_ptr<flutter::FlutterViewController> controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  // 侧边栏引擎自己的 vectra/native，只实现它用得到的方法
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      native_channel_;
  bool visible_ = false;

  // 钉住：不因失去焦点而自动收起。
  // 没有它就没法往侧边栏里拖文件——在资源管理器上按下鼠标的那一刻侧边栏
  // 就失活了，等拖到这儿窗口早没了。
  bool pinned_ = false;

  // 收起时是否缩成右下角的投放点（而不是整个隐藏）。由 Dart 读配置后告知。
  //
  // 为什么投放点长在这个窗口上而不是磁贴窗口上：磁贴常驻 Z 序最底，
  // 右下角一旦被别的窗口盖住就完全够不到（实测被 Chrome 盖住）。
  // 而这个窗口本来就是置顶的，收起态缩成一个小方块正好当常驻投放点。
  bool dock_ = false;

  // 拖文件进来（IDropTarget 注册在 FLUTTERVIEW 子窗口上）
  std::unique_ptr<FileDropTarget> drop_target_;

  // 拖着的文件此刻是否悬在窗口上方，用于让投放点变亮
  bool drop_hover_ = false;

  // 刚显示出来的那一瞬间会先收到一次 WM_ACTIVATE(WA_INACTIVE)——抢前台还没
  // 成功就被自己的"点外面关闭"逻辑关掉了（实测 --ai 启动后侧边栏立刻消失）。
  // 显示后的一小段时间内忽略失活。
  DWORD shown_at_ = 0;

  // 显示之前抓下来的"身后那块屏幕"。必须在窗口可见之前抓，
  // 否则会把自己拍进去，糊出一层套一层。
  std::vector<uint8_t> behind_;
  int behind_w_ = 0;
  int behind_h_ = 0;
};

#endif  // RUNNER_SIDEBAR_WINDOW_H_
