<div align="center">

# Vectra

**把小组件放回桌面。**

一个 Windows 桌面磁贴程序：时钟、日历、待办、天气、歌词，安安静静地待在壁纸上，
盖在它们上面的窗口一挪开就在那儿。

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
[**问题反馈**](https://github.com/MacroSTAR-Org/Vectra/issues) ·
[**赞助作者**](https://www.ifdian.net/a/ms_xh)

---

</div>

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

最短的一个插件只需要两个文件：

```
my-widget/
  manifest.json
  index.js
```

**manifest.json**：

```json
{
  "id": "my-widget",
  "name": "我的组件",
  "version": "1.0.0",
  "entry": "index.js",
  "sizes": ["2x2", "3x2"],
  "defaultSize": "2x2",
  "settings": [
    { "key": "city", "type": "text", "label": "城市", "default": "北京" }
  ]
}
```

**index.js**：

```js
lw.register({
  mount: function (ctx) {
    var state = { text: '加载中…' };

    function draw() {
      ctx.render({
        t: 'col', gap: 6, main: 'center', children: [
          { t: 'text', v: state.text, size: 18, weight: 600 },
          { t: 'text', v: ctx.settings.city, size: 13, opacity: 0.5 },
        ]
      });
    }

    function load() {
      ctx.http.getJSON('https://example.com/api?city=' + ctx.settings.city)
        .then(function (data) { state.text = data.summary; draw(); });
    }

    draw();
    load();
    var timer = ctx.interval(load, Math.max(5, ctx.settings.refreshMin) * 60000);
    ctx.onCleanup(function () { ctx.clearTimer(timer); });
  },

  onSettingsChange: function () { /* 面板里改完设置会调到这里 */ }
});
```

内置的 `clock` / `calendar` / `todo` / `weather` / `lyrics` 就是用这套 API 写的，
在 `assets/plugins/` 下，可以直接抄。

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
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/MacroSTAR-Org"><img src="https://github.com/MacroSTAR-Org.png?s=100" width="100px;" alt=""/><br /><sub><b>夏辉 Seren Xia</b></sub></a><br /><a href="https://github.com/MacroSTAR-Org/Vectra/commits?author=Seren-Xia" title="Code">💻</a> <a href="#design-Seren-Xia" title="Design">🎨</a> <a href="#ideas-Seren-Xia" title="Ideas">💡</a> <a href="#infra-Seren-Xia" title="Infrastructure">🚇</a></td>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/KiriharaReina"><img src="https://github.com/KiriharaReina.png?s=100" width="100px;" alt=""/><br /><sub><b>KiriharaReina</b></sub></a><br /><a href="https://github.com/MacroSTAR-Org/Vectra/commits?author=KiriharaReina" title="Code">💻</a> <a href="#design-KiriharaReina" title="Design">🎨</a></td>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/MichaelYoung"><img src="https://github.com/MichaelYoung.png?s=100" width="100px;" alt=""/><br /><sub><b>Michael Young</b></sub></a><br /><a href="https://github.com/MacroSTAR-Org/Vectra/commits?author=MichaelYoung" title="Code">💻</a></td>
    </tr>
  </tbody>
</table>
<!-- ALL-CONTRIBUTORS-LIST:END -->

## 技术栈

| 层 | 技术 |
|:---|:---|
| UI 框架 | [Flutter](https://flutter.dev) + [Dart](https://dart.dev) |
| 桌面集成 | Win32 API（窗口层级、区域裁剪、SMTC 媒体控制） |
| 插件引擎 | [QuickJS](https://bellard.org/quickjs/)（沙箱化 JS 运行时） |
| 壁纸抓取 | Windows Desktop Capture API（C++） |
| 错误上报 | [Sentry](https://sentry.io) / Better Stack |
| AI 侧边栏 | 多引擎架构（可接入 OpenAI / Claude / 本地模型） |

## 许可与致谢

MacroSTAR Studio 出品。

天气数据来自 [Open-Meteo](https://open-meteo.com)。

## 赞助

觉得好用的话：[为爱发电](https://www.ifdian.net/a/ms_xh)
