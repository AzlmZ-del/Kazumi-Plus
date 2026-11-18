import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/bean/settings/network_mirror_settings.dart';
import 'package:kazumi/services/network/acceleration_mode.dart';
import 'package:kazumi/services/storage/storage.dart';

enum _Mode implements AccelerationMode {
  first,
  second;

  @override
  String get label => name;

  @override
  String get description => '描述-$name';
}

void main() {
  testWidgets('a dialog without a probe never shows 测速中', (tester) async {
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
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();

    // 没传 probe 时应完全没有测速痕迹。
    expect(find.text('测试'), findsOneWidget);
    expect(find.textContaining('测速中'), findsNothing);
    expect(find.byIcon(Icons.bolt_rounded), findsNothing);
    // 两条选项都应只显示自身描述。
    expect(find.text('描述-first'), findsOneWidget);
    expect(find.text('描述-second'), findsOneWidget);
  });
}
