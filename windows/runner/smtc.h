// Windows 系统媒体传输控件（SMTC）桥。
//
// 拿的是 Windows.Media.Control.GlobalSystemMediaTransportControlsSession——
// 就是按音量键时弹出的那个"正在播放"浮层背后的东西。支持它的播放器
// （网易云、QQ 音乐、Spotify、浏览器里的网页媒体）都会把标题、歌手、封面、
// 播放进度注册进去，我们只读不写。
//
// 为什么是"工作线程轮询"而不是"订阅事件"：
//   SMTC 的 MediaPropertiesChanged 之类回调跑在 WinRT 线程池线程上，而
//   flutter::MethodChannel::InvokeMethod 只能在平台线程调。这个工程里没有
//   任何跨线程投递的现成设施，事件方案得自己造 WM_APP 投递加 revoker 生命周期
//   管理。改成工作线程定时轮询、把结果写进带锁的快照，Dart 侧读快照是纯内存
//   读，既不阻塞也不需要跨线程投递。
//
// 另一条硬约束：主线程是 OleInitialize 起的 STA，在 STA 上对 WinRT 的
// IAsyncOperation 调 .get() 会死锁。所有异步都只在这个工作线程（MTA）里做。
#ifndef RUNNER_SMTC_H_
#define RUNNER_SMTC_H_

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// 播放状态，取值与 WinRT 的 GlobalSystemMediaTransportControlsSessionPlaybackStatus 一致
enum class SmtcStatus : int {
  kClosed = 0,
  kOpened = 1,
  kChanging = 2,
  kStopped = 3,
  kPlaying = 4,
  kPaused = 5,
};

// 一次轮询拍下来的完整状态。字符串一律 UTF-8。
struct SmtcSnapshot {
  bool available = false;
  std::string app;     // SourceAppUserModelId，用来分辨是哪个播放器
  std::string title;
  std::string artist;
  std::string album;
  int status = 0;
  bool can_play = false;
  bool can_pause = false;
  bool can_next = false;
  bool can_prev = false;
  bool can_seek = false;
  int64_t position_ms = 0;
  int64_t duration_ms = 0;
  // 播放器上报 position_ms 已经过去多久了。
  //
  // 这个字段是必须的，不是锦上添花：播放器并不逐帧更新 SMTC 的进度，实测
  // Spotify 大约 4.5 秒才推一次。不补上这段年龄，界面上的秒数就是一跳 5 秒，
  // 进度条也是一格一格挪。SMTC 自己提供了 LastUpdatedTime 就是为了这个。
  int64_t position_age_ms = 0;
  // 读到 position_ms 的本地时刻（GetTickCount64）。播放中由上层按经过时间
  // 外推，这样 250ms 的轮询间隔也能画出平滑的进度条。
  int64_t updated_at_ms = 0;
  // 封面版本号：只有换歌才自增。上层据此判断要不要重新取字节，
  // 避免每次轮询都把几十 KB 的图片搬一遍。
  int art_id = 0;
};

class Smtc {
 public:
  static Smtc& Instance();

  // 起工作线程。重复调用无副作用。
  void Start();
  void Stop();

  // 取当前快照（拷贝一份，调用方不用管锁）
  SmtcSnapshot Snapshot() const;

  // 取封面原始字节（JPEG/PNG，不是解码后的像素）。
  // art_id 对不上就返回空，说明上层拿的是过期的版本号。
  std::vector<uint8_t> Art(int art_id) const;

  // 控制命令。cmd: play / pause / toggle / next / prev / seek
  // 投给工作线程异步执行，返回值只表示"命令已排队且当前会话支持它"。
  bool Control(const std::string& cmd, int64_t position_ms);

  // --smtc-dump 用：把当前会话逐字段打到 stdout，用于验证各播放器到底给什么
  static void DumpOnce();

 private:
  Smtc() = default;
  ~Smtc();
  Smtc(const Smtc&) = delete;
  Smtc& operator=(const Smtc&) = delete;

  void Worker();

  mutable std::mutex mutex_;
  SmtcSnapshot snapshot_;
  std::vector<uint8_t> art_;

  std::thread thread_;
  std::atomic<bool> running_{false};

  // 待执行的控制命令。工作线程每轮取走执行。
  std::mutex cmd_mutex_;
  std::vector<std::pair<std::string, int64_t>> commands_;
};

#endif  // RUNNER_SMTC_H_
