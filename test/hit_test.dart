// 从 Electron 版 test/hit.test.mjs 1:1 移植。
// 注意用例里"外圈会吃掉点击"的措辞是 Electron 多窗口时代的背景；在 Flutter
// 单窗口架构下，同样这批断言保证的是 WM_NCHITTEST 不会把间隙判给任何卡片。
import 'package:flutter_test/flutter_test.dart';
import 'package:vectra/core/hit.dart';

const a = HitRect(id: 'a', x: 576, y: 58, w: 484, h: 360, z: 5); // 日历
const b = HitRect(id: 'b', x: 1072, y: 58, w: 360, h: 360, z: 7); // 待办（更靠上层）

void main() {
  test('矩形内部命中', () {
    expect(insideRoundedRect(700, 200, a), isTrue);
  });

  test('矩形外部不命中', () {
    expect(insideRoundedRect(1065, 200, a), isFalse, reason: '右侧 12px 间隙里不该命中');
    expect(insideRoundedRect(700, 40, a), isFalse);
  });

  test('圆角被正确切掉', () {
    expect(insideRoundedRect(a.x + 2, a.y + 2, a), isFalse, reason: '左上角外侧');
    expect(insideRoundedRect(a.x + 2, a.y + 180, a), isTrue, reason: '左边中点在内');
    expect(insideRoundedRect(a.x + 240, a.y + 1, a), isTrue, reason: '顶边中点在内');
  });

  test('间隙里两个组件都不命中', () {
    for (var x = 1061.0; x < 1072; x++) {
      expect(topmostAt(x, 200, [a, b]), isNull, reason: 'x=$x 落在 12px 间隙里');
    }
  });

  test('邻居可见区归邻居', () {
    expect(topmostAt(1080, 200, [a, b]), 'b');
    expect(topmostAt(1100, 200, [a, b]), 'b');
  });

  test('重叠时取 z 更大的', () {
    const over = HitRect(id: 'c', x: 600, y: 80, w: 200, h: 200, z: 9);
    expect(topmostAt(700, 200, [a, over]), 'c');
    expect(topmostAt(700, 400, [a, over]), 'a', reason: '只在 A 范围内时仍是 A');
  });

  test('指针不在任何组件上时返回 null', () {
    expect(topmostAt(10, 10, [a, b]), isNull);
  });
}
