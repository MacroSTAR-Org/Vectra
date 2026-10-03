/// 配置注册与绑定的基础类型。
///
/// 绑定只负责内存中的配置目标、类型校验和变更记录，不直接执行文件 IO。
library;

enum ConfigScope { app, ai, card }

enum ConfigValueType { boolean, number, text, select, json }

class ConfigOption<T> {
  const ConfigOption({required this.value, required this.label});

  final T value;
  final String label;
}

class ConfigSpec<T> {
  const ConfigSpec({
    required this.key,
    required this.scope,
    required this.type,
    required this.read,
    required this.write,
    this.defaultValue,
    this.min,
    this.max,
    this.step,
    this.options = const [],
  });

  final String key;
  final ConfigScope scope;
  final ConfigValueType type;
  final T Function() read;
  final void Function(T value) write;
  final T? defaultValue;
  final double? min;
  final double? max;
  final double? step;
  final List<ConfigOption<T>> options;
}

class ConfigChange {
  const ConfigChange({
    required this.key,
    required this.scope,
    required this.previous,
    required this.value,
  });

  final String key;
  final ConfigScope scope;
  final Object? previous;
  final Object? value;
}

class ConfigValidationException implements Exception {
  const ConfigValidationException(this.key, this.message);

  final String key;
  final String message;

  @override
  String toString() => 'Invalid configuration "$key": $message';
}

class ConfigBinding<T> {
  ConfigBinding(this.spec);

  final ConfigSpec<T> spec;

  T get value => spec.read();

  void set(T next) {
    _validate(next);
    spec.write(next);
  }

  void _validate(T next) {
    switch (spec.type) {
      case ConfigValueType.boolean:
        if (next is! bool) {
          throw ConfigValidationException(spec.key, 'expected a boolean');
        }
      case ConfigValueType.number:
        if (next is! num) {
          throw ConfigValidationException(spec.key, 'expected a number');
        }
        final number = next.toDouble();
        if (spec.min != null && number < spec.min!) {
          throw ConfigValidationException(spec.key, 'value is below the minimum');
        }
        if (spec.max != null && number > spec.max!) {
          throw ConfigValidationException(spec.key, 'value is above the maximum');
        }
        if (spec.step != null && spec.step! > 0 && spec.min != null) {
          final steps = (number - spec.min!) / spec.step!;
          if ((steps - steps.round()).abs() > 0.000001) {
            throw ConfigValidationException(spec.key, 'value does not match the step');
          }
        }
      case ConfigValueType.text:
        if (next is! String) {
          throw ConfigValidationException(spec.key, 'expected text');
        }
      case ConfigValueType.select:
        if (spec.options.isNotEmpty &&
            !spec.options.any((option) => option.value == next)) {
          throw ConfigValidationException(spec.key, 'value is not an available option');
        }
      case ConfigValueType.json:
        break;
    }
  }
}

class ConfigRegistry {
  final Map<String, ConfigBinding<Object?>> _bindings = {};

  Iterable<ConfigBinding<Object?>> get bindings => _bindings.values;

  ConfigBinding<T> register<T>(ConfigSpec<T> spec) {
    if (_bindings.containsKey(spec.key)) {
      throw ArgumentError.value(spec.key, 'key', 'configuration key is already registered');
    }
    final binding = ConfigBinding<T>(spec);
    _bindings[spec.key] = binding as ConfigBinding<Object?>;
    return binding;
  }

  ConfigBinding<T>? find<T>(String key) {
    final binding = _bindings[key];
    if (binding == null) return null;
    return binding as ConfigBinding<T>;
  }

  void clear() => _bindings.clear();
}
