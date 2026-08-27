<div align="center">

  <img src="https://img.macrostar.top/Vectra02.png" alt="vectra" width="75%">

# 山止组件 · Vectra

**你的桌面，你自己来。**

Windows 平台独占：构建你的新一代 Windows 桌面小组件

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-≥3.12-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![Windows](https://img.shields.io/badge/Platform-Windows-0078D4?logo=windows&logoColor=white)](https://flutter.dev)
[![Version](https://img.shields.io/badge/Version-0.1.2-blue)](https://github.com/MacroSTAR-Org/Vectra/releases)
[![GitHub Stars](https://img.shields.io/github/stars/MacroSTAR-Org/Vectra?style=flat&logo=github)](https://github.com/MacroSTAR-Org/Vectra)
[![GitHub Issues](https://img.shields.io/github/issues/MacroSTAR-Org/Vectra?style=flat&logo=github)](https://github.com/MacroSTAR-Org/Vectra/issues)
[![License](https://img.shields.io/badge/License-MIT-green)](#许可与致谢)

---

[**下载最新版**](https://github.com/MacroSTAR-Org/Vectra/releases/latest) ·
[**插件开发文档**](PLUGIN_DEV.md) ·
[**问题反馈**](https://macrostar.feishu.cn/share/base/form/shrcnOjASFuDxU7CROCyuDbB4Ed) ·
[**赞助作者**](https://www.ifdian.net/a/ms_xh)

---

</div>

>[!Caution]
>
>项目可能会经历一些重构，包括Unisphere在线服务不可用，对您造成的不便敬请谅解！
>
>我们更新了新的 Sentry 提供方，自 2026/8/27 起，由 Functional Software, Inc. 提供 Sentry 的服务支持。原先由 Better Stack, Inc. 提供的服务已不可用，尽管数据已经上传。但请放心，我们已对所有数据进行脱敏处理，并完整删除。
>
>您收到这条通知是因为您使用了我们的服务，我们有权及义务告知您此项事件。

## 特性一览

<div align="center">

| | | |
|:---:|:---:|:---:|
| **真·桌面层** | **点得到，点得穿** | **像壁纸一样的质感** |
| 磁贴常驻 Z 序最底，永远在其它窗口下面 | 卡片轮廓外的像素还给桌面，双击/右键照常 | 云母 / 玻璃 / 纯色三档，底子取自实时壁纸 |
| **拖起来跟手** | **多显示器** | **JS 插件** |
| 对齐辅助线、吸附、网格全部本地算 | 每张卡记住"哪块屏的哪个位置" | 一个 manifest.json + 一个 index.js 就是一个组件 |
| **AI 侧边栏** | **插件市场** | **开源** |
| `Ctrl + Alt + Space` 唤出，能读文件、查系统、调音量 | 安装/更新/卸载第三方插件，图标与 README 渲染 | Flutter + Win32 + QuickJS，欢迎 PR |

</div>

## 快速上手

### 下载

从 [**GitHub Releases**](https://github.com/MacroSTAR-Org/Vectra/releases/latest) 下载
`Vectra-<版本>-便携版.exe`，运行后就地释放到同目录的 `Vectra\` 文件夹。

不需要管理员权限，不留卸载项、不写注册表（"开机自启"除外）。

### 数据结构

```
userdata/
  config.json        设置与卡片布局
  plugindata/        各插件自己的数据，一插件一文件
  plugins/           第三方插件放这里
  logs/              日志，按天分文件，留 7 天
```

整个 `userdata/` 文件夹拷走就是搬家。

### 托盘

- **左键**：打开设置
- **右键**：快捷菜单（退出、开机自启等）

## 自己构建

需要 **Flutter 3.x**（Dart SDK ≥ 3.12）与 **Visual Studio 2022** 的桌面 C++ 工作负载。

```powershell
flutter pub get
flutter build windows --release --no-pub
```

产物 `build/windows/x64/runner/Release/`，整个文件夹就是发布版。

打便携包：

```powershell
tool\build_release.bat        # -> installer\out\Vectra-<版本>-便携版.exe
```

跑测试：

```powershell
flutter test --no-pub
node test/js/lrc_verify.js    # 歌词解析的纯函数验证
```

## 写一个插件

> 完整的开发文档在 **[PLUGIN_DEV.md](PLUGIN_DEV.md)**：API 参考、节点类型速查、
> 从零写一个插件的教程、常见错误对照表。

## 项目结构

```
lib/
  main.dart          启动、播种默认卡片、拉起磁贴窗口
  sidebar_main.dart  AI 侧边栏的入口（第二个 Flutter 引擎）
  core/              纯逻辑：网格、吸附、命中、显示器换算、日志、启动闸门
  model/             卡片与设置的持久化模型
  plugin/            QuickJS 运行时、插件宿主、清单解析、节点树渲染
  store/             config.json 与 plugindata 的读写、备份导入导出
  ui/                桌面层、卡片、控制面板、AI 侧边栏、壁纸模糊
  native/            与 C++ 的方法通道
windows/runner/      Win32：窗口层级、区域裁剪、抓屏、SMTC、启动幕布
```

## 贡献者

<!-- ALL-CONTRIBUTORS-LIST:START -->
![Contributors](https://contrib.rocks/image?repo=MacroSTAR-Org/Vectra)
<!-- ALL-CONTRIBUTORS-LIST:END -->

## 技术栈

| 层 | 技术 |
|:---|:---|
| UI 框架 | [Flutter](https://flutter.dev) + [Dart](https://dart.dev) |
| 桌面集成 | Win32 API（窗口层级、区域裁剪、SMTC 媒体控制） |
| 插件引擎 | [QuickJS](https://bellard.org/quickjs/)（沙箱化 JS 运行时） |
| 壁纸抓取 | Windows Desktop Capture API（C++） |
| 错误上报 | [Sentry](https://sentry.io) / Functional Software, Inc. |
| AI 侧边栏 | 多引擎架构（可接入 OpenAI / Claude / 本地模型） |

## 许可与致谢

⨝ MacroSTAR Studio 出品。

天气数据来自小米天气API。

Functional Software, Inc. 提供 Sentry 遥测服务。

## 赞助

觉得好用的话：[为爱发电](https://www.ifdian.net/a/ms_xh)

<div align="center">
  © 2024-2026 宏维星智网络技术工作室 保留所有权利
</div>
