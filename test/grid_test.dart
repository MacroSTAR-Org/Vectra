// 从 Electron 版 test/grid.test.mjs 1:1 移植
import 'package:flutter_test/flutter_test.dart';
import 'package:vectra/core/grid.dart';

const cell = 112;
const gap = 12;

void main() {
  test('解析规格字符串', () {
    expect(parseSize('2x3'), const GridSize(2, 3));
    expect(parseSize(' 4X2 '), const GridSize(4, 2));
    expect(parseSize('0x2'), isNull);
    expect(parseSize('9x1'), isNull, reason: '超过上限应拒绝');
    expect(parseSize('abc'), isNull);
    expect(parseSize(''), isNull);
  });

  test('规格换算像素：含格间距', () {
    expect(sizeToPx('1x1', cell, gap), const PxSize(112, 112));
    expect(sizeToPx('2x2', cell, gap), const PxSize(236, 236));
    expect(sizeToPx('4x2', cell, gap), const PxSize(484, 236));
    expect(sizeToPx('2x4', cell, gap), const PxSize(236, 484));
  });

  test('像素反推格数', () {
    final u = pxToUnits(const PxSize(236, 484), cell, gap);
    expect(u.cols.round(), 2);
    expect(u.rows.round(), 4);
  });

  test('取最接近的可选规格', () {
    final allowed = ['2x2', '4x2', '4x4'];
    expect(nearestSize(const PxSize(240, 230), allowed, cell, gap), '2x2');
    expect(nearestSize(const PxSize(470, 240), allowed, cell, gap), '4x2');
    expect(nearestSize(const PxSize(500, 500), allowed, cell, gap), '4x4');
  });

  test('宽扁不会被高瘦抢走', () {
    final allowed = ['2x4', '4x2'];
    expect(nearestSize(const PxSize(484, 236), allowed, cell, gap), '4x2');
    expect(nearestSize(const PxSize(236, 484), allowed, cell, gap), '2x4');
  });

  test('规格列表去重并按面积排序', () {
    expect(normalizeSizes(['4x4', '2x2', '4x4', 'bad', '4x2']),
        ['2x2', '4x2', '4x4']);
  });

  test('coerce：合法保留，非法取最近', () {
    final allowed = ['2x2', '4x2'];
    expect(coerceSize('2x2', allowed, cell, gap), '2x2');
    expect(coerceSize('4x3', allowed, cell, gap), '4x2', reason: '不在列表时落到最近的');
    expect(coerceSize('乱写', allowed, cell, gap), '2x2');
  });

  test('距离并列时取更小的规格（避免突然变大溢出屏幕）', () {
    // 3x2 到 2x2 与 4x2 的距离都是 1
    expect(coerceSize('3x2', ['2x2', '4x2'], cell, gap), '2x2');
  });

  test('旧布局像素尺寸迁移到规格', () {
    // v1 时钟默认 280x280 -> 最接近 2x2(236)
    expect(migratePxToSize(280, 280, ['2x2', '3x3', '4x2'], cell, gap), '2x2');
    // v1 天气 320x300 -> 3x3(360) 比 2x2(236) 更近
    expect(migratePxToSize(320, 300, ['2x2', '3x3', '4x3'], cell, gap), '3x3');
    // 脏数据兜底
    expect(migratePxToSize(double.nan, double.nan, ['3x3', '2x2'], cell, gap), '2x2');
  });

  test('换网格单元大小时规格不变、像素等比变化', () {
    final a = sizeToPx('3x2', 112, 12);
    final b = sizeToPx('3x2', 140, 12);
    expect(b.w > a.w && b.h > a.h, isTrue);
    expect(coerceSize('3x2', ['3x2'], 140, 12), '3x2');
  });
}
