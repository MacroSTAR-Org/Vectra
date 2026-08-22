// launcher 事件接线验证：node test/js/launcher_verify.js
//
// 单独一个文件，因为这里的用例对应真实踩过的坑：
// launcher 曾把 'launch:0'/'add' 这种自造字符串填进 tap 节点的 id，
// 而渲染协议要求填 ctx.on() 返回的处理器 id——宿主拿 id 去 handlers 表
// 查函数，查不到就静默丢弃，表现为"卡片点不动"。天气/待办能点、它不能，
// 差别就在这一处。
const path = require('path');

let pass = 0, fail = 0;
function eq(actual, expected, label) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a === e) { pass++; console.log(`  ok   ${label}`); }
  else { fail++; console.log(`  FAIL ${label}\n       实际 ${a}\n       期望 ${e}`); }
}
function ok(cond, label) {
  if (cond) { pass++; console.log(`  ok   ${label}`); }
  else { fail++; console.log(`  FAIL ${label}`); }
}

// ---- 加载真实插件 ----
let impl = null;
global.lw = { register: function (x) { impl = x; } };
require(path.join(__dirname, '..', '..', 'assets', 'plugins', 'launcher', 'index.js'));

// ---- 仿 prelude 的 ctx：on 登记进 handlers 表，事件按 id 路由 ----
function makeCtx(opts) {
  const handlers = {}; let seq = 0;
  const out = {
    grid: { cols: 2, rows: 2 },
    theme: {},
    settings: opts.settings || {},
    launched: [],
    toasts: [],
    picks: 0,
    pickResult: opts.pickResult,
    trees: [],
    on: function (fn) { const id = 'h' + (++seq); handlers[id] = fn; return id; },
    // 模拟宿主点击：lw.__event(id, payload) 查表调用
    fire: function (id) { const fn = handlers[id]; if (fn) fn({}); },
    handlerIds: function () { return Object.keys(handlers); },
    render: function (tree) { out.trees.push(tree); },
    storage: {
      get: function (k, d) {
        return Promise.resolve(opts.stored === undefined ? d : opts.stored);
      },
      set: function () { return Promise.resolve(true); },
    },
    launch: function (p) { out.launched.push(p); return Promise.resolve(opts.launchResult || { ok: true }); },
    pickFile: function () {
      out.picks++;
      return Promise.resolve(opts.pickResult || { ok: false, cancelled: true });
    },
    toast: function (m) { out.toasts.push(m); },
  };
  return out;
}

const flush = () => new Promise((r) => setImmediate(r));

// 收集渲染树里所有 tap 节点（按出现顺序）
function tapNodes(tree) {
  const out = [];
  (function walk(n) {
    if (!n || typeof n !== 'object') return;
    if (n.t === 'tap') out.push(n);
    if (Array.isArray(n.children)) n.children.forEach(walk);
    if (n.child) walk(n.child);
  })(tree);
  return out;
}

async function main() {
  ok(impl && typeof impl.mount === 'function', '插件调用了 lw.register 并提供 mount');

  console.log('— 场景一：storage 里有两个快捷方式 —');
  const stored = JSON.stringify([
    { name: '记事本', path: 'C:\\Windows\\notepad.exe' },
    { name: '画图', path: 'C:\\Windows\\System32\\mspaint.exe' },
  ]);
  const ctx1 = makeCtx({
    stored,
    pickResult: { ok: true, path: 'C:\\Tools\\perf.msc' },
  });
  impl.mount(ctx1);
  await flush();

  const taps1 = tapNodes(ctx1.trees[ctx1.trees.length - 1]);
  eq(taps1.length, 3, '两个快捷方式 + 添加按钮 = 3 个 tap');

  const ids1 = ctx1.handlerIds();
  ok(taps1.every((t) => ids1.includes(t.id)),
    '每个 tap 的 id 都来自 ctx.on() 返回的处理器 id');
  ok(taps1.every((t) => /^h\d+$/.test(t.id)),
    'tap 的 id 是处理器样式（h1/h2…），不再是自造字符串');
  ok(taps1.every((t) => t.id !== 'add' && !/^launch:/.test(t.id)),
    '回归：没有 tap 直接写死 "add" 或 "launch:N"');

  ctx1.fire(taps1[0].id); await flush();
  ctx1.fire(taps1[1].id); await flush();
  eq(ctx1.launched,
    ['C:\\Windows\\notepad.exe', 'C:\\Windows\\System32\\mspaint.exe'],
    '点击两个格子各自启动对应程序');
  eq(ctx1.toasts, [], '启动成功不弹提示');

  console.log('— 场景二：点击添加按钮 → 选文件 → 列表多一项并重绘 —');
  ctx1.fire(taps1[2].id);
  eq(ctx1.picks, 1, '添加按钮打开文件选择器');
  await flush();
  const taps2 = tapNodes(ctx1.trees[ctx1.trees.length - 1]);
  eq(taps2.length, 4, '添加后重绘出 4 个 tap');
  ctx1.fire(taps2[3].id);
  ok(ctx1.launched.length === 2, '新增的是添加按钮位置，旧按钮点击不误启动');

  console.log('— 场景三：启动失败时给用户提示 —');
  const ctx2 = makeCtx({
    stored: JSON.stringify([{ name: '不存在', path: 'C:\\x\\nope.exe' }]),
    launchResult: { ok: false },
  });
  impl.mount(ctx2);
  await flush();
  const taps3 = tapNodes(ctx2.trees[ctx2.trees.length - 1]);
  ctx2.fire(taps3[0].id); await flush();
  ok(ctx2.toasts.length === 1, '启动失败走 ctx.toast 提示');

  console.log('— 场景四：storage 为空时退回 settings 里的默认快捷方式 —');
  const ctx3 = makeCtx({
    settings: { shortcuts: JSON.stringify([{ name: '计算器', path: 'C:\\calc.exe' }]) },
  });
  impl.mount(ctx3);
  await flush();
  const taps4 = tapNodes(ctx3.trees[ctx3.trees.length - 1]);
  eq(taps4.length, 2, '默认快捷方式 + 添加按钮 = 2 个 tap');
  ctx3.fire(taps4[0].id); await flush();
  eq(ctx3.launched, ['C:\\calc.exe'], '默认快捷方式点击可启动');
}

main().then(() => {
  console.log(`\n结果：${pass} 通过，${fail} 失败`);
  process.exit(fail === 0 ? 0 : 1);
});
