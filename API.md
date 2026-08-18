# 统曜 Unisphere · API 对接指南

面向要对接 Unisphere 的客户端 / 脚本 / AI。本文自包含：读完即可实现一个完整的插件市场客户端。

---

## 0. 一分钟速览

- **基地址**：`https://你的域名`（下称 `BASE`）。
- **两个产品分区**：Vectra 与 Lunar X 是**两个不同产品，插件不通用**。客户端只取自己那个分区。
  - Vectra 客户端 → 用 `BASE/api/vectra/*` 或 `BASE/api/v1/*`（默认 vectra）
  - Lunar X 客户端 → 用 `BASE/api/lunar-x/*` 或 `BASE/lunar-x/api/v1/*`
- **两套协议，按需选**：
  - **`/api/v1/*`（简版）**：Vectra 桌面端内置协议，字段少、直接给绝对下载地址。**最省事**。
  - **`/api/{product}/*`（完整版）**：列表/搜索/标签/分类/评分/图标/README… 适合做完整市场界面。
- **响应信封**：多数接口返回 `{ "ok": true, "data": ..., "meta": {...} }`；出错 `{ "ok": false, "error": "..." }`。
  **例外**（直接返回裸数据，无信封）：`/api/v1/*`、`*/manifest`、各资源二进制、`/release`（zip）。
- **CORS**：`/api/*` 允许跨源（`Access-Control-Allow-Origin: *`）。

---

## 1. 分区与命名空间

同一份目录，按产品隔离。三种取分区的方式，效果一致：

| 方式 | 例子 | 说明 |
|------|------|------|
| 路径前缀（推荐） | `GET BASE/api/vectra/plugins` | 自动注入分区，**跨区按 id 直取返回 404** |
| 查询参数 | `GET BASE/api/plugins?target=vectra` | 顶层端点加 `target` |
| 顶层（不分区） | `GET BASE/api/plugins` | 返回**全部**分区，仅网页端自用，客户端别用 |

`{product}` 取值：`vectra` 或 `lunar-x`。

> 隔离示例：`GET BASE/api/vectra/plugins/某个lunar-x插件` → `404`。

---

## 2. 方式一：`/api/v1/*` 简版协议（最省事）

Vectra 桌面端就用这套。三个端点搞定「浏览→详情→下载安装」。

### 2.1 目录

```
GET  BASE/api/v1/catalog
```
- 默认只返回 **Vectra** 分区。Lunar X 用 `GET BASE/lunar-x/api/v1/catalog`。
- **顶层直接是 `{ "plugins": [...] }`，不套 ok/data 信封。**

响应：
```json
{
  "plugins": [
    {
      "id": "clock-lite",
      "name": "轻时钟",
      "version": "1.0.0",
      "downloadUrl": "https://你的域名/api/vectra/plugins/clock-lite/release",
      "description": "极简数字时钟…",
      "author": "MacroSTAR",
      "icon": "▢",
      "sizes": ["2x2", "3x2"],
      "updatedAt": "2026-08-17T10:10:24.121Z"
    }
  ]
}
```
- `downloadUrl`：**绝对地址**，直接 GET 它即得安装包 zip。
- `icon`：字形字符（如 `☀`）；插件用文件图标时给占位 `▢`。
- `sizes`：网格尺寸，形如 `"2x2"`。

### 2.2 详情（含 README）

```
GET  BASE/api/v1/plugins/{id}
```
- 顶层直接是插件对象，比目录多一个 `readme`（Markdown，相对图片已改写为绝对地址）。
- 跨分区 → `404`。

```json
{
  "id": "clock-lite", "name": "轻时钟", "version": "1.0.0",
  "downloadUrl": "https://你的域名/api/vectra/plugins/clock-lite/release",
  "description": "…", "author": "MacroSTAR", "icon": "▢",
  "sizes": ["2x2","3x2"], "updatedAt": "…",
  "readme": "# 轻时钟\n\n…"
}
```

### 2.3 下载安装包

```
GET  {downloadUrl}          # 即 2.1/2.2 里给的绝对地址
```
- 返回 `Content-Type: application/zip`，文件名 `{id}-{version}.zip`。
- zip 内是**一个以插件 id 命名的目录**：
  ```
  clock-lite/
    manifest.json
    index.js
    icon.svg
    README.md
  ```
- 客户端解压该目录到插件目录（如 Vectra 的 `userdata/plugins/`）即完成安装。

### 2.4 安装流程（伪代码）

```
list   = GET /api/v1/catalog            # 展示 plugins[]
detail = GET /api/v1/plugins/{id}       # 点开看 readme
zip    = GET detail.downloadUrl         # 下载
// 校验：解压后 manifest.json 的 id 必须 == 请求的 id；带 .. 或绝对路径的包拒绝
install(zip)                            # 解压到插件目录
```

---

## 3. 方式二：`/api/{product}/*` 完整版

想做搜索/标签/分类/评分/分页的完整界面用这套。全部走 `{ok,data,meta}` 信封（资源二进制/manifest 除外）。
把下面路径里的 `{product}` 换成 `vectra` 或 `lunar-x`。

### 3.1 目录快照（客户端轮询用）

```
GET  BASE/api/{product}/catalog
```
```json
{ "ok": true, "data": {
    "generated_at": "…", "source_mode": "local",
    "plugins": [ { "id":"clock-lite","name":"轻时钟","version":"1.0.0",
      "description":"…","author":"MacroSTAR","target":"vectra",
      "tags":["widget","time"],"sizes":["2x2","3x2"],"defaultSize":"2x2",
      "rating":0,"rating_count":0,"downloads":0,"updated_at":"…",
      "icon":"/api/plugins/clock-lite/resources/icon",
      "manifest":"/api/plugins/clock-lite/manifest",
      "release":"/api/plugins/clock-lite/release" } ] },
  "meta": { "total": 1 } }
```
> 注意这里的 `icon/manifest/release` 是**相对路径**，拼 `BASE` 使用。

### 3.2 插件列表（分页/排序）

```
GET  BASE/api/{product}/plugins
```
| 参数 | 默认 | 说明 |
|------|------|------|
| `page` / `per_page` | 1 / 20 | 分页（推荐） |
| `limit` / `offset` | — / 0 | 另一种分页；与 page/per_page 二选一 |
| `sort` | `latest` | `latest` / `name` / `rating` / `downloads` |

```json
{ "ok": true, "data": [ /* PluginRecord[]，见 §6 */ ],
  "meta": { "total":1,"page":1,"per_page":20,"total_pages":1,"limit":20,"offset":0,"sort":"latest" } }
```

### 3.3 检索类

| 端点 | 参数 | 返回 |
|------|------|------|
| `GET /api/{product}/plugins/search` | `q`（必填）, `tag`, `sort`(含 `relevance`), `page`, `per_page` | `data: PluginRecord[]` + 分页 meta |
| `GET /api/{product}/plugins/suggest` | `q`, `limit`(≤20, 默认8) | `data: [{type:'plugin'|'tag'|'author', label, value, pluginId?}]` |
| `GET /api/{product}/plugins/tags` | `ids`（逗号分隔，可选） | `data: [{id, name, count}]` |
| `GET /api/{product}/plugins/category` | `tag`（必填, 逗号分隔）, `mode`(`any`/`all`), `sort`, `page`, `per_page` | `data: PluginRecord[]` + 分页 |
| `GET /api/{product}/plugins/latest` | `limit`(默认10) | `data: PluginRecord[]` |
| `GET /api/{product}/plugins/popular` | `limit`(默认10) | `data: PluginRecord[]`（按评分/下载） |
| `GET /api/{product}/plugins/random` | `limit`(≤20, 默认6) | `data: PluginRecord[]` |

### 3.4 详情

```
GET  BASE/api/{product}/plugins/{id}
```
`data` 为一条 PluginRecord（见 §6），附带 `rating_average`/`rating_count`。跨分区 → 404。

### 3.5 资源

| 端点 | 返回 |
|------|------|
| `GET /api/{product}/plugins/{id}/manifest` | 原始 `manifest.json`（**裸 JSON，无信封**） |
| `GET /api/{product}/plugins/{id}/resources/manifest` | 同上（别名） |
| `GET /api/{product}/plugins/{id}/resources/icon` | 图标二进制（image/*） |
| `GET /api/{product}/plugins/{id}/resources/readme` | README 文本（`text/markdown`，相对图片改写为代理地址） |
| `GET /api/{product}/plugins/{id}/resources/screenshots` | 无 `index` → `data: [截图URL...]`；带 `?index=N` → 第 N 张图二进制 |
| `GET /api/{product}/plugins/{id}/resources/asset/{path}` | 插件目录内任意文件（README 图片等） |

### 3.6 下载安装包

```
GET  BASE/api/{product}/plugins/{id}/release
```
- 返回 zip（同 §2.3）。有下载量统计（local 模式）。跨分区 → 404。

### 3.7 横幅

```
GET  BASE/api/{product}/banners?name=home
```
`data: { slides: [{ image?, title, desc?, href?, pluginId? }] }`

### 3.8 作者

```
GET  BASE/api/authors/{authorName}
```
`data: { author:{name, github?}, plugins: PluginRecord[], total_plugins }`（不分区）。

---

## 4. 平台信息

| 端点 | 返回 |
|------|------|
| `GET BASE/api/healthz` | `{ok:true, data:{status:"ok", time}}` |
| `GET BASE/api/meta` | `{ok:true, data:{ name, platform, targets:["vectra","lunar-x"], source_mode, interactions_enabled, plugin_count, api_version }}` |

---

## 5. 评分（可选，需服务端 local 模式）

匿名评分（无需登录，用签名 Cookie 去重；若服务端接了账户系统且开了强制登录则需登录）。

```
GET  BASE/api/{product}/plugins/{id}/ratings
```
```json
{ "ok": true, "data": {
    "rating_count": 1, "rating_average": 5, "writable": true,
    "require_login": false, "authenticated": false,
    "entries": [ { "rating":5, "comment":"nice", "nickname":"stargazer",
                   "created_at":"…", "updated_at":"…", "mine":true } ] } }
```

```
POST BASE/api/{product}/plugins/{id}/ratings
Content-Type: application/json
{ "rating": 1..5, "comment": "可选", "nickname": "可选" }
```
- 成功：`{ok:true, data:{rating_count, rating_average, entry}}`，并可能下发 `Set-Cookie`（请带 Cookie 复用身份）。
- `writable:false`（github 只读源）→ POST 返回 403。

---

## 6. 数据模型

### PluginRecord（完整版 `data` 元素）
```ts
{
  id: string;
  name: string;
  version: string;
  description: string;
  author: { name: string; github?: string };
  owner?: string;                 // 归属账户（Keystone userId 或 GitHub 账号）
  target: "vectra" | "lunar-x";   // 归属分区（单一）
  tags: string[];
  icon: string;                   // 文件名
  readme: string;                 // 文件名
  entry: string;                  // 入口，如 index.js
  sizes: string[];                // ["2x2","3x2"]
  defaultSize?: string;
  singleton: boolean;
  screenshots: string[];
  featured: boolean;
  release?: string;               // 预置发布包文件名（有则直下，无则即时打包）
  rating_average: number;
  rating_count: number;
  downloads: number;
  created_at: string;             // ISO
  updated_at: string;             // ISO
  source: "local" | "github";
  sourceRef?: string;             // 本地 mtime 或 github commit
  resources: {                    // 相对路径，拼 BASE 使用
    icon: string; readme: string; manifest: string; release: string;
    screenshots: string[];
  };
}
```

### MarketPlugin（v1 `plugins[]` 元素）
```ts
{
  id: string; name: string; version: string;
  downloadUrl: string;            // 绝对地址
  description: string; author: string;
  icon: string;                   // 字形字符或 "▢"
  sizes: string[];
  updatedAt?: string;
  readme?: string;                // 仅详情接口有
}
```

---

## 7. 错误处理

- 信封类：非 200 时 body 为 `{ "ok": false, "error": "人话错误信息" }`。
- 常见码：`400` 参数错误 · `401` 未授权 · `403` 只读/禁用 · `404` 不存在或跨分区 · `429` 限流 · `500` 服务端错误。
- 裸数据类（v1/manifest/资源）：出错时 `manifest`/`v1` 返回 `{error:"…"}` + 对应状态码；资源二进制直接 404。
- 客户端务必处理 `ok:false` 与超时（组件不显示时至少给「加载失败/重试」）。

---

## 8. 完整端点索引

| # | 方法 | 端点 | 信封 |
|---|------|------|------|
| 1 | GET | `/api/healthz` | ✓ |
| 2 | GET | `/api/meta` | ✓ |
| 3 | GET | `/api/{product}/banners` | ✓ |
| 4 | GET | `/api/{product}/catalog` | ✓ |
| 5 | GET | `/api/{product}/plugins` | ✓ |
| 6 | GET | `/api/{product}/plugins/search` | ✓ |
| 7 | GET | `/api/{product}/plugins/suggest` | ✓ |
| 8 | GET | `/api/{product}/plugins/tags` | ✓ |
| 9 | GET | `/api/{product}/plugins/category` | ✓ |
| 10 | GET | `/api/{product}/plugins/latest` | ✓ |
| 11 | GET | `/api/{product}/plugins/popular` | ✓ |
| 12 | GET | `/api/{product}/plugins/random` | ✓ |
| 13 | GET | `/api/{product}/plugins/{id}` | ✓ |
| 14 | GET | `/api/{product}/plugins/{id}/manifest` | ✗ 裸 JSON |
| 15 | GET | `/api/{product}/plugins/{id}/resources/{icon,readme,screenshots,manifest,asset/*}` | 二进制/文本 |
| 16 | GET | `/api/{product}/plugins/{id}/release` | ✗ zip |
| 17 | GET/POST | `/api/{product}/plugins/{id}/ratings` | ✓ |
| 18 | GET | `/api/authors/{name}` | ✓ |
| 19 | GET | `/api/v1/catalog` · `/lunar-x/api/v1/catalog` | ✗ 裸 `{plugins}` |
| 20 | GET | `/api/v1/plugins/{id}` | ✗ 裸对象 |

> 另有开发者/账户/管理端点（`/api/scaffold`、`/api/plugins/validate`、`/api/auth/*`、`/api/me`、`/api/webhook/github`、`/api/admin/plugins`），面向发布与后台，客户端市场对接一般用不到，详见 `INTEGRATION.md` / `AUTH.md` / `CONTRIBUTING.md`。

---

## 9. curl 速查

```bash
BASE=https://你的域名

# —— v1 简版（Vectra）——
curl "$BASE/api/v1/catalog"
curl "$BASE/api/v1/plugins/clock-lite"
curl -L "$(curl -s $BASE/api/v1/catalog | jq -r '.plugins[0].downloadUrl')" -o plugin.zip

# —— 完整版 ——
curl "$BASE/api/vectra/plugins?page=1&per_page=20&sort=downloads"
curl "$BASE/api/vectra/plugins/search?q=时钟"
curl "$BASE/api/vectra/plugins/clock-lite"
curl "$BASE/api/vectra/plugins/clock-lite/manifest"
curl -L "$BASE/api/vectra/plugins/clock-lite/release" -o clock-lite.zip

# —— Lunar X 换前缀 ——
curl "$BASE/api/lunar-x/plugins"
curl "$BASE/lunar-x/api/v1/catalog"
```

## 10. 最小客户端示例（JS）

```js
const BASE = "https://你的域名";
const PRODUCT = "vectra"; // 或 "lunar-x"

async function listPlugins() {
  const r = await fetch(`${BASE}/api/${PRODUCT}/plugins?per_page=50`);
  const j = await r.json();
  if (!j.ok) throw new Error(j.error);
  return j.data; // PluginRecord[]
}

async function getDetail(id) {
  const r = await fetch(`${BASE}/api/${PRODUCT}/plugins/${id}`);
  const j = await r.json();
  if (!j.ok) throw new Error(j.error);
  return j.data;
}

async function downloadZip(id) {
  const r = await fetch(`${BASE}/api/${PRODUCT}/plugins/${id}/release`);
  if (!r.ok) throw new Error(`下载失败 ${r.status}`);
  return new Uint8Array(await r.arrayBuffer()); // 解压安装：校验 manifest.id == id，拒绝含 .. 的路径
}
```

---

有疑问或字段对不上，以实际接口返回为准（`/api/meta` 可探测服务端能力）。
