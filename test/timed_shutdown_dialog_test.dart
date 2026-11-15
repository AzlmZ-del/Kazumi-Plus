import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/dialog/kazumi_toast_host.dart';
import 'package:kazumi/bean/widget/scroll_field.dart';
import 'package:kazumi/bean/widget/state_presentation.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/services/player/timed_shutdown_service.dart';

Semantics _field(WidgetTester tester, String label) => tester.widget<Semantics>(
  find.byWidgetPredicate(
    (widget) => widget is Semantics && widget.properties.label == label,
  ),
);

StateActionButton _startButton(WidgetTester tester) =>
    tester.widget<StateActionButton>(find.byType(StateActionButton));

Future<void> _openDialog(
  WidgetTester tester, {
  VoidCallback? onExpired,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: rootNavigatorKey,
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      navigatorObservers: [KazumiDialog.observer],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: true,
        ),
        child: FToastBuilder()(
          context,
          KazumiToastHost(
            key: toastAnchorKey,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
      home: const Scaffold(body: Text('home')),
    ),
  );
  await tester.pumpAndSettle();
  TimedShutdownService.showCustomTimerDialog(onExpired: onExpired);
  await tester.pumpAndSettle();
}

Future<void> _closeAndDrain(WidgetTester tester) async {
  TimedShutdownService().cancel();
  KazumiDialog.dismiss();
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => TimedShutdownService().cancel());
  tearDown(() => TimedShutdownService().cancel());

  testWidgets(
    'zero duration is disabled and positive selection enables start',
    (tester) async {
      await _openDialog(tester);
      expect(find.byType(ScrollField), findsNWidgets(2));
      expect(_field(tester, '小时').properties.value, '00');
      expect(_field(tester, '分钟').properties.value, '00');
      expect(_startButton(tester).onPressed, isNull);
      _field(tester, '分钟').properties.onIncrease!();
      await tester.pump();
      expect(_startButton(tester).onPressed, isNotNull);
      _field(tester, '分钟').properties.onDecrease!();
      await tester.pump();
      expect(_startButton(tester).onPressed, isNull);
      expect(TimedShutdownService().isActive, isFalse);
      await _closeAndDrain(tester);
    },
  );

  testWidgets('one minute starts the timer and keeps its expiry callback', (
    tester,
  ) async {
    var expirations = 0;
    await _openDialog(tester, onExpired: () => expirations++);
    _field(tester, '分钟').properties.onIncrease!();
    await tester.pump();
    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();
    expect(find.byType(ScrollField), findsNothing);
    expect(TimedShutdownService().setMinutes, 1);
    expect(TimedShutdownService().isActive, isTrue);
    expect(expirations, 0);
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(expirations, 1);
    expect(find.text('定时时间已到，视频已暂停'), findsOneWidget);
    await _closeAndDrain(tester);
  });

  testWidgets('wrapping both fields selects 24 hours 59 minutes', (
    tester,
  ) async {
    await _openDialog(tester);
    _field(tester, '小时').properties.onDecrease!();
    _field(tester, '分钟').properties.onDecrease!();
    await tester.pump();
    expect(_field(tester, '小时').properties.value, '24');
    expect(_field(tester, '分钟').properties.value, '59');
    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();
    expect(TimedShutdownService().setMinutes, 24 * 60 + 59);
    expect(TimedShutdownService().isActive, isTrue);
    await _closeAndDrain(tester);
  });

  testWidgets('cancel preserves an existing timer', (tester) async {
    final timer = TimedShutdownService();
    timer.start(30);
    await _openDialog(tester);
    _field(tester, '分钟').properties.onIncrease!();
    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(ScrollField), findsNothing);
    expect(timer.setMinutes, 30);
    expect(timer.isActive, isTrue);
    await _closeAndDrain(tester);
  });

  testWidgets('stale start callback cannot clear an existing timer at zero', (
    tester,
  ) async {
    final timer = TimedShutdownService();
    timer.start(30);
    await _openDialog(tester);
    _field(tester, '分钟').properties.onIncrease!();
    await tester.pump();
    final confirm = _startButton(tester).onPressed!;
    _field(tester, '分钟').properties.onDecrease!();
    await tester.pump();
    expect(_startButton(tester).onPressed, isNull);
    confirm();
    await tester.pumpAndSettle();
    expect(find.byType(ScrollField), findsNWidgets(2));
    expect(timer.setMinutes, 30);
    expect(timer.isActive, isTrue);
    expect(find.text('请选择有效的时间'), findsOneWidget);
    await _closeAndDrain(tester);
  });

  testWidgets(
    'large text in a small window remains scrollable without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 240);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _openDialog(tester, textScale: 3);
      expect(find.byType(ScrollField), findsNWidgets(2));
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _closeAndDrain(tester);
    },
  );
}
