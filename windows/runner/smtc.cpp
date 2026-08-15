#include "smtc.h"

#include <windows.h>

#include <winrt/Windows.Foundation.h>
// GetSessions() 返回 IVectorView，它的 Size()/GetAt() 定义在 Collections 头里。
// 少这一个 include 会报 C3779"要使用将会返回 auto 的函数，必须首先定义此函数"——
// C++/WinRT 的成员函数是按类型分文件定义的，用到哪个类型就得 include 哪个。
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Media.Control.h>
#include <winrt/Windows.Storage.Streams.h>

#include <chrono>
#include <cstdio>

namespace wmc = winrt::Windows::Media::Control;
namespace wss = winrt::Windows::Storage::Streams;

namespace {

// WinRT 的 hstring 是 UTF-16，通道要 UTF-8
std::string Utf8(const winrt::hstring& s) {
  if (s.empty()) return {};
  const int need = WideCharToMultiByte(CP_UTF8, 0, s.c_str(),
                                       static_cast<int>(s.size()), nullptr, 0,
                                       nullptr, nullptr);
  if (need <= 0) return {};
  std::string out(static_cast<size_t>(need), '\0');
  WideCharToMultiByte(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()),
                      out.data(), need, nullptr, nullptr);
  return out;
}

// WinRT 的 TimeSpan 是 100ns 刻度
int64_t Ms(const winrt::Windows::Foundation::TimeSpan& t) {
  return t.count() / 10000;
}

// 把 IRandomAccessStreamReference 整个读成字节。
// 只在换歌时调用——封面几十 KB，每轮都读是浪费。
std::vector<uint8_t> ReadThumbnail(
    const wss::IRandomAccessStreamReference& ref) {
  std::vector<uint8_t> out;
  if (!ref) return out;
  try {
    auto stream = ref.OpenReadAsync().get();
    const uint32_t size = static_cast<uint32_t>(stream.Size());
    if (size == 0 || size > 8 * 1024 * 1024) return out;  // 防御性上限
    wss::Buffer buffer(size);
    stream.ReadAsync(buffer, size, wss::InputStreamOptions::None).get();
    auto reader = wss::DataReader::FromBuffer(buffer);
    out.resize(buffer.Length());
    if (!out.empty()) {
      reader.ReadBytes(winrt::array_view<uint8_t>(out));
    }
  } catch (...) {
    out.clear();
  }
  return out;
}

}  // namespace

Smtc& Smtc::Instance() {
  static Smtc instance;
  return instance;
}

Smtc::~Smtc() { Stop(); }

void Smtc::Start() {
  if (running_.exchange(true)) return;
  thread_ = std::thread([this] { Worker(); });
}

void Smtc::Stop() {
  if (!running_.exchange(false)) return;
  if (thread_.joinable()) thread_.join();
}

SmtcSnapshot Smtc::Snapshot() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return snapshot_;
}

std::vector<uint8_t> Smtc::Art(int art_id) const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (art_id != snapshot_.art_id) return {};
  return art_;
}

bool Smtc::Control(const std::string& cmd, int64_t position_ms) {
  {
    std::lock_guard<std::mutex> lock(cmd_mutex_);
    commands_.emplace_back(cmd, position_ms);
  }
  return true;
}

void Smtc::Worker() {
  // 这条线程必须是 MTA：主线程被 OleInitialize 设成了 STA，在 STA 上对
  // IAsyncOperation 调 .get() 会死锁。工作线程自己起 MTA 就没这个问题。
  winrt::init_apartment(winrt::apartment_type::multi_threaded);

  wmc::GlobalSystemMediaTransportControlsSessionManager manager{nullptr};
  // 换歌判据：同一首歌不重复拉封面
  std::string last_key;
  int art_seq = 0;

  while (running_.load()) {
    try {
      if (!manager) {
        manager =
            wmc::GlobalSystemMediaTransportControlsSessionManager::RequestAsync()
                .get();
      }
      auto session = manager ? manager.GetCurrentSession() : nullptr;

      // 先把排队的控制命令执行掉，再采样，这样按下暂停后最快 250ms 就能
      // 在界面上看到状态变化
      std::vector<std::pair<std::string, int64_t>> pending;
      {
        std::lock_guard<std::mutex> lock(cmd_mutex_);
        pending.swap(commands_);
      }
      for (const auto& c : pending) {
        if (!session) break;
        try {
          if (c.first == "play") {
            session.TryPlayAsync().get();
          } else if (c.first == "pause") {
            session.TryPauseAsync().get();
          } else if (c.first == "toggle") {
            session.TryTogglePlayPauseAsync().get();
          } else if (c.first == "next") {
            session.TrySkipNextAsync().get();
          } else if (c.first == "prev") {
            session.TrySkipPreviousAsync().get();
          } else if (c.first == "seek") {
            // 参数是 100ns 刻度，不是毫秒
            session.TryChangePlaybackPositionAsync(c.second * 10000).get();
          }
        } catch (...) {
          // 播放器不支持某个操作时会抛，忽略即可——canXxx 已经告诉过界面了
        }
      }

      SmtcSnapshot snap;
      std::vector<uint8_t> art;
      bool art_changed = false;

      if (session) {
        snap.available = true;
        snap.app = Utf8(session.SourceAppUserModelId());

        auto info = session.GetPlaybackInfo();
        if (info) {
          snap.status = static_cast<int>(info.PlaybackStatus());
          auto controls = info.Controls();
          snap.can_play = controls.IsPlayEnabled();
          snap.can_pause = controls.IsPauseEnabled();
          snap.can_next = controls.IsNextEnabled();
          snap.can_prev = controls.IsPreviousEnabled();
          snap.can_seek = controls.IsPlaybackPositionEnabled();
        }

        auto tl = session.GetTimelineProperties();
        if (tl) {
          snap.position_ms = Ms(tl.Position());
          snap.duration_ms = Ms(tl.EndTime()) - Ms(tl.StartTime());
          // 播放器上报这个位置是多久以前的事。实测 Spotify 每 4.5 秒才推一次，
          // 不补这段年龄，界面上就是一跳 5 秒。
          try {
            const auto age = winrt::clock::now() - tl.LastUpdatedTime();
            const int64_t age_ms =
                std::chrono::duration_cast<std::chrono::milliseconds>(age)
                    .count();
            // 有的播放器不填 LastUpdatedTime（留在 1601 年的纪元原点），
            // 那会算出一个天文数字，直接当 0 处理
            snap.position_age_ms = (age_ms < 0 || age_ms > 60000) ? 0 : age_ms;
          } catch (...) {
            snap.position_age_ms = 0;
          }
        }
        snap.updated_at_ms = static_cast<int64_t>(GetTickCount64());

        auto props = session.TryGetMediaPropertiesAsync().get();
        if (props) {
          snap.title = Utf8(props.Title());
          snap.artist = Utf8(props.Artist());
          snap.album = Utf8(props.AlbumTitle());

          const std::string key = snap.app + '\x01' + snap.title + '\x01' +
                                  snap.artist + '\x01' + snap.album;
          if (key != last_key) {
            last_key = key;
            art = ReadThumbnail(props.Thumbnail());
            art_changed = true;
            ++art_seq;
          }
        }
        snap.art_id = art_seq;
      } else {
        last_key.clear();
      }

      {
        std::lock_guard<std::mutex> lock(mutex_);
        snapshot_ = snap;
        if (art_changed) art_ = std::move(art);
      }
    } catch (...) {
      // 会话管理器可能在系统忙时短暂失败；丢掉它，下一轮重新申请
      manager = nullptr;
      std::lock_guard<std::mutex> lock(mutex_);
      snapshot_ = SmtcSnapshot{};
    }

    // 250ms：位置由上层外推，所以不需要更快；再慢会让暂停/切歌的反馈发木
    for (int i = 0; i < 25 && running_.load(); ++i) {
      Sleep(10);
    }
  }
}

void Smtc::DumpOnce() {
  // 探针：只在 --smtc-dump 下跑，把各播放器实际给出的字段原样打出来。
  // 这条路径不共用 Worker，免得探针的结论被我们自己的缓存逻辑污染。
  std::thread([] {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    for (int round = 0; round < 20; ++round) {
      try {
        auto manager =
            wmc::GlobalSystemMediaTransportControlsSessionManager::RequestAsync()
                .get();
        auto sessions = manager.GetSessions();
        printf("[smtc] ===== 第 %d 次采样，会话数 %u =====\n", round + 1,
               sessions.Size());
        auto current = manager.GetCurrentSession();
        for (uint32_t i = 0; i < sessions.Size(); ++i) {
          auto s = sessions.GetAt(i);
          const bool is_current =
              current && current.SourceAppUserModelId() == s.SourceAppUserModelId();
          printf("[smtc] --- 会话 %u%s app=%s\n", i,
                 is_current ? " (当前)" : "",
                 Utf8(s.SourceAppUserModelId()).c_str());
          try {
            auto info = s.GetPlaybackInfo();
            auto c = info.Controls();
            printf("[smtc]     status=%d play=%d pause=%d next=%d prev=%d seek=%d\n",
                   static_cast<int>(info.PlaybackStatus()), c.IsPlayEnabled(),
                   c.IsPauseEnabled(), c.IsNextEnabled(), c.IsPreviousEnabled(),
                   c.IsPlaybackPositionEnabled());
          } catch (...) {
            printf("[smtc]     playbackInfo 取不到\n");
          }
          try {
            auto tl = s.GetTimelineProperties();
            const auto age = winrt::clock::now() - tl.LastUpdatedTime();
            int64_t age_ms =
                std::chrono::duration_cast<std::chrono::milliseconds>(age)
                    .count();
            if (age_ms < 0 || age_ms > 60000) age_ms = 0;
            // raw 是播放器上报的原始值，它好几秒才更新一次；raw+age 才是"现在"。
            // 界面上"读秒 5 秒一步进"就是因为只用了 raw。
            printf("[smtc]     raw=%lldms age=%lldms -> 实际=%lldms end=%lldms\n",
                   static_cast<long long>(Ms(tl.Position())),
                   static_cast<long long>(age_ms),
                   static_cast<long long>(Ms(tl.Position()) + age_ms),
                   static_cast<long long>(Ms(tl.EndTime())));
          } catch (...) {
            printf("[smtc]     timeline 取不到\n");
          }
          try {
            auto p = s.TryGetMediaPropertiesAsync().get();
            auto thumb = ReadThumbnail(p.Thumbnail());
            printf("[smtc]     title=[%s]\n", Utf8(p.Title()).c_str());
            printf("[smtc]     artist=[%s]\n", Utf8(p.Artist()).c_str());
            printf("[smtc]     album=[%s]\n", Utf8(p.AlbumTitle()).c_str());
            printf("[smtc]     albumArtist=[%s] trackNumber=%d\n",
                   Utf8(p.AlbumArtist()).c_str(), p.TrackNumber());
            printf("[smtc]     封面字节数=%zu%s\n", thumb.size(),
                   thumb.empty() ? "（没有封面）" : "");
          } catch (...) {
            printf("[smtc]     mediaProperties 取不到\n");
          }
        }
        if (sessions.Size() == 0) {
          printf("[smtc] 没有任何会话——放首歌再试\n");
        }
      } catch (const winrt::hresult_error& e) {
        printf("[smtc] 失败 hr=0x%08X %s\n", static_cast<unsigned>(e.code()),
               Utf8(e.message()).c_str());
      } catch (...) {
        printf("[smtc] 失败（未知异常）\n");
      }
      fflush(stdout);
      Sleep(3000);
    }
    printf("[smtc] 探针结束\n");
    fflush(stdout);
  }).detach();
}
