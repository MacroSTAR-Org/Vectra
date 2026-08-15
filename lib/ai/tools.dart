/// Agent 工具集：模型能对这台电脑做的每一件事，都在这个文件里。
///
/// 授权分三档（用户选定的模型）：
///   read   只读——直接执行，不打扰
///   write  常用且可逆的写操作（音量/主题/开网页）——直接执行
///   danger 危险或不可逆（执行脚本/删文件/关机）——必须用户点"允许"
///
/// 把权限写死在工具定义里，而不是让模型自己声明，是有意的：
/// 模型可以骗自己"这个不危险"，但它改不了这张表。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'file_parser.dart';

enum ToolRisk { read, write, danger }

class ToolDef {
  const ToolDef({
    required this.name,
    required this.description,
    required this.parameters,
    required this.risk,
    required this.run,
    this.summarize,
  });

  final String name;
  final String description;

  /// JSON Schema，直接发给模型
  final Map<String, Object?> parameters;
  final ToolRisk risk;
  final Future<String> Function(Map<String, Object?> args) run;

  /// 生成给用户看的一句话描述（确认卡片上显示）
  final String Function(Map<String, Object?> args)? summarize;

  Map<String, Object?> toSchema() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': parameters,
        }
      };
}

class Tools {
  static final List<ToolDef> all = [
    // ---------------- 只读 ----------------
    ToolDef(
      name: 'read_file',
      description: '读取并解析一个文件的文字内容。支持 txt/md/json/csv/代码、'
          'docx/xlsx/pptx，以及 PDF（基础文本抽取）。图片无法解析。',
      risk: ToolRisk.read,
      parameters: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': '文件的完整路径'}
        },
        'required': ['path'],
      },
      run: (a) async {
        final parsed = await FileParser.parse('${a['path']}');
        return parsed.forPrompt();
      },
    ),
    ToolDef(
      name: 'list_dir',
      description: '列出目录下的文件和子目录。',
      risk: ToolRisk.read,
      parameters: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': '目录路径'}
        },
        'required': ['path'],
      },
      run: (a) async {
        final dir = Directory('${a['path']}');
        if (!await dir.exists()) return '目录不存在：${a['path']}';
        final out = StringBuffer();
        var n = 0;
        await for (final e in dir.list()) {
          if (n++ >= 200) {
            out.writeln('…（超过 200 项，已截断）');
            break;
          }
          final isDir = e is Directory;
          final size = e is File ? '  ${await e.length()} B' : '';
          out.writeln('${isDir ? "[目录] " : "[文件] "}${p.basename(e.path)}$size');
        }
        return out.isEmpty ? '（空目录）' : out.toString();
      },
    ),
    ToolDef(
      name: 'system_info',
      description: '查询这台电脑的系统信息：系统版本、CPU、内存、磁盘、电池。',
      risk: ToolRisk.read,
      parameters: {'type': 'object', 'properties': {}},
      run: (_) => _ps(r'''
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
"系统: $($os.Caption) $($os.Version)"
"电脑: $($cs.Manufacturer) $($cs.Model)"
"CPU : $cpu"
"内存: {0:N1} GB (可用 {1:N1} GB)" -f ($cs.TotalPhysicalMemory/1GB), ($os.FreePhysicalMemory*1KB/1GB)
Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
  "磁盘 {0} 可用 {1:N1} GB / 共 {2:N1} GB" -f $_.DeviceID, ($_.FreeSpace/1GB), ($_.Size/1GB)
}
$b = Get-CimInstance Win32_Battery
if ($b) { "电池: $($b.EstimatedChargeRemaining)%" } else { "电池: 无" }
'''),
    ),
    ToolDef(
      name: 'get_volume',
      description: '查询当前系统音量（0-100）。',
      risk: ToolRisk.read,
      parameters: {'type': 'object', 'properties': {}},
      run: (_) => _ps('$_volGetter\n[Audio]::Volume * 100'),
    ),
    ToolDef(
      name: 'search_files',
      description: '在某个目录下按文件名关键字递归查找文件。',
      risk: ToolRisk.read,
      parameters: {
        'type': 'object',
        'properties': {
          'dir': {'type': 'string', 'description': '起始目录'},
          'keyword': {'type': 'string', 'description': '文件名包含的关键字'},
        },
        'required': ['dir', 'keyword'],
      },
      run: (a) => _ps(
          'Get-ChildItem -Path "${a['dir']}" -Recurse -File -Filter "*${a['keyword']}*" '
          '-ErrorAction SilentlyContinue | Select-Object -First 50 -ExpandProperty FullName'),
    ),

    // ---------------- 常用写操作（免确认） ----------------
    ToolDef(
      name: 'set_volume',
      description: '设置系统音量。',
      risk: ToolRisk.write,
      parameters: {
        'type': 'object',
        'properties': {
          'percent': {'type': 'integer', 'description': '音量 0-100'}
        },
        'required': ['percent'],
      },
      summarize: (a) => '把音量调到 ${a['percent']}%',
      run: (a) async {
        final v = ((a['percent'] as num?)?.toInt() ?? 50).clamp(0, 100);
        await _ps('$_volGetter\n[Audio]::Volume = ${v / 100}');
        return '音量已设为 $v%';
      },
    ),
    ToolDef(
      name: 'set_theme',
      description: '切换 Windows 的深色/浅色主题。',
      risk: ToolRisk.write,
      parameters: {
        'type': 'object',
        'properties': {
          'mode': {
            'type': 'string',
            'enum': ['dark', 'light'],
            'description': 'dark 或 light'
          }
        },
        'required': ['mode'],
      },
      summarize: (a) => '把系统主题切到${a['mode'] == 'dark' ? '深色' : '浅色'}',
      run: (a) async {
        final dark = '${a['mode']}' == 'dark';
        final v = dark ? 0 : 1;
        const key =
            r'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize';
        await _ps('Set-ItemProperty -Path "$key" -Name AppsUseLightTheme -Value $v; '
            'Set-ItemProperty -Path "$key" -Name SystemUsesLightTheme -Value $v');
        return '主题已切换为${dark ? "深色" : "浅色"}';
      },
    ),
    ToolDef(
      name: 'open_url',
      description: '用默认浏览器打开一个网址。',
      risk: ToolRisk.write,
      parameters: {
        'type': 'object',
        'properties': {
          'url': {'type': 'string'}
        },
        'required': ['url'],
      },
      summarize: (a) => '打开网页 ${a['url']}',
      run: (a) async {
        final url = '${a['url']}';
        if (!url.startsWith('http://') && !url.startsWith('https://')) {
          return '只允许 http/https 网址';
        }
        await Process.run('cmd', ['/c', 'start', '', url]);
        return '已打开 $url';
      },
    ),
    ToolDef(
      name: 'open_app',
      description: '启动一个程序，或用默认程序打开某个文件/文件夹。',
      risk: ToolRisk.write,
      parameters: {
        'type': 'object',
        'properties': {
          'target': {
            'type': 'string',
            'description': '程序名（如 notepad、calc）或文件/文件夹路径'
          }
        },
        'required': ['target'],
      },
      summarize: (a) => '打开 ${a['target']}',
      run: (a) async {
        await Process.run('cmd', ['/c', 'start', '', '${a['target']}']);
        return '已打开 ${a['target']}';
      },
    ),
    ToolDef(
      name: 'open_settings',
      description: '打开 Windows 设置的某一页。常用 page 值：'
          'display 显示、sound 声音、bluetooth 蓝牙、network 网络、'
          'personalization 个性化、powersleep 电源、windowsupdate 更新、'
          'apps 应用、privacy 隐私。',
      risk: ToolRisk.write,
      parameters: {
        'type': 'object',
        'properties': {
          'page': {'type': 'string', 'description': '设置页标识'}
        },
        'required': ['page'],
      },
      summarize: (a) => '打开系统设置的「${a['page']}」页',
      run: (a) async {
        const map = {
          'display': 'ms-settings:display',
          'sound': 'ms-settings:sound',
          'bluetooth': 'ms-settings:bluetooth',
          'network': 'ms-settings:network',
          'wifi': 'ms-settings:network-wifi',
          'personalization': 'ms-settings:personalization',
          'powersleep': 'ms-settings:powersleep',
          'windowsupdate': 'ms-settings:windowsupdate',
          'apps': 'ms-settings:appsfeatures',
          'privacy': 'ms-settings:privacy',
          'about': 'ms-settings:about',
          'storage': 'ms-settings:storagesense',
        };
        final uri = map['${a['page']}'.toLowerCase()] ?? 'ms-settings:';
        await Process.run('cmd', ['/c', 'start', '', uri]);
        return '已打开设置页 $uri';
      },
    ),

    // ---------------- 危险（必须确认） ----------------
    ToolDef(
      name: 'run_powershell',
      description: '执行一段 PowerShell 脚本。任何前面工具做不到的事都可以用它，'
          '包括改系统设置、批量处理文件、查询任意信息。会先让用户确认。',
      risk: ToolRisk.danger,
      parameters: {
        'type': 'object',
        'properties': {
          'script': {'type': 'string', 'description': '要执行的 PowerShell 脚本'},
          'purpose': {'type': 'string', 'description': '用一句话说明这段脚本要做什么'},
        },
        'required': ['script'],
      },
      summarize: (a) => '${a['purpose'] ?? '执行 PowerShell 脚本'}',
      run: (a) => _ps('${a['script']}'),
    ),
    ToolDef(
      name: 'delete_file',
      description: '删除一个文件（进回收站，不是彻底删除）。',
      risk: ToolRisk.danger,
      parameters: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'}
        },
        'required': ['path'],
      },
      summarize: (a) => '把 ${a['path']} 删到回收站',
      run: (a) async {
        // 走回收站而不是直接删：给用户留后悔的余地
        final r = await _ps(
            'Add-Type -AssemblyName Microsoft.VisualBasic;'
            '[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile('
            '"${a['path']}","OnlyErrorDialogs","SendToRecycleBin")');
        return r.trim().isEmpty ? '已删除到回收站：${a['path']}' : r;
      },
    ),
    ToolDef(
      name: 'power',
      description: '电源操作：锁屏、睡眠、关机、重启。',
      risk: ToolRisk.danger,
      parameters: {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'enum': ['lock', 'sleep', 'shutdown', 'restart']
          }
        },
        'required': ['action'],
      },
      summarize: (a) => switch ('${a['action']}') {
        'lock' => '锁定屏幕',
        'sleep' => '让电脑睡眠',
        'shutdown' => '关机',
        'restart' => '重启电脑',
        _ => '电源操作',
      },
      run: (a) async {
        switch ('${a['action']}') {
          case 'lock':
            await Process.run('rundll32.exe', ['user32.dll,LockWorkStation']);
            return '已锁屏';
          case 'sleep':
            await Process.run(
                'rundll32.exe', ['powrprof.dll,SetSuspendState', '0,1,0']);
            return '已进入睡眠';
          case 'shutdown':
            await Process.run('shutdown', ['/s', '/t', '5']);
            return '5 秒后关机（shutdown /a 可取消）';
          case 'restart':
            await Process.run('shutdown', ['/r', '/t', '5']);
            return '5 秒后重启（shutdown /a 可取消）';
          default:
            return '未知操作';
        }
      },
    ),
  ];

  static ToolDef? byName(String name) {
    for (final t in all) {
      if (t.name == name) return t;
    }
    return null;
  }

  static List<Map<String, Object?>> schemas() =>
      all.map((t) => t.toSchema()).toList();

  /// 读取/设置系统音量需要 Core Audio 的 COM 接口，PowerShell 里现声明
  static const String _volGetter = r'''
Add-Type -Language CSharp @"
using System.Runtime.InteropServices;
[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioEndpointVolume {
  int f(); int g(); int h(); int i();
  int SetMasterVolumeLevelScalar(float fLevel, System.Guid pguidEventContext);
  int j();
  int GetMasterVolumeLevelScalar(out float pfLevel);
  int k(); int l(); int m(); int n();
  int SetMute(bool bMute, System.Guid pguidEventContext);
  int GetMute(out bool pbMute);
}
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice { int Activate(ref System.Guid id, int clsCtx, int act, out IAudioEndpointVolume aev); }
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator { int f(); int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint); }
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorComObject { }
public class Audio {
  static IAudioEndpointVolume Vol() {
    IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
    IMMDevice dev = null;
    Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(0, 1, out dev));
    IAudioEndpointVolume epv = null;
    var epvid = typeof(IAudioEndpointVolume).GUID;
    Marshal.ThrowExceptionForHR(dev.Activate(ref epvid, 23, 0, out epv));
    return epv;
  }
  public static float Volume {
    get { float v = -1; Marshal.ThrowExceptionForHR(Vol().GetMasterVolumeLevelScalar(out v)); return v; }
    set { Marshal.ThrowExceptionForHR(Vol().SetMasterVolumeLevelScalar(value, System.Guid.Empty)); }
  }
}
"@
''';

  static Future<String> _ps(String script) async {
    try {
      // 必须显式把输出编码改成 UTF-8。PowerShell 默认按控制台代码页输出
      // （这台机器是 GBK），回到 Dart 就是乱码——而这些文字是要喂给模型的，
      // 乱码等于整个工具白做。实测 system_info 的中文全变成了 "ϵͳ:"。
      final wrapped =
          '[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; '
          r'$OutputEncoding=[System.Text.Encoding]::UTF8; '
          '$script';
      final r = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
         '-Command', wrapped],
        stdoutEncoding: const Utf8Codec(allowMalformed: true),
        stderrEncoding: const Utf8Codec(allowMalformed: true),
      ).timeout(const Duration(seconds: 30));
      final out = (r.stdout as String).trim();
      final err = (r.stderr as String).trim();
      if (out.isEmpty && err.isNotEmpty) return '执行出错：$err';
      if (err.isNotEmpty) return '$out\n（stderr）$err';
      return out.isEmpty ? '（执行完成，无输出）' : out;
    } catch (e) {
      return '执行失败：$e';
    }
  }
}
