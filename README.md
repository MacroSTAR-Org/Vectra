<div align="center">

# Vectra

**把小组件放回桌面。**

一个 Windows 桌面磁贴程序：时钟、日历、待办、天气、歌词，安安静静地待在壁纸上，
盖在它们上面的窗口一挪开就在那儿。

Flutter · Win32 · QuickJS 插件 · MacroSTAR Studio

</div>

---

## 它是什么

Windows 把小组件收进了侧边栏，点一下才出来，关掉就没了。Vectra 反过来：
组件就画在桌面上，属于桌面的一部分。

- **真·桌面层**：磁贴窗口常驻 Z 序最底，永远压在其它窗口下面。你不会在打游戏时
  被它挡住，也不需要"显示桌面"才能看到它——桌面露出来的地方，它就在那儿。
- **点得到，也点得穿**：窗口被裁成卡片轮廓的并集，卡片之外的每一个像素都还给桌面。
  图标照双击，右键菜单照弹，就像它不存在。
- **像壁纸一样的质感**：云母 / 玻璃 / 纯色三档材质，底子取自实时抓取并模糊的壁纸，
  文字明暗跟着壁纸自动翻转，浅色壁纸上不会出现"白底白字"。
- **拖起来跟手**：全部磁贴在同一个窗口里，拖拽不跨进程；对齐辅助线、吸附、网格
  都在本地算，松手即存。
- **多显示器**：每张卡片记住自己"在哪块屏的哪个位置"。插拔显示器、改排列、改缩放，
  它都回到你放它的地方。
- **JS 插件**：一个 `manifest.json` 加一个 `index.js` 就是一个组件，跑在 QuickJS
  沙箱里，碰不到你的文件系统。
- **AI 侧边栏**：`Ctrl + Alt + Space` 唤出，能读文件、查系统、调音量、开程序、
  跑 PowerShell——需要你逐次确认。

## 上手

下载 `Vectra-<版本>-便携版.exe`，运行后就地释放到它自己旁边的 `Vectra\`，
不需要管理员权限，不留卸载项、不写注册表（"开机自启"那一项除外，它写
`HKCU\...\Run`）。所有数据都在程序旁边的 `userdata\`，整个文件夹拷走就是搬家：

```
userdata\
  config.json        设置与卡片布局
  plugindata\        各插件自己的数据，一插件一文件
  plugins\           第三方插件放这里
  logs\              日志，按天分文件，留 7 天
```

托盘图标：左键开设置，右键给菜单。

## 自己构建

需要 Flutter 3.x（Dart SDK ≥ 3.12）与 Visual Studio 2022 的桌面 C++ 工作负载。

```powershell
flutter pub get
flutter build windows --release --no-pub
```

产物 `build\windows\x64\runner\Release\`，整个文件夹就是发布版。

打便携包：

```powershell
tool\build_release.bat        # -> installer\out\Vectra-<版本>-便携版.exe
```

跑测试：

```powershell
flutter test --no-pub
node test\js\lrc_verify.js     # 歌词解析的纯函数验证
```

## 写一个插件

在 `userdata\plugins\` 下新建一个目录，放两个文件：

```
my-widget\
  manifest.json
  index.js
```

**manifest.json** —— 声明身份、可选尺寸和设置项，设置项会自动生成到控制面板里：

```json
{
  "id": "my-widget",
  "name": "我的组件",
  "version": "1.0.0",
  "entry": "index.js",
  "sizes": ["2x2", "3x2"],
  "defaultSize": "2x2",
  "settings": [
    { "key": "city", "type": "text", "label": "城市", "default": "北京" },
    { "key": "refreshMin", "type": "number", "label": "刷新间隔（分钟）",
      "min": 5, "max": 180, "step": 5, "default": 30 }
  ]
}
```

**index.js** —— 注册一个 `mount`，往 `ctx.render()` 里喂一棵节点树，框架负责画：

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

节点树认这些：`col` `row` `stack` `grid` `scroll` 管布局，`text` `image` `icon`
`divider` `progress` `slider` `input` `flip` 是内容，`box` 管背景圆角内边距，
`spacer` `gap` `flex` 管留白。交互用 `tap` 节点包一层，回调靠 `ctx.on(fn)` 领一个
id 挂上去：

```js
var retry = ctx.on(function () { load(); });
ctx.render({ t: 'tap', id: retry, child: { t: 'text', v: '重试' } });
```

`ctx` 上能用的全部能力（其余一概没有——没有 DOM、没有 `fetch`、没有文件系统）：

| 能力 | 说明 |
| --- | --- |
| `ctx.http.getJSON(url, opts)` | 只放行 http/https，URL 里的密钥在日志中会被脱敏 |
| `ctx.storage.get/set` | 插件自己的数据，一插件一文件 |
| `ctx.storage.cacheGet/cacheSet` | 带过期时间的缓存 |
| `ctx.media.state/play/pause/next/prev/seek` | 系统正在播放的曲目（SMTC） |
| `ctx.interval/timeout/clearTimer` | 卡片卸载时自动清理，不会泄漏 |
| `ctx.requestSize('3x2')` | 请求换一个尺寸 |
| `ctx.settings` / `ctx.grid` / `ctx.size` | 当前设置、格数、像素尺寸 |
| `ctx.openExternal(url)` / `ctx.toast(msg)` / `ctx.openSettings()` | |

内置的 `clock` / `calendar` / `todo` / `weather` / `lyrics` 就是用这套 API 写的，
在 `assets\plugins\` 下，可以直接抄。

## 里面是怎么搭的

```
lib\
  main.dart          启动、播种默认卡片、拉起磁贴窗口
  sidebar_main.dart  AI 侧边栏的入口（第二个 Flutter 引擎）
  core\              纯逻辑：网格、吸附、命中、显示器换算、日志、启动闸门
  model\             卡片与设置的持久化模型
  plugin\            QuickJS 运行时、插件宿主、清单解析、节点树渲染
  store\             config.json 与 plugindata 的读写、备份导入导出
  ui\                桌面层、卡片、控制面板、AI 侧边栏、壁纸模糊
  native\            与 C++ 的方法通道
windows\runner\      Win32：窗口层级、窗口区域裁剪、抓屏、SMTC、启动幕布
```

## 许可与致谢

MacroSTAR Studio 出品。天气数据来自 [Open-Meteo](https://open-meteo.com)

## 赞助

觉得好用的话：[为爱发电](https://www.ifdian.net/a/ms_xh)
