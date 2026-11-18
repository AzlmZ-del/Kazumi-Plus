import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/bean/settings/network_mirror_settings.dart';
import 'package:kazumi/services/network/acceleration_mode.dart';
import 'package:kazumi/services/storage/storage.dart';

enum _Mode implements AccelerationMode {
  first,
  second;

  @override
  String get label => '选项 $name';

  @override
  String get description => '描述 $name';
}

void main() {
  testWidgets('option title uses titleMedium so it outweighs the subtitle', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => selectAccelerationMode<_Mode>(
                context,
                title: '测试',
                current: _Mode.first,
                modes: _Mode.values,
                setting: SettingsKeys.rulesMirror,
                probe: (onResult, {bool force = false}) async {
                  for (final mode in _Mode.values) {
                    onResult(
                      AccelerationProbe(
                        mode: mode,
                        label: '396 ms',
                        latencyMillis: 396,
                      ),
                    );
                  }
                },
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final theme = Theme.of(tester.element(find.text('测试')));
    final title = tester.widget<Text>(find.text('选项 first'));
    final subtitle = tester.widget<Text>(find.textContaining('描述 first'));

    // 标题取 titleMedium；bodyLarge 是 w400，会和外层卡片正文同重、没有层次。
    expect(title.style?.fontSize, theme.textTheme.titleMedium?.fontSize);
    expect(title.style?.fontWeight, theme.textTheme.titleMedium?.fontWeight);
    expect(subtitle.style?.fontSize, theme.textTheme.bodySmall?.fontSize);

    // 主标题必须比描述更重，否则「主副」只是字号差。
    expect(
      title.style!.fontWeight!.index,
      greaterThan(subtitle.style!.fontWeight!.index),
    );

    final size = tester.getSize(find.byType(RadioListTile<_Mode>).first);
    // ignore: avoid_print
    print('tile height=${size.height}');
    expect(size.height, lessThan(72));
    expect(size.height, greaterThanOrEqualTo(48));
  });
}
