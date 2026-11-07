import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:kazumi/bean/dialog/dialog.dart'
    show KazumiDialog, KazumiDialogHandle;
import 'package:kazumi/bean/widget/loading_indicator.dart';

mixin KazumiDialogOwner<T extends StatefulWidget> on State<T> {
  late final dialogs = KazumiDialogController(context: () => context)
    ..addListener(_refreshDialogState);

  void _refreshDialogState() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    dialogs.removeListener(_refreshDialogState);
    dialogs.dispose();
    super.dispose();
  }
}

class KazumiDialogController extends ChangeNotifier {
  KazumiDialogController({BuildContext Function()? context})
      : _context = context;

  final BuildContext Function()? _context;
  KazumiDialogTask? _current;
  bool _disposed = false;

  bool get isRunning => _current?._isActive ?? false;

  /// await 会把取消异常穿过任务体；换掉或销毁持有者不会触发 [onCancelled]，
  /// 只有用户主动取消才会在清理之后调用它。
  Future<void> run(
    Future<void> Function(KazumiDialogTask task) action, {
    String? errorMessage,
    void Function(Object error, StackTrace stackTrace)? onError,
    VoidCallback? onCancelled,
  }) async {
    if (_disposed || !(_context?.call().mounted ?? true)) return;
    cancel();
    final task = _current = KazumiDialogTask._(this);
    notifyListeners();
    try {
      await action(task);
    } on _DialogTaskCancelled {
      if (!_disposed && identical(_current, task)) onCancelled?.call();
    } catch (error, stackTrace) {
      if (!task._isActive) return;
      if (onError != null) {
        onError(error, stackTrace);
      } else if (errorMessage != null) {
        KazumiDialog.showToast(message: errorMessage);
      } else {
        rethrow;
      }
    } finally {
      task._dialog?.dismiss();
      if (identical(_current, task)) {
        _current = null;
        if (!_disposed) notifyListeners();
      }
    }
  }

  void cancel() {
    _current?.cancel();
  }

  void _notifyCancellation() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}

class KazumiDialogTask {
  KazumiDialogTask._(this._owner);

  final KazumiDialogController _owner;
  final _cancelled = Completer<void>();
  KazumiDialogHandle<dynamic>? _dialog;
  FutureOr<void> Function()? _onCancel;
  Future<void>? _cancelCleanup;

  bool get _isActive =>
      !_cancelled.isCompleted &&
      !_owner._disposed &&
      identical(_owner._current, this) &&
      (_owner._context?.call().mounted ?? true);

  void withContext(void Function(BuildContext context) action) {
    _checkActive();
    final context = _owner._context?.call();
    if (context == null) {
      throw StateError('This dialog task has no widget owner.');
    }
    action(context);
  }

  void _checkActive() {
    if (!_isActive) throw const _DialogTaskCancelled();
  }

  void cancel() {
    if (_cancelled.isCompleted) return;
    _cancelled.complete();
    _owner._notifyCancellation();
    _dialog?.dismiss();
    final onCancel = _onCancel;
    if (onCancel != null) {
      _cancelCleanup = Future<void>.sync(onCancel).catchError((Object error) {
        debugPrint('Kazumi Dialog Error: Task cancellation failed: $error');
      });
    }
  }

  /// 只停止等待，不停底层操作；迟到的错误仍会被消费掉。
  Future<T> wait<T>(Future<T> future) async {
    final result = await Future.any<T>([
      future,
      _cancelled.future.then<T>((_) => throw const _DialogTaskCancelled()),
    ]);
    _checkActive();
    return result;
  }

  Future<T> loading<T>({
    required Future<T> Function() action,
    String? title,
    String? message,
    bool barrierDismissible = false,
    FutureOr<void> Function()? onCancel,
    WidgetBuilder? builder,
  }) async {
    _checkActive();
    final dialog = KazumiDialogHandle<void>();
    _dialog = dialog;
    _onCancel = onCancel;
    final closed = KazumiDialog.show<void>(
      context: _owner._context?.call(),
      handle: dialog,
      clickMaskDismiss: barrierDismissible,
      builder: builder ??
          (_) => _LoadingDialog(title: title, message: message),
    );
    unawaited(closed.then((_) {
      if (identical(_dialog, dialog)) cancel();
    }));
    late T result;
    try {
      if (!dialog.isActive) cancel();
      _checkActive();
      result = await wait(action());
    } finally {
      // 系统返回手势可能先于对话框 Future 完成，此时也要按取消处理。
      if (!dialog.isActive) cancel();
      _dialog = null;
      _onCancel = null;
      dialog.dismiss();
      await _cancelCleanup;
      _checkActive();
    }
    return result;
  }

  /// 点遮罩关闭算取消整个流程；明确返回 false 则仍是一个结果值。
  Future<T> show<T extends Object>({
    required WidgetBuilder builder,
    bool clickMaskDismiss = true,
  }) async {
    _checkActive();
    final dialog = KazumiDialogHandle<T>();
    _dialog = dialog;
    try {
      final result = await wait(KazumiDialog.show<T>(
        context: _owner._context?.call(),
        handle: dialog,
        clickMaskDismiss: clickMaskDismiss,
        builder: builder,
      ));
      if (result == null) {
        cancel();
        throw const _DialogTaskCancelled();
      }
      return result;
    } finally {
      _dialog = null;
      dialog.dismiss();
    }
  }
}

class _DialogTaskCancelled implements Exception {
  const _DialogTaskCancelled();
}

class _LoadingDialog extends StatelessWidget {
  const _LoadingDialog({this.title, this.message});

  final String? title;
  final String? message;

  @override
  Widget build(BuildContext context) => Center(
        child: Card(
          elevation: 8,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const LoadingIndicator(),
                const SizedBox(height: 16),
                if (title != null) ...[
                  Text(
                    title!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
                Text(
                  message ?? 'Loading...',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16),
                ),
              ],
            ),
          ),
        ),
      );
}
