// 工具冒烟测试：直接跑工具，不经过模型。
// ignore_for_file: avoid_print
// 直接跑工具，不经过模型：验证 PowerShell 那几段到底能不能用
import 'package:vectra/ai/tools.dart';
import 'package:vectra/ai/file_parser.dart';
import 'dart:io';

Future<void> main() async {
  var pass = 0, fail = 0;
  Future<void> check(String what, Future<String> Function() run,
      bool Function(String) ok) async {
    try {
      final r = await run();
      final good = ok(r);
      if (good) { pass++; print('  通过  $what -> ${r.split("\n").first}'); }
      else { fail++; print('  失败  $what -> ${r.replaceAll("\n", " | ").substring(0, r.length > 160 ? 160 : r.length)}'); }
    } catch (e) { fail++; print('  异常  $what -> $e'); }
  }

  print('--- 只读工具 ---');
  await check('system_info', () => Tools.byName('system_info')!.run({}),
      (r) => r.contains('系统:') && r.contains('CPU'));
  await check('get_volume', () => Tools.byName('get_volume')!.run({}),
      (r) => double.tryParse(r.trim()) != null);
  await check('list_dir', () => Tools.byName('list_dir')!.run({'path': Directory.current.path}),
      (r) => r.contains('文件') || r.contains('目录'));

  print('--- 文件解析 ---');
  final tmp = File('${Directory.systemTemp.path}/lw_tool_test.md');
  await tmp.writeAsString('# 标题\n这是一段测试文字。');
  await check('解析 md', () async => (await FileParser.parse(tmp.path)).text,
      (r) => r.contains('这是一段测试文字'));
  await check('read_file 工具', () => Tools.byName('read_file')!.run({'path': tmp.path}),
      (r) => r.contains('这是一段测试文字') && r.contains('【文件】'));

  print('--- 工具 schema ---');
  final schemas = Tools.schemas();
  final names = Tools.all.map((t) => t.name).toList();
  print('  共 ${schemas.length} 个工具: ${names.join(", ")}');
  final danger = Tools.all.where((t) => t.risk == ToolRisk.danger).map((t) => t.name).toList();
  print('  需确认的: ${danger.join(", ")}');
  if (danger.contains('run_powershell') && danger.contains('power') && danger.contains('delete_file')) {
    pass++; print('  通过  危险工具分级正确');
  } else { fail++; print('  失败  危险工具分级不对'); }

  print('\n通过 $pass / ${pass + fail}');
  exit(fail > 0 ? 1 : 0);
}
