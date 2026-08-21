/// OpenAI 兼容的流式对话客户端。
///
/// 只用 SSE 流式：非流式要等整段生成完才有反馈，桌面侧边栏里体感很差。
/// 服务端不支持流式时会直接返回一整个 JSON，这里也能兜住（见 _parseWhole）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/logger.dart';
import '../model/ai_settings.dart';

class ChatMessage {
  ChatMessage({
    required this.role,
    required this.content,
    this.error = false,
    this.toolCalls,
    this.toolCallId,
    this.toolName,
  });

  /// user / assistant / system / tool
  final String role;
  String content;

  /// 标记为错误气泡，UI 里用红色显示
  bool error;

  /// assistant 发起的工具调用
  List<Map<String, Object?>>? toolCalls;

  /// role == 'tool' 时，对应哪一次调用
  final String? toolCallId;
  final String? toolName;

  /// 界面上显示的替代文本。附件会把整篇文件内容拼进 content 发给模型，
  /// 但气泡里只该显示文件名，否则一条消息糊满整个侧边栏。
  String? displayOverride;

  Map<String, Object?> toJson() => {
        'role': role,
        'content': content,
        if (toolCalls != null) 'tool_calls': toolCalls,
        if (toolCallId != null) 'tool_call_id': toolCallId,
        if (toolName != null) 'name': toolName,
      };

  /// 发给模型时用的形状。tool_calls 存在时 content 必须允许为空。
  Map<String, Object?> toWire() {
    if (role == 'tool') {
      return {'role': 'tool', 'tool_call_id': toolCallId, 'content': content};
    }
    return {
      'role': role,
      'content': content,
      if (toolCalls != null && toolCalls!.isNotEmpty) 'tool_calls': toolCalls,
    };
  }

  static ChatMessage fromJson(Map<String, Object?> j) => ChatMessage(
        role: j['role'] as String? ?? 'user',
        content: j['content'] as String? ?? '',
        error: j['error'] == true,
        toolCalls: (j['tool_calls'] as List?)
            ?.whereType<Map>()
            .map((e) => e.cast<String, Object?>())
            .toList(),
        toolCallId: j['tool_call_id'] as String?,
        toolName: j['name'] as String?,
      );
}

class ChatClient {
  http.Client? _client;

  bool get busy => _client != null;

  /// 发起一次对话。[onDelta] 每收到一段增量文本回调一次。
  /// [tools] 非空时开启工具调用；模型要求调用工具会通过 [onToolCalls] 交回，
  /// 由调用方执行后把结果作为 role=tool 的消息追加进 history 再调一次。
  /// 返回完整回复；出错时抛异常（调用方负责显示）。
  Future<String> send({
    required AiSettings cfg,
    required List<ChatMessage> history,
    required void Function(String delta) onDelta,
    List<Map<String, Object?>>? tools,
    void Function(List<Map<String, Object?>> calls)? onToolCalls,
  }) async {
    final uri = cfg.chatUri();
    if (uri == null) throw const FormatException('Base URL 不合法');

    // 只带最近 maxHistory 条，避免上下文越滚越长
    final trimmed = history.length > cfg.maxHistory
        ? history.sublist(history.length - cfg.maxHistory)
        : history;

    final messages = <Map<String, Object?>>[
      if (cfg.systemPrompt.trim().isNotEmpty)
        {'role': 'system', 'content': cfg.systemPrompt},
      for (final m in trimmed)
        if (!m.error) m.toWire(),
    ];

    final req = http.Request('POST', uri)
      ..headers.addAll({
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${cfg.apiKey}',
        'Accept': 'text/event-stream',
      })
      ..body = jsonEncode({
        'model': cfg.model,
        'messages': messages,
        'temperature': cfg.temperature,
        'stream': true,
        if (tools != null && tools.isNotEmpty) 'tools': tools,
        if (tools != null && tools.isNotEmpty) 'tool_choice': 'auto',
      });

    final client = http.Client();
    _client = client;
    final buffer = StringBuffer();
    final pendingCalls = <Map<String, Object?>>[];
    try {
      final res = await client.send(req);

      if (res.statusCode < 200 || res.statusCode >= 300) {
        final body = await res.stream.bytesToString();
        throw HttpFailure(res.statusCode, _briefError(body));
      }

      // 服务端可能忽略 stream=true 直接返回整个 JSON，先看 content-type
      final ctype = res.headers['content-type'] ?? '';
      if (!ctype.contains('event-stream')) {
        final body = await res.stream.bytesToString();
        final whole = _parseWhole(body);
        buffer.write(whole);
        onDelta(whole);
        return buffer.toString();
      }

      await for (final line in res.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload.isEmpty) continue;
        if (payload == '[DONE]') break;
        try {
          final obj = jsonDecode(payload) as Map<String, Object?>;
          final choices = obj['choices'] as List?;
          if (choices == null || choices.isEmpty) continue;
          final delta = (choices.first as Map)['delta'];
          if (delta is! Map) continue;

          final text = delta['content'] as String?;
          if (text != null && text.isNotEmpty) {
            buffer.write(text);
            onDelta(text);
          }

          // 工具调用是分片下发的：同一个 index 的 arguments 要拼起来
          final tc = delta['tool_calls'];
          if (tc is List) {
            for (final raw in tc) {
              if (raw is! Map) continue;
              final idx = (raw['index'] as num?)?.toInt() ?? 0;
              while (pendingCalls.length <= idx) {
                pendingCalls.add({
                  'id': '',
                  'type': 'function',
                  'function': {'name': '', 'arguments': ''}
                });
              }
              final slot = pendingCalls[idx];
              if (raw['id'] != null) slot['id'] = raw['id'];
              final fn = raw['function'];
              if (fn is Map) {
                final f = slot['function'] as Map<String, Object?>;
                if (fn['name'] != null) f['name'] = fn['name'];
                if (fn['arguments'] != null) {
                  f['arguments'] = '${f['arguments']}${fn['arguments']}';
                }
              }
            }
          }
        } catch (e) {
          // 单行解析失败不该中断整个流，但要记下来——
          // AI 返回格式跑偏了，插件作者改了 API 之类，不报就永远不知道
          Log.w('ai', '流式响应行解析失败: $e');
        }
      }
      if (pendingCalls.isNotEmpty && onToolCalls != null) {
        onToolCalls(pendingCalls);
      }
      return buffer.toString();
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  /// 中断当前请求
  void abort() {
    _client?.close();
    _client = null;
  }

  static String _parseWhole(String body) {
    try {
      final obj = jsonDecode(body) as Map<String, Object?>;
      final choices = obj['choices'] as List?;
      if (choices != null && choices.isNotEmpty) {
        final msg = (choices.first as Map)['message'];
        if (msg is Map) return msg['content'] as String? ?? '';
      }
    } catch (_) {}
    return body;
  }

  /// 把服务端的错误体压成一行，太长会把侧边栏撑爆
  static String _briefError(String body) {
    try {
      final obj = jsonDecode(body) as Map<String, Object?>;
      final err = obj['error'];
      if (err is Map) {
        return '${err['message'] ?? err}';
      }
    } catch (_) {}
    final one = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length > 300 ? '${one.substring(0, 300)}…' : one;
  }
}

class HttpFailure implements Exception {
  HttpFailure(this.status, this.message);
  final int status;
  final String message;

  @override
  String toString() {
    // 常见错误给出可操作的提示，而不是丢一个裸状态码
    final hint = switch (status) {
      401 => '（API Key 不对或没生效）',
      403 => '（没有权限，检查 Key 的可用模型）',
      404 => '（地址不对，检查 Base URL 是否该带 /v1）',
      429 => '（触发限流，稍后再试）',
      _ => '',
    };
    return 'HTTP $status $hint\n$message';
  }
}
