// 把"从资源管理器拖文件进来"接到 Flutter 窗口上。
//
// 为什么用 IDropTarget 而不是 DragAcceptFiles + WM_DROPFILES：
// 光标下的窗口是 FLUTTERVIEW 子窗口（实测窗口树就是 顶层 -> FLUTTERVIEW，
// 再往下没有别的子窗口），WM_DROPFILES 会投给它而不是顶层，而它的窗口过程
// 归 Flutter 所有 —— 之前子类化 FLUTTERVIEW 造成过"整块界面点不动"的事故，
// 不能再走那条路。IDropTarget 是 COM 对象，注册到子窗口上完全不碰窗口过程；
// 顺带还能拿到 DragOver，用来在拖到右下角投放点时高亮。
#ifndef RUNNER_FILE_DROP_H_
#define RUNNER_FILE_DROP_H_

#include <oleidl.h>
#include <windows.h>

#include <functional>
#include <string>
#include <vector>

class FileDropTarget : public IDropTarget {
 public:
  // 拖到某个屏幕坐标上：返回 true 表示这里接收投放（光标显示"复制"）
  using OverFn = std::function<bool(POINT screen)>;
  // 真的松手了
  using DropFn =
      std::function<void(POINT screen, const std::vector<std::wstring>& files)>;
  // 拖出去了/取消了，用来把高亮撤掉
  using LeaveFn = std::function<void()>;

  FileDropTarget(OverFn on_over, DropFn on_drop, LeaveFn on_leave);
  virtual ~FileDropTarget() = default;

  // IUnknown
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;

  // IDropTarget
  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD key_state,
                                      POINTL pt, DWORD* effect) override;
  HRESULT STDMETHODCALLTYPE DragOver(DWORD key_state, POINTL pt,
                                     DWORD* effect) override;
  HRESULT STDMETHODCALLTYPE DragLeave() override;
  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data, DWORD key_state, POINTL pt,
                                 DWORD* effect) override;

 private:
  LONG ref_ = 1;
  // 本次拖拽里到底有没有文件。只在 DragEnter 判一次，DragOver 每移动一像素
  // 都会来一发，不该反复去问数据对象。
  bool has_files_ = false;
  OverFn on_over_;
  DropFn on_drop_;
  LeaveFn on_leave_;
};

// 在 hwnd 上注册投放目标；target 的所有权仍归调用方。返回是否成功。
bool RegisterFileDrop(HWND hwnd, FileDropTarget* target);
void UnregisterFileDrop(HWND hwnd);

#endif  // RUNNER_FILE_DROP_H_
