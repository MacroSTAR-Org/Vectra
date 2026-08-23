/// NativeBridge.runUpdateInstaller 的参数契约：走哪条通道、带什么参数。
///
/// 静默自更新是"点一下就换文件"级别的操作，参数拼错一个字符就是
/// 装到别的目录/装不上，所以通道载荷在这里钉死。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vectra/native/native_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  late bool channelResult;

  setUp(() {
    calls = [];
    channelResult = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('vectra/native'), (call) async {
      calls.add(call);
      if (call.method == 'runUpdateInstaller') return channelResult;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('vectra/native'), null);
  });

  test('透传安装器路径与目标目录', () async {
    const installer =
        r'C:\Users\Seren\AppData\update\Vectra-0.1.2.156-便携版.exe';
    const dir = r'I:\Tools\Vectra';
    final ok = await NativeBridge.runUpdateInstaller(installer, dir);
    expect(ok, isTrue);
    expect(calls, hasLength(1));
    expect(calls.first.method, 'runUpdateInstaller');
    expect(calls.first.arguments, {'installer': installer, 'dir': dir});
  });

  test('native 返回 false 时拿到 false', () async {
    channelResult = false;
    final ok = await NativeBridge.runUpdateInstaller(r'C:\a.exe', r'C:\dir');
    expect(ok, isFalse);
  });

  test('空路径直接拦下，不进通道', () async {
    expect(await NativeBridge.runUpdateInstaller('', r'C:\dir'), isFalse);
    expect(await NativeBridge.runUpdateInstaller(r'C:\a.exe', ''), isFalse);
    expect(calls, isEmpty);
  });
}
