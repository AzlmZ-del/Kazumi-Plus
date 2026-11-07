/// 持有一条可被替换的序列中「当前有效」的那个异步操作。
///
/// 开启新会话会让上一个失效。[cancel] 让当前会话失效但持有者仍可复用，
/// [close] 则让持有者永久拒绝新任务。
final class AsyncSessionOwner {
  int _version = 0;
  bool _closed = false;

  bool get isClosed => _closed;

  AsyncSession begin() {
    if (_closed) {
      throw StateError('Cannot begin a session after the owner is closed.');
    }
    return AsyncSession._(this, ++_version);
  }

  void cancel() {
    if (!_closed) {
      _version++;
    }
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _version++;
  }

  bool _owns(AsyncSession session) {
    return !_closed &&
        identical(session._owner, this) &&
        session._version == _version;
  }
}

final class AsyncSession {
  const AsyncSession._(this._owner, this._version);

  final AsyncSessionOwner _owner;
  final int _version;

  bool get isActive => _owner._owns(this);

  bool get isStale => !isActive;
}
