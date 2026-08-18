# Vectra — 把小组件放回桌面

**Vectra**（原名 LiquidWidgets）是一款面向 **Windows 11/10** 的桌面小组件引擎，由 **MacroSTAR Studio** 开发。它让小组件直接**渲染在桌面壁纸上**，作为桌面本身的一部分，而非像 Windows 11 自带 Widget 侧边栏那样需要点击呼出、失去焦点即消失。

---

## 1. 核心理念

Windows 11 引入了 Widget 面板，但它是**覆盖在桌面上的一个浮层**——点击任务栏图标展开，点击空白处收起。小组件始终无法真正"待在桌面上"。

Vectra 的解决方案是创建一个**全屏透明窗口**，置于所有窗口的**最底层**（Z-order 底部），在此窗口上渲染小组件。这样：

- 桌面壁纸上的小组件**始终可见**，不会被其他窗口遮挡
- 点击桌面空白处 = 正常操作桌面（文件、右键菜单等）
- 小组件**不干扰**任何窗口操作
- 支持**多显示器**，每个显示器可独立放置小组件

---

## 2. 技术栈

| 层 | 技术 |
|---|---|
| UI 框架 | **Flutter 3.x**（Dart >= 3.12.2） |
| 桌面平台 | **Windows Win32**（仅 Windows） |
| 插件运行时 | **QuickJS**（嵌入式 JS 引擎，通过 `flutter_js` 集成） |
| 原生桥接 | **MethodChannel**（`vectra/native`） |
| 原生窗口 | **C++ Win32 API** + Windows 11 系统背景效果（Mica/Acrylic） |
| 设置面板 UI | **fluent_ui**（Windows 11 风格组件库） |
| 构建系统 | **CMake** + Visual Studio 2022 |
| 打包 | **Inno Setup 6**（便携式自解压安装包） |
| 字体 | **HarmonyOS Sans SC**（6 字重） |
| AI 侧边栏 | **OpenAI 兼容 API**（SSE 流式 + 工具调用 Agent） |
| 状态存储 | **JSON 文件**（config.json, plugindata/*.json） |
| 测试 | Flutter test + Node.js JS 单元测试 |

---

## 3. 架构概览

Vectra 采用 **"双进程、多窗口、两引擎"** 架构：

```
┌─────────────────────────────────────────────────────────────────┐
│                      Windows 桌面                               │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Flutter Engine 1（主进程）                               │  │
│  │  ┌──────────────────────┐  ┌──────────────────────────┐  │  │
│  │  │   Tile Window        │  │   Settings Panel          │  │  │
│  │  │  全屏透明窗口         │  │  独立任务栏窗口            │  │  │
│  │  │  Z-order: 最底层     │  │  Z-order: 正常           │  │  │
│  │  │  渲染所有小组件       │  │  fluent_ui 设置面板       │  │  │
│  │  └──────────────────────┘  └──────────────────────────┘  │  │
│  │                         同 Isolate / 同 Engine            │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Flutter Engine 2（侧边栏进程）                            │  │
│  │  ┌──────────────────────────────────────────────────┐   │  │
│  │  │  AI Sidebar Window                               │   │  │
│  │  │  右侧浮动面板，Z-order: 最顶层                      │   │  │
│  │  │  OpenAI 流式对话 + 文件解读 + 工具调用 Agent         │   │  │
│  │  └──────────────────────────────────────────────────┘   │  │
│  │  独立 Engine，独立 Isolate，通过文件系统通讯              │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Native C++ 层（Windows 原生 Runner）                     │  │
│  │  窗口创建 · Z-order 管理 · 命中测试 · 壁纸捕获            │  │
│  │  SMTC 媒体控制 · 拖放 · 全局热键 · 启动闪屏               │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### 3.1 为什么是两引擎？

- **Tile Window** 必须处于 Z-order 最底层（`HWND_BOTTOM`），否则小组件会遮挡其他窗口
- **AI 侧边栏** 必须处于 Z-order 最顶层（`HWND_TOPMOST`），否则无法始终可见
- 同一个窗口不能同时处于最底层和最顶层，因此需要两个独立的 Flutter 引擎
- 两个引擎通过文件系统通信（共享 `config.json`，`chat.json` 由侧边栏独占）

### 3.2 窗口一览

| 窗口 | 用途 | 位置 | Z-order | 引擎 |
|---|---|---|---|---|
| **Tile Window** | 桌面小组件渲染 | 全虚拟桌面 | 最底层 | Engine 1 |
| **Settings Panel** | 配置 UI | 独立任务栏窗口 | 正常 | Engine 1（第二视图） |
| **AI Sidebar** | AI 聊天助手 | 屏幕右侧 | 最顶层 | Engine 2（独立进程） |
| **Splash Window** | 启动加载进度 | 屏幕居中 | 最顶层 | Native（独立线程） |

---

## 4. 核心架构设计

### 4.1 单窗口 Tile 架构

**前身**（Electron 版本）为每个小组件创建一个独立窗口，导致跨窗口拖放、Z-order 管理等问题。Vectra 改用一个**全屏窗口 + 窗口区域裁剪**的方案：

1. 创建一个覆盖整个虚拟桌面的全屏透明窗口
2. 用 `SetWindowRgn` 将窗口区域裁剪为所有小组件圆角矩形的**并集**
3. 在 `WM_NCHITTEST` 中，点击非小组件区域返回 `HTTRANSPARENT`，让鼠标事件穿透到桌面
4. 所有小组件在同一个 Flutter 渲染树中，拖放无跨窗口问题

```
桌面上的点击行为：
┌─────────────────────────────────────────────────────────┐
│  桌面壁纸区域（点击穿透到桌面）                          │
│  ┌──────────┐  ┌──────────┐                             │
│  │ 时钟组件  │  │ 天气组件  │  ← 点击命中组件            │
│  │ (窗口区域) │  │ (窗口区域) │                             │
│  └──────────┘  └──────────┘                             │
│        桌面图标（正常操作）                              │
│  ┌────┐ ┌────┐ ┌────┐                                  │
│  │回收站│ │此电脑│ │文件夹│  ← 点击穿透到桌面            │
│  └────┘ └────┘ └────┘                                  │
└─────────────────────────────────────────────────────────┘
```

### 4.2 窗口区域与命中测试

- **C++ 层**（`hit_region.cpp`）：线程安全的矩形集合，接收 Dart 层传入的卡片位置，计算 `SetWindowRgn` 的裁剪区域和 `WM_NCHITTEST` 的命中判定
- **Dart 层**（`hit.dart`）：同样实现圆角矩形命中测试，用于 Flutter 指针事件路由
- 两者必须**严格一致**，否则会出现点击区域错位

### 4.3 材料模拟（Material Simulation）

Windows 11 的 Mica/Acrylic 系统背景效果是**在全窗口矩形上渲染**的，不受 `SetWindowRgn` 影响。这意味着如果直接开启系统背景，效果会出现在整个虚拟桌面区域而非仅小组件区域。

Vectra 的解决方案：**手动模拟**材料效果：

1. 使用 `Desktop Duplication API` 捕获桌面壁纸像素
2. 对捕获的图像进行**高斯模糊**
3. 在 Flutter 层将模糊后的壁纸**按卡片形状裁剪**并合成到卡片背景上
4. 支持三种材料：`opaque`（不透明）、`acrylic`（亚克力）、`mica`（云母）

### 4.4 插件系统

Vectra 的插件基于 **QuickJS** 嵌入式 JavaScript 引擎：

```
┌─────────────────────────────────────────────────────┐
│  每个卡片 = 独立的 QuickJS 运行时实例 (~200KB)      │
│                                                      │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐ │
│  │  Clock 插件  │  │ Weather 插件 │  │  Todo 插件   │ │
│  │  (JS 沙箱)   │  │  (JS 沙箱)   │  │  (JS 沙箱)   │ │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘ │
│         │               │               │          │
│         └───────────────┼───────────────┘          │
│                         │                           │
│                  ┌──────┴──────┐                    │
│                  │  PluginHost  │                    │
│                  │  (Dart 侧)  │                    │
│                  │  storage    │                    │
│                  │  http       │                    │
│                  │  media      │                    │
│                  │  settings   │                    │
│                  └──────┬──────┘                    │
│                         │                           │
│                  ┌──────┴──────┐                    │
│                  │  JSON UI 树  │                    │
│                  │  → Flutter  │                    │
│                  │  Widget 渲染 │                    │
│                  └─────────────┘                    │
└─────────────────────────────────────────────────────┘
```

**关键设计：**

- **隔离性**：每个卡片拥有独立的 QuickJS 运行时，全局变量不互相污染
- **沙箱**：JS 代码无法访问 DOM、文件系统、网络——只能通过 `ctx` API 调用宿主能力
- **UI 描述**：插件渲染一个 **JSON UI 树**，Dart 侧的 `PluginView` 将其解析为 Flutter Widget（支持 col/row/stack/grid/scroll/text/image/icon/divider/progress/slider/input/flip/tap/box/spacer/gap/flex 等）
- **执行预算**：每次渲染有 800ms 超时保护，防止死循环或卡死
- **定时器**：JS 侧 `setTimeout`/`setInterval` 映射到 Dart 的 `Timer`，受窗口可见性控制

**插件 API（ctx 对象）：**

```javascript
// 状态存储
ctx.storage.put(key, value)    // 保存键值对（持久化到 plugindata/<id>.json）
ctx.storage.get(key)           // 读取键值对
ctx.storage.clear()            // 清除所有数据

// 缓存（带过期时间，按 LRU 淘汰，最多 500 条）
ctx.cache.set(key, value, ttlMs)
ctx.cache.get(key)

// 网络请求
ctx.http.get(url, headers)     // HTTP GET
ctx.http.post(url, body, headers)

// 媒体控制
ctx.media.getState()           // 获取当前播放状态
ctx.media.onUpdate(callback)   // 监听播放状态变化
ctx.media.previous() / playPause() / next()

// 插件设置
ctx.settings.get(key)          // 读取用户设置
ctx.settings.set(key, value)   // 更新用户设置

// 渲染
ctx.render()                   // 返回 JSON UI 树，触发 Flutter 渲染
ctx.setSize(cols, rows)        // 请求调整卡片尺寸
ctx.getSize()                  // 获取当前卡片尺寸
```

**插件生命周期：**

```
注册 → 扫描 manifest.json → 加入插件列表
  │
放置 → 用户选择尺寸 → 创建卡片实例
  │
挂载 → 创建 QuickJS 运行时 → 注入 prelude → 加载 index.js
  │
  ├── 首次渲染 → 调用 render() → 显示 UI
  ├── 定时刷新 → 按需调用 render() → 更新 UI
  ├── 用户交互 → 点击/输入触发回调 → 更新状态 → 重新渲染
  ├── 尺寸变化 → 调用 setSize → 重新布局
  │
卸载 → 清除定时器 → 销毁运行时 → 释放内存
```

### 4.5 内置插件

| 插件 | ID | 尺寸 | 功能 |
|---|---|---|---|
| **时钟** | `clock` | 2x2, 3x2, 3x3, 4x2 | 数字时钟、日期、秒针开关、12/24 小时制 |
| **日历** | `calendar` | 3x3, 4x3, 4x4, 5x4, 5x5 | 月历、农历、节气、节假日 |
| **待办** | `todo` | 2x3, 3x3, 3x4, 4x4 | 待办列表、本地存储、隐藏已完成 |
| **天气** | `weather` | 3x2, 3x3, 4x2, 4x3 | Open-Meteo 天气（无需 API Key）、自动定位 |
| **歌词** | `lyrics` | 4x2, 5x2, 6x2, 5x3, 6x3, 6x4, 7x4, 8x4 | 系统媒体播放歌词、滚动显示、翻译、网易云/LRCLIB 来源 |

### 4.6 网格系统

小组件通过**离散网格**定位，而非自由像素坐标：

```
gridCell = 112px（可配置）
gridGap = 12px（可配置）

┌──────────┬──────────┬──────────┐
│  2x2     │          │          │
│  时钟    │  空白     │  空白     │
│          │          │          │
├──────────┼──────────┼──────────┤
│          │  3x3      │          │
│  空白     │  日历     │  空白     │
│          │          │          │
├──────────┼──────────┼──────────┤
│          │          │          │
│  空白     │  空白     │  空白     │
│          │          │          │
└──────────┴──────────┴──────────┘
```

- 位置以网格坐标（col, row）存储
- 尺寸以网格单元数（cols, rows）存储
- 每个卡片锚定到特定显示器，记录在显示器上的相对位置
- 显示器插拔、分辨率变化、缩放变化时自动重算位置

### 4.7 吸附对齐引擎

拖放卡片时，`snap.dart` 提供磁吸对齐：

- 检测卡片边缘与附近卡片边缘的对齐关系
- 绘制蓝色对齐引导线（`guides.dart`）
- 阈值可配置，默认吸附到最近的网格对齐位置

### 4.8 AI 侧边栏

AI 侧边栏是一个独立的 Flutter 应用，运行在第二个引擎中：

- **API 兼容**：OpenAI 兼容接口（支持自定义 baseUrl 和模型）
- **SSE 流式**：服务端事件流式输出，打字机效果
- **文件解读**：支持 txt、md、json、csv、docx、xlsx、pptx、PDF 文件解析
- **工具调用 Agent**：三级风险机制
  - **read**（低风险）：文件读取、目录列表——自动执行
  - **write**（中风险）：音量调节、主题切换、打开 URL——用户确认
  - **danger**（高风险）：PowerShell 执行、文件删除、关机——用户确认
- **全局热键**：默认 Ctrl+Alt+Space 呼出/隐藏
- **视觉风格**：可配置毛玻璃效果、颜色、透明度

---

## 5. 数据持久化

所有用户数据存储在 **`userdata/`** 目录下（与可执行文件同级），实现便携式设计：

```
userdata/
├── config.json              # 全局配置 + 卡片布局 + AI 设置
├── chat.json                # AI 侧边栏聊天历史（侧边栏独占）
├── plugindata/              # 插件数据
│   ├── clock.json           #   clock 插件的键值存储
│   ├── todo.json            #   todo 插件的键值存储
│   ├── clock/               #   clock 插件的缓存目录
│   │   ├── <hash>.json      #     缓存条目（最多 500 条）
│   │   └── ...
│   └── ...
├── plugins/                 # 第三方插件
│   └── <id>/
│       ├── manifest.json
│       └── index.js
└── logs/                    # 日志文件
    ├── main-2025-01-01.log  #   主引擎日志
    └── sidebar-2025-01-01.log # 侧边栏日志
```

**config.json 结构：**

```json
{
  "version": 1,
  "gridCell": 112,
  "gridGap": 12,
  "snapEnabled": true,
  "snapThreshold": 12,
  "locked": false,
  "animations": true,
  "cardColor": -1077952513,
  "cardRadius": 26,
  "material": "mica",
  "glassTint": 30,
  "glassBlur": 20,
  "liveRefreshMs": 0,
  "theme": "auto",
  "cards": [
    {
      "id": "uuid",
      "plugin": "clock",
      "col": 0,
      "row": 0,
      "cols": 2,
      "rows": 2,
      "zIndex": 0,
      "monitor": 0,
      "monitorX": 0.0,
      "monitorY": 0.0,
      "settings": {}
    }
  ],
  "ai": {
    "apiKey": "",
    "baseUrl": "https://api.openai.com/v1",
    "model": "gpt-4o",
    "systemPrompt": "...",
    "temperature": 0.7,
    "maxHistory": 50,
    "sidebarWidth": 380,
    "glass": true,
    "tint": 30,
    "radius": 12,
    "blurSigma": 20,
    "agent": false,
    "dock": true,
    "hotkeyMods": 6,
    "hotkeyVk": 32
  }
}
```

---

## 6. 原生 C++ 层详解

### 6.1 窗口管理

**Tile Window**（`flutter_window.cpp`）：
- 创建时覆盖整个虚拟桌面（`GetSystemMetrics(SM_CXVIRTUALSCREEN)` × `SM_CYVIRTUALSCREEN`）
- 设置 `WS_EX_LAYERED` + `WS_EX_TRANSPARENT` 扩展样式
- 设置 `WS_EX_NOACTIVATE` 防止窗口获得焦点
- 通过 `SetWindowPos(HWND_BOTTOM, ...)` 保持在最底层
- 监听 `WM_DISPLAYCHANGE` 在显示器变化时调整大小
- 监听 `WM_WINDOWPOSCHANGING` 阻止外部 Z-order 修改

**Sidebar Window**（`sidebar_window.cpp`）：
- 固定在屏幕右侧，宽度可配置
- 独立 Flutter 引擎
- 支持隐藏/显示切换，最小化到 dock 图标
- 拖放文件到侧边栏自动上传给 AI

**Settings Panel**（`panel_window.cpp`）：
- 使用 `FlutterDesktopEngineCreateViewController` 创建同一引擎的第二视图
- 独立任务栏窗口，可独立拖动

### 6.2 命中测试（`hit_region.cpp`）

```cpp
class HitRegion {
  std::vector<RECT> rects;  // 线程安全的卡片矩形列表
  CRITICAL_SECTION cs;

  void SetRects(const std::vector<RECT>& new_rects);
  bool Contains(POINT pt) const;  // 判断点是否在任一卡片内
};
```

- Dart 侧在卡片位置变化时通过 MethodChannel `setRegion` 传入新矩形
- C++ 侧更新 `SetWindowRgn` 裁剪窗口区域
- `WM_NCHITTEST` 中调用 `Contains()` 决定是否让鼠标事件穿透

### 6.3 桌面捕获（`desktop_capture.cpp`）

- 使用 `IDXGIOutputDuplication`（Desktop Duplication API）
- 捕获整个桌面为 BGRA 像素缓冲区
- 通过 MethodChannel 传回 Dart 侧用于壁纸模糊和材料模拟

### 6.4 SMTC 媒体控制（`smtc.cpp`）

- 通过 `Windows.Media.Control` UWP API 获取系统媒体信息
- 监听 `CurrentSessionChanged` 和 `MediaPropertiesChanged` 事件
- 提供：标题、艺术家、专辑、播放状态、进度、专辑封面
- 支持：上一曲、播放/暂停、下一曲

### 6.5 文件拖放（`file_drop.cpp`）

- 实现 `IDropTarget` COM 接口
- 注册到 Tile Window 和 Sidebar Window
- 拖放文件到桌面 → 插件处理（如歌词插件拖入 LRC 文件）
- 拖放文件到侧边栏 → AI 解读文件内容

---

## 7. 日志系统

统一的异步日志系统（`logger.dart`）：

- **双输出**：同时写入文件和控制台
- **每日轮转**：按日期分割文件（`main-YYYY-MM-DD.log`）
- **7 天保留**：自动清理过期日志
- **密钥脱敏**：自动将 `sk-` 开头的 API Key 替换为 `***`
- **异步写入**：日志队列批量写入，不阻塞主线程

---

## 8. 构建与运行

### 开发环境要求

- Flutter SDK >= 3.12.2（Dart >= 3.12.2）
- Visual Studio 2022（含 C++ 桌面开发工作负载）
- CMake
- Node.js（用于 JS 插件测试）

### 构建命令

```powershell
# 获取依赖
flutter pub get

# 构建 Release
flutter build windows --release --no-pub

# 完整构建 + 便携式安装包
tool\build_release.bat

# 跳过 Flutter 构建，仅重新打包
tool\build_release.bat --skip
```

### 运行命令

```powershell
# 正常启动
flutter run

# 启动时打开设置面板
flutter run --dart-define=args=--panel

# 启动时打开 AI 侧边栏
flutter run --dart-define=args=--ai

# 详细日志输出
flutter run --dart-define=args=--verbose

# 窗口浮到最前（仅用于截图，非正常使用）
flutter run --dart-define=args=--raise
```

### 测试

```powershell
# Flutter 测试
flutter test --no-pub

# JS 插件测试
node test\js\lrc_verify.js
node test\js\lunar_verify.js
```

---

## 9. 设计原则

1. **便携优先**：所有数据存储在 `userdata/` 目录下，无需注册表、无需安装器，可拖拽迁移
2. **单窗口 Tile**：所有小组件在一个窗口中渲染，消除跨窗口拖放问题
3. **插件隔离**：每个卡片独立 QuickJS 沙箱，互不干扰
4. **材料模拟**：系统背景效果不兼容窗口裁剪，故手动捕获+模糊+合成来模拟
5. **双引擎架构**：Tile 窗口需在最底层，AI 侧边栏需在最顶层，一个引擎无法同时满足
6. **多显示器感知**：卡片锚定到具体显示器，适应插拔、缩放、分辨率变化
7. **统一日志**：Dart + C++ 统一日志格式，每日轮转，自动脱敏

---

## 10. 目录结构

```
I:\Git\Vectra/
├── assets/plugins/          # 内置插件（clock, calendar, todo, weather, lyrics）
├── lib/
│   ├── main.dart            # 主引擎入口
│   ├── sidebar_main.dart    # AI 侧边栏入口
│   ├── ai/                  # AI 侧边栏逻辑（chat_client, tools, file_parser）
│   ├── core/                # 纯逻辑层（grid, snap, hit, monitor, logger, paths）
│   ├── model/               # 数据模型（card, settings, ai_settings）
│   ├── native/              # Dart-C++ 桥接（native_bridge.dart）
│   ├── plugin/              # 插件系统（runtime, host, node, registry, manifest）
│   ├── store/               # 持久化（store.dart）
│   └── ui/                  # Flutter UI 组件（surface, card_view, panel, ai_sidebar）
├── windows/runner/          # C++ 原生层（6 个窗口类 + 工具类）
├── test/                    # 测试（Flutter + JS）
└── tool/                    # 构建工具脚本
```

---

## 11. 适用场景

- **桌面美化爱好者**：将天气、日历、待办等小组件放在桌面上，替代 Windows 11 的 Widget 侧边栏
- **效率工具用户**：在桌面上始终可见的待办列表、日历、时钟
- **音乐爱好者**：在桌面上显示当前播放的歌词，支持滚动和翻译
- **AI 助手用户**：通过快捷键呼出 AI 侧边栏，快速提问、解读文件、执行系统操作
- **插件开发者**：使用 JavaScript + JSON UI 树开发自定义小组件，无需接触 Flutter/Dart