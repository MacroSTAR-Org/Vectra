// launcher 事件接线与编辑面验证：node test/js/launcher_verify.js
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
require(path.join(__dirname, '..', '..', 'plugins', 'launcher', 'index.js'));

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
    saved: [],
    on: function (fn) { const id = 'h' + (++seq); handlers[id] = fn; return id; },
    // 模拟宿主事件：lw.__event(id, payload) 查表调用（tap 恒 {}，input 带 {value}）
    fire: function (id, payload) { const fn = handlers[id]; if (fn) fn(payload || {}); },
    handlerIds: function () { return Object.keys(handlers); },
    render: function (tree) { out.trees.push(tree); },
    storage: {
      get: function (k, d) {
        return Promise.resolve(opts.stored === undefined ? d : opts.stored);
      },
      set: function (k, v) { out.saved.push(v); return Promise.resolve(true); },
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
const lastTree = (ctx) => ctx.trees[ctx.trees.length - 1];

// 深度遍历收集节点
function collect(node, pred, out = []) {
  if (!node || typeof node !== 'object') return out;
  if (pred(node)) out.push(node);
  if (Array.isArray(node.children)) node.children.forEach((c) => collect(c, pred, out));
  if (node.child) collect(node.child, pred, out);
  return out;
}
const tapsIn = (node) => collect(node, (n) => n.t === 'tap');
const inputsIn = (node) => collect(node, (n) => n.t === 'input');
const allTaps = (tree) => tapsIn(tree);

// flip 双面都在树上，取当前正/背面
function faces(tree) {
  const flip = collect(tree, (n) => n.t === 'flip')[0];
  return { flip, front: flip.children[0], back: flip.children[1] };
}

// 正面启动格：tap > col > [盒(内含首字母文字), 名字]；尾格小按钮的盒里是图标，靠这个区分
const frontNames = (front) =>
  tapsIn(front)
    .filter((t) => {
      const c = t.child;
      return c && c.t === 'col' && Array.isArray(c.children) && c.children.length === 2 &&
        c.children[0].t === 'box' && c.children[0].child && c.children[0].child.t === 'text' &&
        c.children[1].t === 'text';
    })
    .map((t) => t.child.children[1].v);

async function main() {
  ok(impl && typeof impl.mount === 'function', '插件调用了 lw.register 并提供 mount');

  console.log('— 场景一：storage 里有两个快捷方式，正面可点 —');
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

  const f1 = faces(lastTree(ctx1));
  const frontTaps1 = tapsIn(f1.front);
  eq(f1.flip.flipKey, 'front', '初始在正面');
  eq(frontTaps1.length, 4, '两个启动格 + 添加/管理两个小按钮 = 4 个 tap');
  const ids1 = ctx1.handlerIds();
  ok(allTaps(lastTree(ctx1)).every((t) => ids1.includes(t.id)),
    '两面每个 tap 的 id 都来自 ctx.on() 返回的处理器 id');
  ok(frontTaps1.every((t) => /^h\d+$/.test(t.id)),
    'tap 的 id 是处理器样式（h1/h2…），不再是自造字符串');

  ctx1.fire(frontTaps1[0].id); await flush();
  ctx1.fire(frontTaps1[1].id); await flush();
  eq(ctx1.launched,
    ['C:\\Windows\\notepad.exe', 'C:\\Windows\\System32\\mspaint.exe'],
    '点击两个格子各自启动对应程序');
  eq(ctx1.toasts, [], '启动成功不弹提示');

  console.log('— 场景二：正面添加按钮 → 选文件 → 列表多一项并重绘 —');
  ctx1.fire(frontTaps1[2].id); // 尾格第一个小按钮 = 添加
  eq(ctx1.picks, 1, '添加按钮打开文件选择器');
  await flush();
  const frontTaps2 = tapsIn(faces(lastTree(ctx1)).front);
  eq(frontTaps2.length, 5, '添加后正面有 3 个启动格 + 2 个小按钮');
  eq(frontNames(faces(lastTree(ctx1)).front), ['记事本', '画图', 'perf'],
    '新程序按文件名入列');
  ctx1.fire(frontTaps2[0].id); await flush();
  eq(ctx1.launched[ctx1.launched.length - 1], 'C:\\Windows\\notepad.exe',
    '重绘后第一格仍启动记事本（处理器不是陈旧的）');

  console.log('— 场景三：翻到编辑面，行内删除 / 重排 / 重命名 —');
  ctx1.fire(tapsIn(faces(lastTree(ctx1)).front)[4].id); // 尾格第二个小按钮 = 管理
  let f3 = faces(lastTree(ctx1));
  eq(f3.flip.flipKey, 'edit', '点管理翻到编辑面');
  // 编辑行每行 4 个 tap：[名字(重命名), 上移, 下移, 删除]，底部还有 2 个
  const backTaps3 = tapsIn(f3.back);
  eq(backTaps3.length, 3 * 4 + 2, '3 行 × (重命名/上移/下移/删除) + 添加/完成');

  // 删除第一行（记事本）：第 0 行的第 4 个 tap
  ctx1.fire(backTaps3[3].id); await flush();
  f3 = faces(lastTree(ctx1));
  eq(frontNames(f3.front), ['画图', 'perf'], '删除"记事本"后剩两项');
  ok(ctx1.saved.length >= 1 && JSON.parse(ctx1.saved[ctx1.saved.length - 1]).length === 2,
    '删除后写入 storage');

  // 重排：把第 1 行（perf）上移 → [perf, 画图]
  const backTaps4 = tapsIn(f3.back);
  ctx1.fire(backTaps4[5].id); await flush(); // 第 1 行的上移
  eq(frontNames(faces(lastTree(ctx1)).front), ['perf', '画图'], '上移生效');

  // 重命名：点第 0 行名字 → 变输入框，预填旧名；提交新名
  ctx1.fire(tapsIn(faces(lastTree(ctx1)).back)[0].id); await flush();
  const renameTree = faces(lastTree(ctx1));
  const input = inputsIn(renameTree.back)[0];
  ok(!!input && input.value === 'perf', '点名字进入重命名，输入框预填旧名');
  ctx1.fire(input.submit, { value: '性能监视器' }); await flush();
  eq(frontNames(faces(lastTree(ctx1)).front), ['性能监视器', '画图'], '提交新名后更新');
  eq(inputsIn(faces(lastTree(ctx1)).back).length, 0, '重命名完成后输入框收起');
  ok(ctx1.saved.length >= 3, '重命名也写入 storage');

  // 完成：翻回正面
  ctx1.fire(tapsIn(faces(lastTree(ctx1)).back)[tapsIn(faces(lastTree(ctx1)).back).length - 1].id);
  await flush();
  eq(faces(lastTree(ctx1)).flip.flipKey, 'front', '点完成翻回正面');
  ctx1.fire(tapsIn(faces(lastTree(ctx1)).front)[0].id); await flush();
  eq(ctx1.launched[ctx1.launched.length - 1], 'C:\\Tools\\perf.msc',
    '编辑后的第一格启动的是重排+改名后的程序');

  console.log('— 场景四：启动失败时给用户提示 —');
  const ctx2 = makeCtx({
    stored: JSON.stringify([{ name: '不存在', path: 'C:\\x\\nope.exe' }]),
    launchResult: { ok: false },
  });
  impl.mount(ctx2);
  await flush();
  ctx2.fire(tapsIn(faces(lastTree(ctx2)).front)[0].id); await flush();
  ok(ctx2.toasts.length === 1, '启动失败走 ctx.toast 提示');

  console.log('— 场景五：storage 为空时退回 settings 里的旧配置 —');
  const ctx3 = makeCtx({
    settings: { shortcuts: JSON.stringify([{ name: '计算器', path: 'C:\\calc.exe' }]) },
  });
  impl.mount(ctx3);
  await flush();
  const f5 = faces(lastTree(ctx3));
  eq(frontNames(f5.front), ['计算器'], '老用户在面板配过的数据照常导入');
  ctx3.fire(tapsIn(f5.front)[0].id); await flush();
  eq(ctx3.launched, ['C:\\calc.exe'], '导入的快捷方式点击可启动');

  console.log('— 场景六：全新安装（无 storage 无 settings）给空态引导 —');
  const ctx4 = makeCtx({});
  impl.mount(ctx4);
  await flush();
  const f6 = faces(lastTree(ctx4));
  eq(f6.flip.flipKey, 'front', '空列表也在正面');
  const emptyTaps = tapsIn(f6.front);
  eq(emptyTaps.length, 2, '空态只有 添加/管理 两个按钮');
  ctx4.fire(emptyTaps[0].id); // 空态点添加
  eq(ctx4.picks, 1, '空态的添加按钮可用');
}

main().then(() => {
  console.log(`\n结果：${pass} 通过，${fail} 失败`);
  process.exit(fail === 0 ? 0 : 1);
});
