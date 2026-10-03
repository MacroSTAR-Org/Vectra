/// 配置变更协调器。
///
/// 统一负责注册、内存更新、去抖持久化和宿主刷新通知；Store 仍是唯一文件持久化边界。
library;

import 'dart:async';

import '../store/store.dart';
import 'config_binding.dart';

class ConfigCoordinator {
  ConfigCoordinator({
    required this.store,
    required this.state,
    required this.onChanged,
    this.onHotkeyChanged,
  });

  final Store store;
  final AppState state;
  final void Function() onChanged;
  final void Function()? onHotkeyChanged;
  final ConfigRegistry registry = ConfigRegistry();

  final List<ConfigChange> _pending = [];
  Timer? _notifyTimer;

  List<ConfigChange> get pendingChanges => List.unmodifiable(_pending);
  bool get isDirty => _pending.isNotEmpty;

  ConfigBinding<T> register<T>(ConfigSpec<T> spec) => registry.register(spec);

  bool set<T>(ConfigBinding<T> binding, T value, {bool hotkey = false}) {
    final previous = binding.value;
    if (previous == value) return false;
    binding.set(value);
    _pending.add(ConfigChange(
      key: binding.spec.key,
      scope: binding.spec.scope,
      previous: previous,
      value: value,
    ));
    store.save(state);
    if (hotkey) onHotkeyChanged?.call();
    _notifyTimer?.cancel();
    _notifyTimer = Timer(const Duration(milliseconds: 260), () {
      _notifyTimer = null;
      if (isDirty) onChanged();
    });
    return true;
  }

  void commit() {
    store.save(state);
    _notifyTimer?.cancel();
    _notifyTimer = Timer(const Duration(milliseconds: 260), () {
      _notifyTimer = null;
      onChanged();
    });
  }

  void markCommitted() => _pending.clear();

  Future<void> commitNow() async {
    _notifyTimer?.cancel();
    await store.saveNow(state);
    _pending.clear();
  }

  void dispose() {
    _notifyTimer?.cancel();
    if (isDirty) onChanged();
  }
}
