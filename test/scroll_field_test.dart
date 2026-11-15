import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/bean/widget/scroll_field.dart';

Semantics _fieldSemantics(WidgetTester tester) => tester.widget<Semantics>(
  find.byWidgetPredicate(
    (widget) => widget is Semantics && widget.properties.label == '分钟',
  ),
);

Future<void> _mountField(
  WidgetTester tester, {
  required ValueChanged<int> onChanged,
  int itemCount = 60,
  bool disableAnimations = false,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: disableAnimations,
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Center(
          child: ScrollField(
            itemCount: itemCount,
            semanticLabel: '分钟',
            onChanged: onChanged,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final count in [25, 60]) {
    testWidgets('$count options start at zero with wrapping semantics', (
      tester,
    ) async {
      final changes = <int>[];
      await _mountField(tester, itemCount: count, onChanged: changes.add);
      final properties = _fieldSemantics(tester).properties;
      expect(properties.value, '00');
      expect(properties.increasedValue, '01');
      expect(properties.decreasedValue, '${count - 1}');
      expect(properties.onIncrease, isNotNull);
      expect(properties.onDecrease, isNotNull);
      expect(changes, isEmpty);
    });
  }

  testWidgets(
    'accessibility steps wrap and reduced motion changes immediately',
    (tester) async {
      final changes = <int>[];
      await _mountField(
        tester,
        onChanged: changes.add,
        disableAnimations: true,
      );
      _fieldSemantics(tester).properties.onDecrease!();
      await tester.pump();
      expect(_fieldSemantics(tester).properties.value, '59');
      _fieldSemantics(tester).properties.onIncrease!();
      await tester.pump();
      expect(_fieldSemantics(tester).properties.value, '00');
      expect(changes, [59, 0]);
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  testWidgets('rapid steps accumulate while animation is running', (
    tester,
  ) async {
    final changes = <int>[];
    await _mountField(tester, onChanged: changes.add);
    final increase = _fieldSemantics(tester).properties.onIncrease!;
    increase();
    increase();
    increase();
    await tester.pumpAndSettle();
    expect(_fieldSemantics(tester).properties.value, '03');
    expect(changes.last, 3);
  });

  testWidgets('keyboard focus supports up and down steps', (tester) async {
    final changes = <int>[];
    await _mountField(tester, onChanged: changes.add, disableAnimations: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_fieldSemantics(tester).properties.value, '01');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(_fieldSemantics(tester).properties.value, '00');
    expect(changes, [1, 0]);
  });

  testWidgets('mouse drag snaps exactly to an item', (tester) async {
    final changes = <int>[];
    await _mountField(tester, onChanged: changes.add);
    await tester.drag(
      find.byType(ScrollField),
      const Offset(0, -95),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    final list = tester.widget<ListView>(find.byType(ListView));
    final page = list.controller!.offset / list.itemExtent!;
    expect(page, closeTo(page.roundToDouble(), 0.001));
    expect(changes, isNotEmpty);
    expect(int.parse(_fieldSemantics(tester).properties.value!), changes.last);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a nearby number selects it', (tester) async {
    final changes = <int>[];
    await _mountField(tester, onChanged: changes.add);
    await tester.tap(find.text('01'));
    await tester.pumpAndSettle();
    expect(_fieldSemantics(tester).properties.value, '01');
    expect(changes.last, 1);
  });

  testWidgets('large system text is clamped without layout exceptions', (
    tester,
  ) async {
    await _mountField(tester, onChanged: (_) {}, textScale: 3);
    final scaler = MediaQuery.textScalerOf(tester.element(find.text('00')));
    expect(scaler.scale(10), closeTo(13, 0.001));
    expect(tester.getSize(find.byType(ScrollField)), const Size(100, 120));
    expect(tester.takeException(), isNull);
  });
}
