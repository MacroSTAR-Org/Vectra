/// 多显示器坐标换算的行为约定。
///
/// 这些规则几乎没法靠手点验证——要真去插拔显示器、改排列顺序、改缩放比例，
/// 而且错了以后的表现（"卡片自己跑到另一块屏上去了"）事后根本无从复现。
/// 所以每条都在这里钉死。
///
/// 贯穿所有用例的那个坑：卡片存的是**窗口坐标**，而窗口盖住整个虚拟屏、
/// 窗口原点就是虚拟屏原点——它会动。在主屏左边接一块 1920 宽的屏，原点从 0
/// 变成 -1920，所有存下来的坐标就集体偏了 1920 像素。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vectra/core/monitor.dart';

void main() {
  // 一套典型的双屏：主屏 2560x1440 在原点，副屏 1920x1080 摆在它左边。
  // 副屏在左边时虚拟屏原点是负的，这正是最容易出错的排列。
  const primary =
      (id: r'\\.\DISPLAY1', x: 0, y: 0, w: 2560, h: 1440);
  const leftSecond =
      (id: r'\\.\DISPLAY2', x: -1920, y: 0, w: 1920, h: 1080);

  group('找屏', () {
    test('点落在哪块屏上', () {
      const mons = [primary, leftSecond];
      expect(monitorAt(mons, 100, 100)?.id, primary.id);
      expect(monitorAt(mons, -100, 100)?.id, leftSecond.id);
    });

    test('屏与屏之间的空档不算任何一块', () {
      // 副屏比主屏矮，右下角那块区域不属于任何屏
      expect(monitorAt(const [primary, leftSecond], -100, 1300), isNull);
    });

    test('右边界是开区间，不能把相邻屏的第一列算进来', () {
      // 少了这条，摆在 x=0 的主屏第一列会被判成左边那块屏的最后一列
      expect(monitorAt(const [leftSecond], 0, 100), isNull);
      expect(monitorAt(const [leftSecond], -1, 100)?.id, leftSecond.id);
    });

    test('按设备名找；没记过家或那块屏被拔了都返回 null', () {
      expect(monitorById(const [primary], primary.id)?.w, 2560);
      expect(monitorById(const [primary], null), isNull);
      expect(monitorById(const [primary], leftSecond.id), isNull);
    });

    test('最近的屏按屏中心距离算', () {
      expect(nearestMonitor(const [primary, leftSecond], -900, 500)?.id,
          leftSecond.id);
      expect(
          nearestMonitor(const [primary, leftSecond], 1200, 700)?.id, primary.id);
      expect(nearestMonitor(const [], 0, 0), isNull);
    });
  });

  group('窗口坐标 ↔ 屏内相对位置', () {
    test('来回换算能还原（屏没动过时不该有任何位移）', () {
      // 单屏、窗口原点 0：卡片左上角 100,200，尺寸 300x200
      final cx = physicalCenter(0, 100, 300, 1.0);
      final cy = physicalCenter(0, 200, 200, 1.0);
      final home = homeOf(const [primary], cx, cy)!;

      final backX = anchoredTopLeft(
          monitorOrigin: primary.x.toDouble(),
          monitorSize: primary.w.toDouble(),
          rel: home.relX,
          windowOrigin: 0,
          dpr: 1.0,
          cardSize: 300);
      final backY = anchoredTopLeft(
          monitorOrigin: primary.y.toDouble(),
          monitorSize: primary.h.toDouble(),
          rel: home.relY,
          windowOrigin: 0,
          dpr: 1.0,
          cardSize: 200);

      expect(backX, closeTo(100, 1e-9));
      expect(backY, closeTo(200, 1e-9));
      // 误差要远小于判定阈值，否则每次启动都会被当成"位置变了"而重写一次盘
      expect((backX - 100).abs(), lessThan(kAnchorEpsilon));
    });

    test('在左边接一块屏：卡片必须留在原来那块屏的原处', () {
      // 单屏时用户把卡片放在主屏 100,200
      final cx = physicalCenter(0, 100, 300, 1.0);
      final cy = physicalCenter(0, 200, 200, 1.0);
      final home = homeOf(const [primary], cx, cy)!;
      expect(home.id, primary.id);

      // 关掉程序、在左边接一块 1920 宽的屏、再打开：虚拟屏原点变成 -1920。
      // 什么都不做的话，窗口坐标 100 现在指的是屏幕上的 -1820——
      // 卡片会整体跑到左边那块新屏上去，这就是用户看到的"错位"。
      const newOrigin = -1920.0;
      expect(physicalCenter(newOrigin, 100, 300, 1.0), -1670);

      // 按家重新锚定之后，物理位置回到主屏原处
      final fixedX = anchoredTopLeft(
          monitorOrigin: primary.x.toDouble(),
          monitorSize: primary.w.toDouble(),
          rel: home.relX,
          windowOrigin: newOrigin,
          dpr: 1.0,
          cardSize: 300);
      expect(fixedX, closeTo(100 + 1920, 1e-9), reason: '窗口原点左移多少，窗口坐标就要右挪多少');
      expect(physicalCenter(newOrigin, fixedX, 300, 1.0), closeTo(cx, 1e-9),
          reason: '换算完的物理位置必须和当初放下去时一模一样');
    });

    test('缩放比例变了也要钉得住', () {
      // 100% 时放在主屏 400,300
      final cx = physicalCenter(0, 400, 300, 1.0);
      final home = homeOf(const [primary], cx, physicalCenter(0, 300, 200, 1.0))!;

      // 改成 125%：同一个逻辑坐标在屏幕上会往右下角挪
      expect(physicalCenter(0, 400, 300, 1.25), greaterThan(cx));

      final fixedX = anchoredTopLeft(
          monitorOrigin: primary.x.toDouble(),
          monitorSize: primary.w.toDouble(),
          rel: home.relX,
          windowOrigin: 0,
          dpr: 1.25,
          cardSize: 300);
      expect(physicalCenter(0, fixedX, 300, 1.25), closeTo(cx, 1e-9));
    });

    test('那块屏换了分辨率：按比例跟着走，不会掉到屏外', () {
      // 卡片在 2560 宽的屏上正中间
      final cx = physicalCenter(0, 1130, 300, 1.0);
      final home = homeOf(const [primary], cx, physicalCenter(0, 600, 200, 1.0))!;
      expect(home.relX, closeTo(0.5, 0.01));

      const shrunk = (id: r'\\.\DISPLAY1', x: 0, y: 0, w: 1920, h: 1080);
      final x = anchoredTopLeft(
          monitorOrigin: shrunk.x.toDouble(),
          monitorSize: shrunk.w.toDouble(),
          rel: home.relX,
          windowOrigin: 0,
          dpr: 1.0,
          cardSize: 300);
      // 还在新分辨率的正中间附近，而不是留在 1130（那已经快到右边缘了）
      expect(x + 150, closeTo(960, 20));
    });

    test('中心不在任何屏上的卡片认不了家', () {
      expect(homeOf(const [primary, leftSecond], -100, 1300), isNull);
    });
  });
}
