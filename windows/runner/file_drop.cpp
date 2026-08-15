#include "file_drop.h"

#include <shellapi.h>
#include <shlobj.h>

namespace {

// 数据对象里有没有 CF_HDROP（也就是"一组文件路径"）
bool HasFiles(IDataObject* data) {
  if (!data) return false;
  FORMATETC fmt{};
  fmt.cfFormat = CF_HDROP;
  fmt.ptd = nullptr;
  fmt.dwAspect = DVASPECT_CONTENT;
  fmt.lindex = -1;
  fmt.tymed = TYMED_HGLOBAL;
  return data->QueryGetData(&fmt) == S_OK;
}

std::vector<std::wstring> ExtractFiles(IDataObject* data) {
  std::vector<std::wstring> out;
  if (!data) return out;

  FORMATETC fmt{};
  fmt.cfFormat = CF_HDROP;
  fmt.ptd = nullptr;
  fmt.dwAspect = DVASPECT_CONTENT;
  fmt.lindex = -1;
  fmt.tymed = TYMED_HGLOBAL;

  STGMEDIUM medium{};
  if (FAILED(data->GetData(&fmt, &medium))) return out;

  if (HDROP drop = static_cast<HDROP>(GlobalLock(medium.hGlobal))) {
    const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
    for (UINT i = 0; i < count; ++i) {
      // 先问长度（不含结尾 \0），再按 len+1 取；缓冲区必须留出结尾位置，
      // 否则最后一个字符会被截掉。
      const UINT len = DragQueryFileW(drop, i, nullptr, 0);
      if (len == 0) continue;
      std::wstring path(static_cast<size_t>(len) + 1, L'\0');
      const UINT got = DragQueryFileW(drop, i, path.data(), len + 1);
      path.resize(got);
      if (!path.empty()) out.push_back(path);
    }
    GlobalUnlock(medium.hGlobal);
  }
  ReleaseStgMedium(&medium);
  return out;
}

}  // namespace

FileDropTarget::FileDropTarget(OverFn on_over, DropFn on_drop, LeaveFn on_leave)
    : on_over_(std::move(on_over)),
      on_drop_(std::move(on_drop)),
      on_leave_(std::move(on_leave)) {}

HRESULT STDMETHODCALLTYPE FileDropTarget::QueryInterface(REFIID riid,
                                                         void** ppv) {
  if (!ppv) return E_POINTER;
  if (riid == IID_IUnknown || riid == IID_IDropTarget) {
    *ppv = static_cast<IDropTarget*>(this);
    AddRef();
    return S_OK;
  }
  *ppv = nullptr;
  return E_NOINTERFACE;
}

ULONG STDMETHODCALLTYPE FileDropTarget::AddRef() {
  return static_cast<ULONG>(InterlockedIncrement(&ref_));
}

ULONG STDMETHODCALLTYPE FileDropTarget::Release() {
  // 生命周期由持有者（窗口对象）管，这里只是计数不为 0 让 OLE 安心。
  // 不在归零时 delete：这个对象是窗口的成员，不是 new 出来的。
  const LONG n = InterlockedDecrement(&ref_);
  return static_cast<ULONG>(n < 0 ? 0 : n);
}

HRESULT STDMETHODCALLTYPE FileDropTarget::DragEnter(IDataObject* data,
                                                    DWORD /*key_state*/,
                                                    POINTL pt, DWORD* effect) {
  has_files_ = HasFiles(data);
  const bool accept =
      has_files_ && on_over_ && on_over_(POINT{pt.x, pt.y});
  if (effect) *effect = accept ? DROPEFFECT_COPY : DROPEFFECT_NONE;
  return S_OK;
}

HRESULT STDMETHODCALLTYPE FileDropTarget::DragOver(DWORD /*key_state*/,
                                                   POINTL pt, DWORD* effect) {
  const bool accept = has_files_ && on_over_ && on_over_(POINT{pt.x, pt.y});
  if (effect) *effect = accept ? DROPEFFECT_COPY : DROPEFFECT_NONE;
  return S_OK;
}

HRESULT STDMETHODCALLTYPE FileDropTarget::DragLeave() {
  has_files_ = false;
  if (on_leave_) on_leave_();
  return S_OK;
}

HRESULT STDMETHODCALLTYPE FileDropTarget::Drop(IDataObject* data,
                                               DWORD /*key_state*/, POINTL pt,
                                               DWORD* effect) {
  const POINT p{pt.x, pt.y};
  const bool accept = has_files_ && on_over_ && on_over_(p);
  has_files_ = false;
  if (on_leave_) on_leave_();

  if (accept) {
    std::vector<std::wstring> files = ExtractFiles(data);
    if (!files.empty() && on_drop_) on_drop_(p, files);
  }
  if (effect) *effect = accept ? DROPEFFECT_COPY : DROPEFFECT_NONE;
  return S_OK;
}

bool RegisterFileDrop(HWND hwnd, FileDropTarget* target) {
  if (!hwnd || !target) return false;
  // RegisterDragDrop 要求本线程已经 OleInitialize 过（main.cpp 里做了）。
  // 已经注册过会返回 DRAGDROP_E_ALREADYREGISTERED，先撤一次更稳。
  RevokeDragDrop(hwnd);
  return SUCCEEDED(RegisterDragDrop(hwnd, target));
}

void UnregisterFileDrop(HWND hwnd) {
  if (hwnd) RevokeDragDrop(hwnd);
}
