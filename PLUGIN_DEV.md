# Vectra 插件开发

一个插件就是一个目录、两个文件：`manifest.json` 说明它是什么，`index.js` 决定它长什么样。
没有构建步骤、没有依赖安装、没有打包——写完把目录丢进 `userdata\plugins\`，重新扫描一下就能用。

```
userdata\plugins\
  my-widget\
    manifest.json
    index.js
```

---

## 目录

- [五分钟做一个能跑的插件](#五分钟做一个能跑的插件)
- [插件是怎么跑起来的](#插件是怎么跑起来的)
- [manifest.json](#manifestjson)
- [生命周期](#生命周期)
- [界面：节点树](#界面节点树)
- [节点类型速查](#节点类型速查)
- [交互与事件](#交互与事件)
- [定时器](#定时器)
- [存储](#存储)
- [网络](#网络)
- [媒体控制](#媒体控制)
- [卡片操作](#卡片操作)
- [动画](#动画)
- [调试](#调试)
- [约束与注意事项](#约束与注意事项)
- [拿内置插件当范本](#拿内置插件当范本)
- [插件 SDK：扩展宿主程序](#插件-sdk扩展宿主程序)

---

## 五分钟做一个能跑的插件

新建 `userdata\plugins\hello\`，放两个文件。

**manifest.json**

```json
{
  "id": "hello",
  "name": "打招呼",
  "version": "1.0.0",
  "entry": "index.js",
  "sizes": ["2x2", "3x2"],
  "defaultSize": "2x2",
  "settings": [
    { "key": "who", "type": "text", "label": "跟谁打招呼", "default": "世界" }
  ]
}
```

**index.js**

```js
lw.register({
  mount: function (ctx) {
    var count = 0;

    // 事件处理器要先登记，拿到 id 才能挂到节点上
    var onTap = ctx.on(function () {
      count++;
      draw();
    });

    function draw() {
      ctx.render({
        t: 'col', main: 'center', cross: 'center', gap: 8,
        children: [
          { t: 'text', v: '你好，' + ctx.settings.who, size: 18, weight: 600 },
          { t: 'tap', id: onTap, child: {
              t: 'box', pad: [6, 14], radius: 8, bg: '#FFFFFF14',
              child: { t: 'text', v: '点了 ' + count + ' 次', size: 12 }
          } }
        ]
      });
    }

    draw();
  },

  // 面板里改完设置会调到这里；ctx.settings 已经是新值了
  onSettingsChange: function (settings, ctx) {
    // 这个插件的 draw 直接读 ctx.settings，重画一次就行
    // 复杂插件通常在这里重新拉数据
  }
});
```

托盘右键 →「重新扫描插件」，然后在控制面板的组件库里就能看到「打招呼」，添加到桌面即可。

改完代码想看效果，同样是「重新扫描插件」+ 重新添加卡片（或者重启程序）。

---

## 插件是怎么跑起来的

每张卡片一个独立的 **QuickJS** 运行时（约 200KB）。插件之间互不影响——一个插件把自己的全局变量搞坏，
不会波及别的卡片。

QuickJS 是干净的 ES2020 引擎，**没有** DOM、`window`、`document`、`fetch`、`XMLHttpRequest`、
`localStorage`，也没有文件系统。所有外部能力都得通过 `ctx` 走宿主：

```
你的 index.js  ──ctx.http.getJSON()──►  Vectra 宿主  ──►  真正发请求
               ◄──────Promise─────────
```

界面同理：插件不碰 Flutter，只用 `ctx.render()` 交一棵 JSON 描述的树，宿主翻译成真正的界面。

**能用的标准库**：`JSON`、`Math`、`Date`（已修正为本地时区）、`String`/`Array`/`Object`/`Map`/`Set`、
`Promise`、`async/await`、正则——ES2020 该有的都有。

---

## manifest.json

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `id` | string | ✅ | 唯一标识。只允许小写字母、数字、`-`、`_`，1~64 字符。**必须和目录名一致** |
| `name` | string | ✅ | 显示名称 |
| `version` | string | ✅ | 版本号，形如 `"1.0.0"` |
| `entry` | string | ✅ | 入口文件，通常是 `"index.js"` |
| `description` | string | | 一句话描述，显示在组件库里 |
| `author` | string | | 作者 |
| `icon` | string | | 组件库里的图标字符，比如 `"☀"`。默认 `"▢"` |
| `sizes` | string[] | | 支持的尺寸，如 `["2x2","3x2","4x3"]`。默认 `["2x2"]` |
| `defaultSize` | string | | 默认尺寸，**必须在 `sizes` 里** |
| `singleton` | boolean | | 为 `true` 时全桌面只允许一个实例 |
| `settings` | object[] | | 设置项，见下 |
| `scripts` | string[] | | 在 `entry` 之前按顺序加载的附加脚本（相对插件目录），用来拆分代码 |
| `api_version` | string | | 要求的 SDK API 版本，默认 `"1.0"`。不匹配时警告但不阻止加载 |
| `dependencies` | string[] | | 依赖的其他插件注册的能力（`"provider:capability"` 格式） |
| `headless` | boolean | | 是否支持无 UI 后台运行（用于能力提供者插件），默认 `false` |

尺寸写成 `"列x行"`，一格的实际像素由用户在设置里的网格大小决定。

### 设置项

`settings` 里的每一项都会在控制面板里自动生成一个控件，用户改完通过 `ctx.settings` 读到。

```json
"settings": [
  { "key": "city",     "type": "text",    "label": "城市", "desc": "留空按 IP 自动定位", "default": "" },
  { "key": "hour24",   "type": "boolean", "label": "24 小时制", "default": true },
  { "key": "refresh",  "type": "number",  "label": "刷新间隔（分钟）", "min": 5, "max": 180, "step": 5, "default": 30 },
  { "key": "unit",     "type": "select",  "label": "单位", "default": "c",
    "options": [ { "value": "c", "label": "摄氏度" }, { "value": "f", "label": "华氏度" } ] }
]
```

| `type` | 渲染成 | 额外字段 |
|--------|--------|----------|
| `text`（或不写） | 单行输入框 | `placeholder` |
| `boolean` | 开关 | |
| `number` | 滑块 + 数值 | `min`（默认 0）、`max`（默认 100）、`step`（默认 1） |
| `select` | 下拉框 | `options: [{ value, label }]` |

公共字段：`key`（必填）、`label`（标题）、`desc`（副标题说明）、`default`（默认值）。

> `number` 存下来的值会按 `step` 对齐；`step` 是整数时存成整数，是小数时按小数位数保留。

---

## 生命周期

```js
lw.register({
  mount: function (ctx) { },                        // 必需
  onSettingsChange: function (settings, ctx) { },   // 可选
  onResize: function (w, h, ctx) { },               // 可选
  unmount: function (ctx) { }                       // 可选
});
```

| 钩子 | 什么时候调 |
|------|-----------|
| `mount(ctx)` | 卡片创建时调一次。在这里登记事件、起定时器、画第一帧 |
| `onSettingsChange(settings, ctx)` | 用户在面板里改了这张卡的设置。`ctx.settings` 已同步为新值 |
| `onResize(w, h, ctx)` | 卡片尺寸变化。`ctx.size`、`ctx.grid` 已同步为新值 |
| `unmount(ctx)` | 卡片被删除或程序退出前 |

**注意**：改设置和改尺寸都**不会**重新 `mount`，同一个运行时会一直用下去。所以别把"只该做一次的事"
写在 `draw()` 里，也别指望改设置能重置你的内部状态——需要重置就自己在 `onSettingsChange` 里做。

### ctx 上的只读信息

| 属性 | 说明 |
|------|------|
| `ctx.id` | 插件 id（manifest 里的那个） |
| `ctx.instanceId` | 这张卡片的唯一 id。同一插件的多张卡片各不相同 |
| `ctx.manifest` | 完整的 manifest 对象 |
| `ctx.settings` | 当前设置，已用 manifest 的 `default` 补齐 |
| `ctx.size` | `{ w, h }`，卡片当前的逻辑像素尺寸 |
| `ctx.grid` | `{ cols, rows }`，卡片当前占几格 |

### 收尾

```js
var timer = ctx.interval(tick, 1000);
ctx.onCleanup(function () { ctx.clearTimer(timer); });
```

`ctx.onCleanup(fn)` 登记的函数在卡片卸载时执行，`unmount` 钩子之后、清理定时器之前。
定时器其实宿主会统一回收，但**别的东西不会**——比如你想在卸载前存一次状态，就得靠它。

---

## 界面：节点树

`ctx.render(tree)` 接受一个普通的 JS 对象，每个节点用 `t` 字段表示类型：

```js
ctx.render({
  t: 'col', gap: 6,
  children: [
    { t: 'text', v: '标题', size: 16, weight: 600 },
    { t: 'row', gap: 4, cross: 'center', children: [
      { t: 'icon', v: 'sun', size: 14 },
      { t: 'text', v: '26°', size: 22 }
    ] }
  ]
});
```

调用 `ctx.render()` 就是"把整棵树换成这个"——没有增量更新，也不需要你操心 diff。
时钟插件每秒 render 一次也完全没问题。

**颜色**写成 `"#RGB"`、`"#RRGGBB"`、`"#RRGGBBAA"` 都行。不写颜色的话，文字会自动跟随卡片前景色——
壁纸亮的时候是深色字，壁纸暗的时候是浅色字。**能不写就别写死颜色**，否则浅色壁纸上你的白字会看不见。

---

## 节点类型速查

### 布局

**`col` / `row`** —— 竖排 / 横排

| 字段 | 说明 |
|------|------|
| `children` | 子节点数组 |
| `gap` | 子节点间距 |
| `cross` | 交叉轴对齐：`start`（默认）/ `center` / `end` / `stretch` |
| `main` | 主轴对齐：`start`（默认）/ `center` / `end` / `between` / `around` |

> `main` 只要不是 `start`，容器就会撑满主轴。这意味着它**不能**直接放进 `scroll` 里（无限高的容器里谈居中没有意义）。

**`box`** —— 背景、圆角、内边距、固定尺寸

| 字段 | 说明 |
|------|------|
| `w` / `h` | 固定宽高 |
| `pad` | 内边距。`8` 四边相同；`[上下, 左右]`；`[上, 右, 下, 左]` |
| `bg` | 背景色 |
| `radius` | 圆角半径 |
| `border` | 1px 边框颜色 |
| `center` | `true` 时子节点居中 |
| `child` | 单个子节点 |
| `gradientMask` | `true` 时上下边缘渐隐（配合滚动内容用） |
| `fade` | 渐隐高度比例，0.01~0.45，默认 0.15 |

**`grid`** —— 固定列数网格（日历用的就是它）

| 字段 | 说明 |
|------|------|
| `cols` | 列数，1~12，默认 7 |
| `gap` | 间距，默认 4 |
| `fill` | `true` 时各行均分可用高度 |
| `children` | 按行优先铺进格子 |

**`stack`** —— 层叠，`children` 从后往前画
**`scroll`** —— 可滚动，包一个 `child`
**`flex`** —— 占据剩余空间，`f` 是权重（默认 1），包一个 `child`
**`spacer`** —— 弹性空白
**`gap`** —— 固定空白，`v` 是尺寸（默认 8）

### 内容

**`text`**

| 字段 | 说明 |
|------|------|
| `v` | 文字内容 |
| `size` | 字号，默认 13 |
| `weight` | 字重 100~900，默认 400 |
| `color` | 颜色。不写则跟随卡片前景色 |
| `opacity` | 不透明度 0~1 |
| `align` | `start` / `center` / `end` |
| `maxLines` | 最多几行，超出显示省略号 |
| `lh` | 行高倍数 |
| `mono` | `true` 时数字等宽——**秒数、倒计时一定要开**，否则数字宽度不一会左右抖 |
| `strike` | `true` 时加删除线 |

**`icon`** —— `v` 是图标名，`size`、`color` 可选

可用图标：`check` `check_circle` `circle` `close` `add` `refresh` `left` `right` `up` `down`
`sun` `cloud` `rain` `snow` `fog` `storm` `settings` `play` `pause` `prev` `next` `music`
（写错名字会显示成一个方框）

**`image`** —— 只接受 `key`，不接受图片字节

```js
{ t: 'image', key: artKey, w: 48, h: 48, radius: 6, fit: 'cover' }
```

`key` 从 `ctx.media.state()` 的 `artKey` 来。`fit` 可选 `cover`（默认）/ `contain` / `fill`。
图片还没解码好时会显示一个占位方块，解码完自动替换，不用你管。

**`divider`** —— 一条分隔线，`color` 可选
**`progress`** —— 只读进度条。`v` 是 0~1，`h` 是高度，`color` 可选

### 交互

**`tap`** —— 点击区域

```js
var onTap = ctx.on(function (payload) { /* ... */ });
{ t: 'tap', id: onTap, child: { /* 被点的内容 */ } }
```

**`input`** —— 输入框

| 字段 | 说明 |
|------|------|
| `id` | 控件标识，用来复用输入状态（不写默认 `"input"`） |
| `value` | 当前值 |
| `placeholder` | 占位提示 |
| `size` | 字号 |
| `submit` | 回车时回调的处理器 id，payload 是 `{ value }`，回调后输入框自动清空 |
| `live` | `true` 时允许插件在用户打字过程中覆盖内容 |

> 同一个输入框在多次 render 之间要保持 `id` 不变，否则光标和已输入内容会丢。

**`slider`** —— 可拖动的滑条

| 字段 | 说明 |
|------|------|
| `id` | 处理器 id，**松手时**回调，payload 是 `{ value }`（0~1） |
| `v` | 当前值 0~1 |
| `h` | 轨道高度，默认 4 |
| `color` / `bg` | 已填充 / 未填充颜色 |
| `enabled` | `false` 时不可拖 |

拖动过程中滑条用自己的本地值跟手，不会等你的回调——所以拖起来不会一顿一顿的。

---

## 交互与事件

事件处理器必须**先登记后使用**：

```js
var handlerId = ctx.on(function (payload) { ... });   // 返回 "h1" 这样的 id
```

然后把这个 id 放进节点的 `id` 字段。树里只放 id，函数留在 JS 这边。

**登记一次就够了**——别在每次 `draw()` 里重新 `ctx.on()`，那样每重画一次就多一个处理器，
虽然不会立刻出问题，但白白堆内存。正确做法是在 `mount` 里登记好，`draw()` 里只引用 id：

```js
lw.register({
  mount: function (ctx) {
    var onPrev = ctx.on(function () { month--; draw(); });   // ✅ 只登记一次
    var onNext = ctx.on(function () { month++; draw(); });

    function draw() {
      ctx.render({ t: 'row', children: [
        { t: 'tap', id: onPrev, child: { t: 'icon', v: 'left' } },
        { t: 'tap', id: onNext, child: { t: 'icon', v: 'right' } }
      ] });
    }
    draw();
  }
});
```

---

## 定时器

```js
var t1 = ctx.interval(fn, 1000);   // 重复
var t2 = ctx.timeout(fn, 500);     // 一次性
ctx.clearTimer(t1);
```

全局的 `setInterval` / `setTimeout` / `clearInterval` / `clearTimeout` 也能用，它们被换成了同一套实现。

定时器由宿主持有，卡片卸载时统一回收，不会泄漏到程序退出。

**别把间隔设得太密**。桌面组件是常驻的，1 秒一次已经是时钟这种"必须跳秒"的极限；
天气这类几十分钟一次足够。每次唤醒都是实打实的 CPU。

---

## 存储

三层，用途不同，别用混：

```js
await ctx.storage.set('key', value);       // 插件级：同一插件的所有卡片共享
await ctx.storage.get('key', 默认值);

await ctx.storage.setLocal('key', value);  // 卡片级：每张卡片各存各的
await ctx.storage.getLocal('key', 默认值);

await ctx.storage.cacheSet('key', value);  // 缓存：可能被宿主淘汰
await ctx.storage.cacheGet('key');
```

| | 用来存 | 例子 |
|---|--------|------|
| `get` / `set` | 整个插件共用的配置 | 登录 token、用户偏好 |
| `getLocal` / `setLocal` | **用户真正的数据** | 待办清单、便签内容 |
| `cacheGet` / `cacheSet` | 丢了能重新拿的大块数据 | 歌词文本、接口响应 |

三条规矩：

1. **`set(key, null)` 是删除这个键**，不是存一个 `null`。
2. **缓存随时可能消失**，只放"丢了能重新算/重新抓"的东西。用户的数据一律用 `setLocal`。
3. **大块数据走缓存**。键值存储是整份读写的，往里塞几百 KB 会让每次存取都变贵；缓存只碰命中的那一条。

所有存储方法都返回 Promise，记得 `await`。

---

## 网络

```js
var res = await ctx.http.getJSON('https://api.example.com/data');
if (res.ok) {
  console_use(res.data);       // 解析好的 JSON
} else {
  console_use(res.error);      // 人话错误信息
}
```

| | |
|---|---|
| 方法 | 只有 GET |
| 返回 | `{ ok: true, data }` 或 `{ ok: false, error }`，**永远不抛异常** |
| 超时 | 15 秒 |
| 协议 | 只允许 `http` / `https` |

可以带少量请求头：

```js
await ctx.http.getJSON(url, { headers: { 'Referer': 'https://example.com' } });
```

只有 `User-Agent`、`Referer`、`Accept`、`Accept-Language` 会被采纳，其余一律丢弃（插件伪造不了 Cookie）。

**一定要处理 `ok: false`**。接口挂了、限流了、断网了，在用户那边都表现为"组件不显示数据"——
你至少要画一句"加载失败"，最好再给个重试按钮。天气插件就是这么做的。

> 请求会被记进日志（URL 只记主机名和路径，query 里的密钥不会落盘），出问题时可以在
> 「设置 → 其他 → 日志」里查到耗时和状态码。

---

## 媒体控制

读写 Windows 系统媒体控件（SMTC），也就是按音量键弹出来的那个"正在播放"浮层背后的数据。

```js
var res = await ctx.media.state();
if (res.ok && res.data.available) {
  var m = res.data;
  // m.title, m.artist, m.album
  // m.position（毫秒）, m.duration, m.isPlaying
  // m.artKey —— 直接塞给 { t:'image', key: m.artKey }
}
```

控制命令：

```js
await ctx.media.play();
await ctx.media.pause();
await ctx.media.toggle();
await ctx.media.next();
await ctx.media.prev();
await ctx.media.seek(90000);   // 毫秒
```

命令返回值只表示"已经发出去了"，不代表播放器真的照做——有的播放器不支持 seek。

---

## 卡片操作

```js
ctx.requestSize('3x2');    // 请求换尺寸，必须是 manifest.sizes 里有的
ctx.openSettings();        // 打开这张卡片的设置面板
ctx.toast('已保存');        // 提示（目前只写日志，UI 待做）
await ctx.openExternal('https://example.com');   // 用默认浏览器打开
```

---

## 动画

动画必须**显式声明**，宿主不会自作主张——时钟每秒重绘一次，要是每次都动画就一直在闪。

**内容切换淡入**：给根节点加 `key`，`key` 变化时整卡交叉淡入。

```js
ctx.render({ key: '2026-8', t: 'col', children: [ /* 日历内容 */ ] });
```

日历翻月把 `key` 设成 `"年-月"`，歌词切歌设成歌名——只在真正换内容时过渡。

**翻面**：`flip` 节点，`flipKey` 变化时 3D 翻转。`children[0]` 是正面，`children[1]` 是背面。

```js
{ t: 'flip', flipKey: face, children: [ 正面节点, 背面节点 ] }
```

> 用户在设置里关掉动画时，这两种都会自动降级为直接切换，不用你判断。

---

## 调试

**看日志**：设置 →「其他」→ 日志 →「打开日志目录」。插件的 HTTP 请求、报错、挂载耗时都在里面。

**报错会显示在卡片上**：插件抛异常、超时、或者 manifest 写错，卡片上会显示一句提示，
展开能看到具体原因。修好之后点「重试」就能重新加载，不用重启程序。

**改完代码怎么生效**：托盘右键 →「重新扫描插件」，然后删掉卡片重新添加。

**常见错误对照**：

| 现象 | 多半是 |
|------|--------|
| 卡片一片空白 | 没调 `ctx.render()`，或者树的根节点类型拼错了 |
| `插件没有调用 lw.register({ mount })` | 忘了 `lw.register`，或者 `mount` 不是函数 |
| `插件执行超时` | 有死循环，或者某次同步计算太重（超过 800ms） |
| 组件库里找不到 | manifest 的 `id` 和目录名不一致，或者 JSON 语法错误 |
| 点击没反应 | `ctx.on()` 拿到的 id 没放进节点的 `id` 字段 |
| 文字在浅色壁纸上看不见 | 写死了白色。删掉 `color` 让它自动跟随 |

---

## 约束与注意事项

**没有的东西**：DOM、`window`、`document`、`fetch`、`XMLHttpRequest`、`localStorage`、
文件系统、`require`/`import`（要拆文件用 manifest 的 `scripts`）。

**单次执行不能超过 800ms**。插件跑在 UI 线程上，一个死循环会把整个桌面卡住。
宿主会在超时后停止调度这个插件并显示错误，但**挡不住第一次**——写循环时自己留神。

**`console.log` 不可用**。要输出信息用 `ctx.toast()`（进日志），或者干脆画到卡片上。

**别在 render 里做重活**。`render` 可能每秒调用一次，把网络请求、大量计算放进去会拖垮整卡。

**卡片可能很小**。用户可以把 `2x2` 的卡片配成很小的网格，文字记得设 `maxLines`，
布局尽量用 `flex` / `spacer` 而不是写死像素。

---

## 拿内置插件当范本

五个内置插件的完整源码在 `assets\plugins\` 下，都是用这套 API 写的，可以直接抄：

| 插件 | 值得看的地方 |
|------|------------|
| `clock` | 最简单的例子。定时器、`mono` 等宽数字、按 `ctx.grid.cols` 调整字号 |
| `calendar` | `grid` 节点的用法、翻月的 `key` 动画、事件处理器只登记一次 |
| `todo` | `input` 提交、`setLocal` 存用户数据、列表增删 |
| `weather` | HTTP 请求 + 错误处理 + 重试按钮、`cacheSet` 缓存、`flip` 翻面 |
| `lyrics` | `ctx.media` 全套、`image` 封面、`slider` 拖进度、`gradientMask` 边缘渐隐 |

---

---

## 插件 SDK：扩展宿主程序

除了用 `ctx.render()` 画卡片，插件还可以通过 SDK 扩展 Vectra 本身。在 `lw.register()` 里加一个 `onLoad` 函数即可：

```js
lw.register({
  onLoad: function (api) {
    // api.sdk 提供扩展点
    // api.appVersion — Vectra 版本号
    // api.pluginDir  — 插件目录路径
  },

  mount: function (ctx) {
    ctx.render({ t: 'text', v: '我的插件', size: 14 });
  }
});
```

### 注册新的渲染节点类型

让 `ctx.render()` 能画更多东西：

```js
onLoad: function (api) {
  api.sdk.node.register('chart', {
    // v1 阶段：注册即生效，宿主会显示占位符
    // 后续版本会调用 render 函数获取真实 widget
  });
}
```

然后其他插件就能在 UI 树里用了：

```js
ctx.render({ t: 'chart', data: [10, 25, 18], type: 'line' });
```

> 同名节点类型会被拒绝（后者不覆盖前者），日志里会记录冲突。

### 注册新的 host API 能力

让 `ctx` 上出现全新的 API 对象：

```js
onLoad: function (api) {
  api.sdk.capability.register('websocket', {
    connect: function (args) { /* ... */ },
    send: function (args) { /* ... */ },
    // 方法表可以是部分的——只注册需要的方法
  });
}
```

其他插件声明依赖后就能用（manifest 里写 `"dependencies": ["my-plugin:websocket"]`）。

### 钩入生命周期

在程序的各个阶段注入行为：

```js
onLoad: function (api) {
  api.sdk.lifecycle.on('appReady', function (data) {
    // 程序启动完毕
  });

  api.sdk.lifecycle.on('cardAdded', function (data) {
    // data = { id, pluginId, size }
  });

  api.sdk.lifecycle.on('wallpaperChanged', function (data) {
    // data = { path, brightness }
  });
}
```

可用的生命周期事件：

| 事件 | 触发时机 |
|------|---------|
| `appReady` | 程序启动完毕，所有卡片首次渲染完成 |
| `cardAdded` | 一张卡片被添加到桌面 |
| `cardRemoved` | 一张卡片从桌面移除 |
| `cardResized` | 一张卡片被调整大小 |
| `wallpaperChanged` | 壁纸切换 |
| `themeChanged` | 系统主题切换 |
| `settingsChanged` | 全局设置变更 |

### 注册 widget 模板

在组件库中添加一键添加的卡片模板：

```js
onLoad: function (api) {
  api.sdk.widget.register({
    id: 'stock-ticker',
    name: '股票行情',
    description: '实时股价显示',
    icon: '📈',
    sizes: ['2x2', '3x2'],
    defaultSize: '3x2',
    settings: [
      { key: 'symbol', type: 'text', label: '股票代码', default: 'AAPL' }
    ]
  });
}
```

### 清理

插件卸载时，所有注册的节点、能力、生命周期监听会自动清理。不需要手动处理。

---

有问题或者发现文档和实际对不上，欢迎提 issue：
[github.com/MacroSTAR-Org/Vectra](https://github.com/MacroSTAR-Org/Vectra)
