import 'package:flutter_test/flutter_test.dart';

import 'package:vectra/config/config_binding.dart';

void main() {
  test('binding validates and writes typed values', () {
    var value = 10;
    final binding = ConfigBinding<int>(ConfigSpec<int>(
      key: 'settings.gridCell',
      scope: ConfigScope.app,
      type: ConfigValueType.number,
      min: 8,
      max: 20,
      step: 2,
      read: () => value,
      write: (next) => value = next,
    ));

    binding.set(14);
    expect(value, 14);
    expect(() => binding.set(15), throwsA(isA<ConfigValidationException>()));
    expect(() => binding.set(22), throwsA(isA<ConfigValidationException>()));
  });

  test('select binding rejects values outside registered options', () {
    var value = 'auto';
    final binding = ConfigBinding<String>(ConfigSpec<String>(
      key: 'settings.updateSource',
      scope: ConfigScope.app,
      type: ConfigValueType.select,
      options: const [
        ConfigOption(value: 'auto', label: '自动'),
        ConfigOption(value: 'github', label: 'GitHub'),
      ],
      read: () => value,
      write: (next) => value = next,
    ));

    binding.set('github');
    expect(value, 'github');
    expect(() => binding.set('unknown'),
        throwsA(isA<ConfigValidationException>()));
  });

  test('registry rejects duplicate keys', () {
    final registry = ConfigRegistry();
    ConfigSpec<bool> spec(bool value) => ConfigSpec<bool>(
          key: 'settings.enabled',
          scope: ConfigScope.app,
          type: ConfigValueType.boolean,
          read: () => value,
          write: (_) {},
        );

    registry.register(spec(true));
    expect(() => registry.register(spec(false)), throwsArgumentError);
  });
}
