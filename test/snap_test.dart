// 从 Electron 版 test/snap.test.mjs 1:1 移植
import 'package:flutter_test/flutter_test.dart';
import 'package:vectra/core/snap.dart';

const bounds = (w: 1920.0, h: 1040.0);
const threshold = 10.0;
const gutter = 12.0;

// 左500 右700 上300 下450 中心(600,375)
const anchor = Rect(500, 300, 200, 150);

SnapResult run(Rect moving, List<Rect> others) =>
    resolve(moving, others, threshold: threshold, gutter: gutter, bounds: bounds);

void main() {
  test('左边缘对齐：偏差在阈值内时吸附', () {
    final r = run(const Rect(506, 700, 200, 150), [anchor]);
    expect(r.x, 500);
    expect(r.snappedX, isTrue);
  });

  test('超出阈值不吸附', () {
    final r = run(const Rect(520, 700, 200, 150), [anchor]);
    expect(r.x, 520);
    expect(r.snappedX, isFalse);
  });

  test('右边缘对齐', () {
    final r = run(const Rect(597, 700, 100, 150), [anchor]);
    expect(r.x, 600); // 600 + 100 = 700 = anchor 右边
    expect(r.snappedX, isTrue);
  });

  test('水平中线对齐', () {
    // 中心对齐解: x = 600 - 50 = 550
    final r = run(const Rect(553, 700, 100, 150), [anchor]);
    expect(r.x, 550);
  });

  test('贴合吸附：零间距咬合到右侧', () {
    final r = run(const Rect(703, 300, 120, 150), [anchor]);
    expect(r.x, 700); // 紧贴 anchor 右边
    expect(r.snappedX, isTrue);
  });

  test('贴合吸附：按 gutter 留白', () {
    final r = run(const Rect(714, 300, 120, 150), [anchor]);
    expect(r.x, 712); // 700 + gutter(12)
  });

  test('X/Y 两轴独立生效', () {
    final r = run(const Rect(504, 296, 200, 150), [anchor]);
    expect(r.x, 500);
    expect(r.y, 300);
    expect(r.snappedX, isTrue);
    expect(r.snappedY, isTrue);
  });

  test('顶边贴合到 anchor 底部', () {
    final r = run(const Rect(900, 452, 200, 150), [anchor]);
    expect(r.y, 450);
  });

  test('没有其它卡片时原样返回', () {
    final r = run(const Rect(123, 456, 200, 150), []);
    expect(r.x, 123);
    expect(r.y, 456);
    expect(r.guides, isEmpty);
  });

  test('夹在画布内，且被夹回后不残留辅助线', () {
    final r = run(const Rect(-50, -50, 200, 150), [anchor]);
    expect(r.x, 0);
    expect(r.y, 0);
    expect(r.snappedX, isFalse);
    expect(r.guides, isEmpty);
  });

  test('右下越界被夹回', () {
    final r = run(const Rect(5000, 5000, 200, 150), []);
    expect(r.x, bounds.w - 200);
    expect(r.y, bounds.h - 150);
  });

  test('吸附时产生辅助线，且线段覆盖两张卡片', () {
    final r = run(const Rect(506, 700, 200, 150), [anchor]);
    final v = r.guides.where((g) => g.type == 'v').firstOrNull;
    expect(v, isNotNull, reason: '应有竖向辅助线');
    expect(v!.pos, 500);
    expect(v.start <= 300, isTrue, reason: '线应向上覆盖到 anchor');
    expect(v.end >= 850, isTrue, reason: '线应向下覆盖到拖动卡片');
  });

  test('辅助线按位置去重', () {
    const a2 = Rect(500, 600, 200, 150);
    final r = run(const Rect(503, 900, 200, 150), [anchor, a2]);
    final vs = r.guides
        .where((g) => g.type == 'v' && g.pos.round() == 500)
        .toList();
    expect(vs.length, 1, reason: '同一 x 只保留一条线');
  });

  test('多候选取最近者', () {
    // anchor 右边 700；候选 x=698 距"贴合700"2px，距"对齐左500"198px
    final r = run(const Rect(698, 300, 100, 150), [anchor]);
    expect(r.x, 700);
  });

  // 落点区域：整块屏（原点 0,0）
  final area = Rect(0, 0, bounds.w, bounds.h);

  test('findFreeSpot 避开已占位置', () {
    final others = [const Rect(40, 40, 200, 150)];
    final spot = findFreeSpot(const PxRect(200, 150), others, area);
    final hit = spot.x < 240 &&
        spot.x + 200 > 40 &&
        spot.y < 190 &&
        spot.y + 150 > 40;
    expect(hit, isFalse, reason: '新落点不应与已有卡片重叠');
  });

  test('findFreeSpot 从右上角开始找', () {
    final spot = findFreeSpot(const PxRect(200, 150), [], area);
    expect(spot.y, 40, reason: '应贴着上边缘的留白');
    expect(spot.x, bounds.w - 40 - 200, reason: '应贴着右边缘的留白');
  });

  test('findFreeSpot 右上被占时往左让', () {
    // 占住右上角那一块
    final others = [Rect(bounds.w - 240, 40, 200, 150)];
    final spot = findFreeSpot(const PxRect(200, 150), others, area);
    expect(spot.y, 40, reason: '同一行还有空位，不该换行');
    expect(spot.x < bounds.w - 240, isTrue, reason: '应落在被占块的左边');
  });

  test('findFreeSpot 限制在指定显示器内', () {
    // 第二块屏：从 x=1920 开始
    const second = Rect(1920, 0, 1920, 1040);
    final spot = findFreeSpot(const PxRect(200, 150), [], second);
    expect(spot.x >= 1920, isTrue, reason: '不能跑到第一块屏上');
    expect(spot.x + 200 <= 3840, isTrue);
    expect(spot.x, 1920 + 1920 - 40 - 200, reason: '仍是该屏的右上角');
  });

  group('一种组件每块屏最多一个', () {
    final screens = [
      const Rect(0, 0, 1920, 1040),
      const Rect(1920, 0, 1920, 1040),
    ];

    test('都空着时挑第一块', () {
      expect(firstFreeMonitor(screens, []), 0);
    });

    test('第一块被占则挑第二块', () {
      final placed = [const Rect(100, 100, 200, 150)];
      expect(firstFreeMonitor(screens, placed), 1);
    });

    test('两块都被占则不给加', () {
      final placed = [
        const Rect(100, 100, 200, 150),
        const Rect(2000, 100, 200, 150),
      ];
      expect(firstFreeMonitor(screens, placed), isNull);
    });

    test('只占了第二块时挑第一块', () {
      final placed = [const Rect(2000, 100, 200, 150)];
      expect(firstFreeMonitor(screens, placed), 0);
    });

    test('横跨边界的卡片按中心点算归属', () {
      // 卡片从 1820 到 2020，中心 1920 已落在第二块屏
      final placed = [const Rect(1820, 100, 200, 150)];
      expect(firstFreeMonitor(screens, placed), 0,
          reason: '中心在第二块，所以第一块仍算空着');
    });

    test('单屏时放了一个就满了', () {
      final one = [const Rect(0, 0, 1920, 1040)];
      expect(firstFreeMonitor(one, []), 0);
      expect(firstFreeMonitor(one, [const Rect(50, 50, 200, 150)]), isNull);
    });

    test('卡片在屏幕之外时不占任何一块', () {
      final placed = [const Rect(9000, 9000, 200, 150)];
      expect(firstFreeMonitor(screens, placed), 0);
    });
  });

  test('clamp 边界', () {
    expect(clamp(-5, 0, 10), 0);
    expect(clamp(15, 0, 10), 10);
    expect(clamp(5, 0, 10), 5);
  });
}
