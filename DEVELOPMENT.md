# Vectra 开发手册

本文档记录 Vectra 项目的开发规矩、注意事项和工作流程。面向项目成员，不是用户文档。

---

## 1. 版本号

**唯一出处**：`pubspec.yaml` 里的 `version: A.B.C+D`。

- Windows 四段版本：`A.B.C.D`（如 `0.1.2.146`）
- 便携包文件名：`Vectra-0.1.2.146-便携版.exe`
- HTTP User-Agent：`Vectra/0.1.2.146`

**每次功能完成，版本号 +2**（`0.1.2.146` → `0.1.2.148` → `0.1.2.150`）。不跳号，不留空档。

**改版本号的方法**：

```powershell
$f = "pubspec.yaml"
$t = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8)
$t = $t -replace "version: 0\.1\.2\+\d+", "version: 0.1.2+148"
[IO.File]::WriteAllText($f, $t, (New-Object Text.UTF8Encoding($false)))
```

注意 UTF-8 无 BOM。不要用记事本改。

---

## 2. 开发环境

| 工具 | 版本 | 说明 |
|:---|:---|:---|
| Flutter | 3.x（Dart SDK ≥ 3.12） | `C:\flutter\bin` |
| Visual Studio | 2022（Community 即可） | 需要 "使用 C++ 的桌面开发" 工作负载 |
| Inno Setup | 6.x | 打包便携包用，装在 `D:\Inno Setup 6\` |
| Node.js | 任意 | 跑 `test/js/` 下的 JS 测试脚本 |

**PATH 配置**：PowerShell 里 Flutter 可能找不到，需要手动加：

```powershell
$env:PATH = "C:\flutter\bin;$env:PATH"
```

---

## 3. 构建

### 3.1 日常开发构建

```powershell
flutter build windows --release --no-pub
```

产物：`build\windows\x64\runner\Release\`

### 3.2 打正式包

```powershell
tool\build_release.bat
```

三步走：
1. `flutter build windows --release --no-pub`
2. 复制 VC++ 运行时 DLL（`msvcp140.dll` 等）到 Release 目录
3. Inno Setup 打便携包 → `installer\out\Vectra-<版本>-便携版.exe`

**注意**：`build_release.bat` 会自动设好 VS 环境。直接跑 `flutter build` 有时会因为 CMake 缓存问题失败，用 `build_release.bat` 更稳。

### 3.3 构建失败排查

| 症状 | 原因 | 解法 |
|:---|:---|:---|
| `Unable to load asset` | pubspec.yaml 里没加 assets 条目 | 加上 `- assets/plugins/xxx/` |
| `error MSB3073` INSTALL 失败 | CMake 缓存损坏或 native_assets 缺失 | `Remove-Item -Recurse build\windows` 后重跑 |
| `format error: <<<<<<< HEAD` | 合并冲突残留 | `git checkout` 冲突文件后 `flutter pub get` |
| LINK fatal error | vectra.exe 还在跑 | `Get-Process -Name vectra \| Stop-Process -Force` |

---

## 4. 测试

### 4.1 跑测试

```powershell
flutter test --no-pub
```

当前 **276 个测试**，全部通过才算合格。

### 4.2 静态分析

```powershell
flutter analyze --no-pub
```

当前 **3 条基线告警**（info 级别，不影响功能）。如果新增了 warning 或 error，必须修掉。

### 4.3 新增测试的原则

- **TDD 优先**：先写测试，定义 API 契约，再实现
- **每个新功能/修复都要有对应测试**
- 测试文件命名：`test/xxx_test.dart`
- 测试目录下还有 JS 测试脚本：`test/js/lrc_verify.js` 等，用 Node.js 跑

### 4.4 提交前必须跑的命令

```powershell
flutter analyze --no-pub    # 确认无新增 error
flutter test --no-pub       # 确认全绿
```

---

## 5. Git 约定

### 5.1 提交信息格式

```
类型: 简短描述

详细说明（可选）
```

类型：
- `feat:` 新功能
- `fix:` 修 bug
- `build:` 构建/版本相关
- `docs:` 文档
- `test:` 测试
- `refactor:` 重构

### 5.2 提交节奏

**每个功能完成 = 一次提交 + 版本号 +2**。不要把多个不相关的改动混在一个提交里。

### 5.3 不要提交的东西

- `build/` 目录（已在 .gitignore）
- `userdata/` 目录（用户数据）
- `installer/out/`（构建产物）
- `*.log` 日志文件

### 5.4 合并冲突

拉取上游后如果有冲突：
1. `git checkout` 冲突文件（保留我们的版本）
2. 手动合并
3. 跑测试确认无回归
4. 提交

特别注意：`.flutter-plugins-dependencies` 和 `pubspec.lock` 是生成文件，有冲突直接删掉重新 `flutter pub get` 生成。

---

## 6. 代码规范

### 6.1 语言

- **Dart 代码**：注释用中文，变量名用英文
- **C++ 代码**：注释用中文
- **JS 插件代码**：注释用中文
- **文档**：中文为主

### 6.2 文件编码

全程 UTF-8 无 BOM。C++ 文件在 CMakeLists.txt 里已配 `/utf-8`。

### 6.3 命名约定

| 类型 | 约定 | 例子 |
|:---|:---|:---|
| 文件名 | snake_case | `plugin_card_body.dart` |
| 类名 | PascalCase | `PluginRuntime` |
| 变量/函数 | camelCase | `pluginId` |
| 常量 | kCamelCase | `kMarketBaseUrl` |
| 私有成员 | _前缀 | `_handleCall` |

### 6.4 注释风格

```dart
/// 文档注释：说明这个类/方法做什么
/// 第二行继续
final String pluginId;

// 行内注释：解释为什么这样做
// 多行注释用多个 //
```

**不要加多余的注释**。代码本身应该能说明"做什么"，注释说明"为什么"。

### 6.5 import 顺序

```dart
// Dart 核心
import 'dart:async';
import 'dart:convert';

// Flutter
import 'package:flutter/material.dart';

// 第三方包
import 'package:http/http.dart' as http;

// 项目内
import '../core/logger.dart';
import 'manifest.dart';
```

### 6.6 错误处理

- 插件层：永远返回 `{ok, data}` 或 `{ok, error}`，不抛异常
- 宿主层：`try-catch` 兜底，记日志，不崩溃
- 日志级别：`Log.d` 调试、`Log.i` 信息、`Log.w` 警告、`Log.e` 错误

---

## 7. 架构要点

### 7.1 多窗口架构

```
主引擎（main engine）
  ├─ 桌面磁贴窗口（Z 底层，全屏透明，点击穿透）
  ├─ 设置面板窗口（共享主引擎 isolate）
  └─ 插件市场窗口（共享主引擎 isolate）

侧边栏引擎（sidebar engine）— 独立 Flutter 引擎
  └─ AI 侧边栏窗口（Z 顶层，置顶）
```

侧边栏用独立引擎是因为它必须浮在所有窗口上面，不能和主窗口共享 Z 序。

### 7.2 插件运行时

每个卡片 = 一个独立 QuickJS 实例（~200KB）。隔离性：一个插件崩了不影响别的卡片。

```
manifest.json → 解析 → 验证
index.js → 拼接 scripts + entry → 一个字符串
→ 创建 QuickJS 运行时 → 注入 prelude → 执行源码
→ lw.register({ mount }) → mount(ctx) → 渲染
```

### 7.3 渲染协议

插件不碰 Flutter，只返回 JSON 描述的节点树：

```js
ctx.render({
  t: 'col', gap: 6, children: [
    { t: 'text', v: 'Hello', size: 18 },
    { t: 'box', bg: '#ffffff15', child: { t: 'text', v: 'World' } }
  ]
});
```

宿主把 JSON 翻译成 Flutter Widget。18 种内置节点类型 + 插件可注册自定义类型。

### 7.4 数据持久化

三文件分离：

| 文件 | 内容 | 大小 |
|:---|:---|:---|
| `config.json` | 设置 + 卡片布局 + AI 配置 | 小，值得备份 |
| `plugindata/<id>.json` | 插件级键值存储 | 中 |
| `plugindata/<id>/<hash>.json` | 插件缓存（可淘汰） | 可能很大 |

写入用原子操作（写 .tmp → rename），防崩溃丢数据。

### 7.5 窗口穿透

主窗口覆盖整个虚拟屏幕，但通过 `SetWindowRgn` 裁剪成所有卡片的并集。卡片之外的像素返回 `HTTRANSPARENT`，点击穿透到桌面。

---

## 8. 插件开发

### 8.1 最小插件

```
userdata/plugins/hello/
  manifest.json
  index.js
```

**manifest.json**：

```json
{
  "id": "hello",
  "name": "Hello",
  "version": "1.0.0",
  "entry": "index.js",
  "sizes": ["2x2"]
}
```

**index.js**：

```js
lw.register({
  mount: function (ctx) {
    ctx.render({ t: 'text', v: 'Hello!', size: 18 });
  }
});
```

### 8.2 manifest 规则

- `id`：只允许 `[a-z0-9][a-z0-9\-_]{0,63}`，必须和目录名一致
- `sizes`：格式 `"列x行"`，如 `"2x2"`、`"3x3"`
- `settings`：自动生成到控制面板
- `scripts`：在 entry 之前加载的附加 JS 文件
- `api_version`：SDK API 版本要求
- `dependencies`：依赖的其他插件能力（`"provider:capability"` 格式）

### 8.3 插件可用的 API

| API | 说明 |
|:---|:---|
| `ctx.render(tree)` | 渲染 UI 树 |
| `ctx.interval(fn, ms)` | 重复定时器 |
| `ctx.timeout(fn, ms)` | 一次性定时器 |
| `ctx.clearTimer(id)` | 清除定时器 |
| `ctx.on(fn)` | 注册事件处理器 |
| `ctx.onCleanup(fn)` | 注册卸载清理函数 |
| `ctx.storage.get/set` | 插件级键值存储 |
| `ctx.storage.getLocal/setLocal` | 卡片级键值存储 |
| `ctx.storage.cacheGet/cacheSet` | 可淘汰缓存 |
| `ctx.http.getJSON(url, opts)` | HTTP GET（仅 http/https） |
| `ctx.media.state/play/pause/...` | 系统媒体控制（SMTC） |
| `ctx.requestSize(size)` | 请求调整卡片尺寸 |
| `ctx.openSettings()` | 打开该卡片的设置 |
| `ctx.toast(msg)` | 显示提示（目前只落日志） |
| `ctx.openExternal(url)` | 打开外部链接（仅 http/https） |
| `ctx.pickFile(opts)` | 系统文件选择对话框 |
| `ctx.settings` | 当前设置 |
| `ctx.size` / `ctx.grid` | 像素尺寸 / 格数 |
| `ctx.theme` | 主题/壁纸色 |

### 8.4 插件 SDK

在 `lw.register()` 里加 `onLoad` 函数即可使用 SDK：

```js
lw.register({
  onLoad: function (api) {
    // api.sdk.node.register(type, handler)  — 注册新节点类型
    // api.sdk.capability.register(name, methods) — 注册新 host API
    // api.sdk.widget.register(template) — 注册 widget 模板
    // api.sdk.lifecycle.on(event, handler) — 钩入生命周期
    // api.appVersion — Vectra 版本号
    // api.pluginDir — 插件目录路径
  },
  mount: function (ctx) { /* ... */ }
});
```

生命周期事件：`appReady`、`cardAdded`、`cardRemoved`、`cardResized`、`wallpaperChanged`、`themeChanged`、`settingsChanged`。

### 8.5 内置插件

5 个内置插件在 `assets/plugins/` 下：

| 插件 | 展示的能力 |
|:---|:---|
| clock | 定时器、mono 等宽数字、按 grid 调整布局 |
| calendar | 多文件（scripts）、grid 节点、key 动画 |
| todo | input 提交、setLocal 存数据、列表增删 |
| weather | HTTP 请求 + 错误处理 + cacheSet + flip 翻面 |
| lyrics | ctx.media 全套、image 封面、slider、gradientMask |

**launcher（快捷启动）不是内置插件**：源码在仓库 `plugins/launcher/`，走
Unisphere 市场分发（zip 内套一层 `launcher/` 目录，含 manifest.json + index.js，
manifest 的 id 必须与目录名一致）。它展示 SDK onLoad + widget.register +
flip 编辑面（重命名/重排/删除）+ pickFile + launch。

### 8.6 内置插件注册

新内置插件需要改两个地方：

1. `lib/plugin/registry.dart`：`builtinIds` 列表加 ID
2. `pubspec.yaml`：assets 列表加 `- assets/plugins/xxx/`

---

## 9. Native Bridge（C++ 集成）

### 9.1 通道

唯一的 MethodChannel：`vectra/native`。

Dart → C++：`NativeBridge.xxx()` 方法
C++ → Dart：`setMethodCallHandler` 回调

### 9.2 新增 Native 方法的步骤

1. `lib/native/native_bridge.dart`：加 `static Future<T> xxx()` 方法
2. `windows/runner/flutter_window.cpp`：在 `HandleMethodCall` 里加 `if (call.method_name() == "xxx")`
3. `windows/runner/CMakeLists.txt`：如果用了新的 Win32 API，加 `target_link_libraries` 链接对应的 `.lib`
4. 重启应用测试

### 9.3 常用 Win32 API 链接

| API | 库 |
|:---|:---|
| SetWindowRgn, SetWindowPos | `user32.lib`（默认链接） |
| DwmEnableBlurBehindWindow | `dwmapi.lib` |
| ShellExecute | `shell32.lib` |
| CoCreateInstance (IFileOpenDialog) | `ole32.lib` |
| GetOpenFileNameW | `comdlg32.lib` |

---

## 10. 市场服务器

### 10.1 地址

- 生产环境：`https://unisphere.macrostar.top`
- 可配置：设置里改 `marketBaseUrl`
- 内置默认：`lib/core/marketplace.dart` 里的 `kMarketBaseUrl`

### 10.2 API 协议

客户端用 v1 简版协议（`/api/v1/*`）：

| 端点 | 用途 |
|:---|:---|
| `GET /api/v1/catalog` | 插件目录 |
| `GET /api/v1/plugins/{id}` | 插件详情（含 README） |
| `GET {downloadUrl}` | 下载 zip 包 |

真图标用完整版端点：`GET /api/vectra/plugins/{id}/resources/icon`

### 10.3 下载地址归一化

服务器可能返回 `http://host:443`（协议和端口矛盾）。客户端用 `resolveDownloadUrl()` 自动修正：同主机一律改用 base 的协议和端口。

---

## 11. 错误上报

### 11.1 Sentry（Better Stack）

- DSN 写死在 `lib/core/sentry.dart`
- 100% 采样
- `--no-sentry` 关闭
- `--test-sentry` 验证上报链路

### 11.2 覆盖范围

- `FlutterError.onError` — Flutter 框架错误
- `Dispatcher.instance.onError` — Dart 未捕获异常
- `runZonedGuarded` — 异步异常
- `Log.e` 转发 — 插件错误、网络错误、数据损坏等

---

## 12. 性能注意事项

- **每卡一个 QuickJS 实例**（~200KB），10 张卡片 ≈ 2MB
- **800ms 执行预算**：单次 evaluate 超过 800ms 会被标记为失控，停止调度
- **模糊图共享缩略图**：壁纸模糊用 0.4 倍缩略图，避免每帧回读全图
- **亮度量化**：壁纸亮度变化 < 0.01 时不重建模糊图
- **RepaintBoundary**：每张卡片独立重绘，拖一张不触发其他卡片重绘

---

## 13. 常见踩坑

| 坑 | 说明 |
|:---|:---|
| `state.json` vs `config.json` | schema 3 后主引擎写 `config.json`，侧边栏如果还读 `state.json` 就会脱节 |
| `\0` 在 C++ wstring 里 | `std::wstring += L'\0'` 会在 `\0` 处截断，必须用 `push_back` |
| PowerShell 中文乱码 | 终端代码页问题，文件本身是 UTF-8 |
| `flutter build` 不更新 assets | CMake 缓存问题，删 `build\windows` 后重跑 |
| 插件卸载后卡片残留 | 先删卡片再删目录，否则 config.json 里还有引用 |
| 多显示器启动错位 | 卡片用 monitorId + relX/relY 锚定，不是绝对坐标 |
| `http://` 配 `:443` | 服务器配错协议，客户端用 `resolveDownloadUrl` 兜住 |

---

## 14. 工作流程总结

```
1. 拉代码：git pull
2. 确认版本号：pubspec.yaml 里的 version
3. 写代码 + 写测试
4. 跑测试：flutter test --no-pub
5. 跑分析：flutter analyze --no-pub
6. 改版本号：+2
7. git add -A && git commit
8. 构建：tool\build_release.bat
9. 产物在 installer\out\，不要删历史版本
```

**每次功能完成 = 版本号 +2 → git 提交 → build_release.bat → 报产物路径**。
