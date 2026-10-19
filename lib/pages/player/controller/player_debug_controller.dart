// ignore_for_file: library_private_types_in_public_api

import 'dart:async';

import 'package:kazumi/services/logging/logger.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mobx/mobx.dart';

part 'player_debug_controller.g.dart';

class PlayerDebugController = _PlayerDebugController
    with _$PlayerDebugController;

abstract class _PlayerDebugController with Store {
  /// LogLevel 0: 错误 1: 警告 2: 简略 3: 详细
  int playerLogLevel = 2;

  @observable
  ObservableList<String> playerLog = ObservableList.of([]);
  @observable
  int playerWidth = 0;
  @observable
  int playerHeight = 0;
  @observable
  String playerVideoParams = '';
  @observable
  String playerAudioParams = '';
  @observable
  String playerPlaylist = '';
  @observable
  String playerAudioTracks = '';
  @observable
  String playerVideoTracks = '';
  @observable
  String playerAudioBitrate = '';
  @observable
  String playerVideoBitrate = '';
  @observable
  String playerFps = '';
  @observable
  String playerEstimatedFps = '';

  StreamSubscription<PlayerLog>? playerLogSubscription;
  StreamSubscription<int?>? playerWidthSubscription;
  StreamSubscription<int?>? playerHeightSubscription;
  StreamSubscription<VideoParams>? playerVideoParamsSubscription;
  StreamSubscription<AudioParams>? playerAudioParamsSubscription;
  StreamSubscription<Playlist>? playerPlaylistSubscription;
  StreamSubscription<Track>? playerTracksSubscription;
  StreamSubscription<double?>? playerAudioBitrateSubscription;
  StreamSubscription<double?>? playerVideoBitrateSubscription;

  // 帧率：标称 fps 与实测 estimated-frame-rate 都靠 observeProperty 推送。
  NativePlayer? _fpsPlayer;
  bool _fpsListenerAttached = false;
  final Set<String> _fpsObserved = <String>{};

  Future<void> setup(
    Player player, {
    required bool Function(Player player) isCurrentPlayer,
    required bool playerDebugMode,
  }) async {
    await playerLogSubscription?.cancel();
    if (!isCurrentPlayer(player)) return;
    playerLogSubscription = player.stream.log.listen((event) {
      playerLog.add(event.toString());
      if (playerDebugMode) {
        KazumiLogger().i("MPV: ${event.toString()}", forceLog: true);
      }
    });
    await playerWidthSubscription?.cancel();
    if (!isCurrentPlayer(player)) return;
    playerWidthSubscription = player.stream.width.listen((event) {
      playerWidth = event ?? 0;
    });
    await playerHeightSubscription?.cancel();
    if (!isCurrentPlayer(player)) return;
    playerHeightSubscription = player.stream.height.listen((event) {
      playerHeight = event ?? 0;
    });
    await playerVideoParamsSubscription?.cancel();
    if (!isCurrentPlayer(player)) return;
    playerVideoParamsSubscription = player.stream.videoParams.listen((event) {
      playerVideoParams = event.toString();
    });
    await playerAudioParamsSubscription?.cancel();
    if (!isCurrentPlayer(player)) return;
    playerAudioParamsSubscription = player.stream.audioParams.listen((event) {
      playerAudioParams = event.toString();
    });
    await playerPlaylistSubscription?.cancel();
    if (!isCurrentPlayer(player)) return;
    playerPlaylistSubscription = player.stream.playlist.listen((event) {
      playerPlaylist = event.toString();
    });
    await playerTracksSubscription?.cancel();
    if (!isCurrentPlayer(player)) return;
    playerTracksSubscription = player.stream.track.listen((event) {
      playerAudioTracks = event.audio.toString();
      playerVideoTracks = event.video.toString();
    });
    await playerAudioBitrateSubscription?.cancel();
    if (!isCurrentPlayer(player)) return;
    playerAudioBitrateSubscription = player.stream.audioBitrate.listen((event) {
      playerAudioBitrate = event.toString();
    });
    await playerVideoBitrateSubscription?.cancel();
    if (!isCurrentPlayer(player)) return;
    playerVideoBitrateSubscription = player.stream.videoBitrate.listen((event) {
      playerVideoBitrate = event.toString();
    });

    // 帧率：setup 发生在媒体加载之前，getProperty 此刻拿不到值，
    // 因此全部改用 observeProperty 注册监听，mpv 在媒体加载后自动推送。
    final native = player.platform;
    if (native is NativePlayer && !_fpsListenerAttached) {
      _fpsPlayer = native;
      // 标称帧率：不同 mpv 版本属性名不同（container-fps / fps），两个都监听。
      for (final property in const ['container-fps', 'fps']) {
        try {
          await native.observeProperty(property, (value) async {
            if (!isCurrentPlayer(player)) return;
            final v = value.trim();
            if (v.isNotEmpty && double.tryParse(v) != null) playerFps = v;
          });
          _fpsObserved.add(property);
        } catch (_) {
          // 该属性不受支持，忽略。
        }
      }
      // 实测帧率：mpv 的正式属性名是 estimated-vf-fps，旧名 estimated-frame-rate 一并监听兜底。
      for (final property in const ['estimated-vf-fps', 'estimated-frame-rate']) {
        try {
          await native.observeProperty(property, (value) async {
            if (!isCurrentPlayer(player)) return;
            final v = value.trim();
            if (v.isNotEmpty && double.tryParse(v) != null) {
              playerEstimatedFps = v;
            }
          });
          _fpsObserved.add(property);
        } catch (_) {
          // 该属性不受支持，忽略。
        }
      }
      _fpsListenerAttached = true;
    }
  }

  Future<void> cancel() async {
    // Detach fields before awaiting so a new player cannot lose its listeners.
    final logSubscription = playerLogSubscription;
    final widthSubscription = playerWidthSubscription;
    final heightSubscription = playerHeightSubscription;
    final videoParamsSubscription = playerVideoParamsSubscription;
    final audioParamsSubscription = playerAudioParamsSubscription;
    final playlistSubscription = playerPlaylistSubscription;
    final tracksSubscription = playerTracksSubscription;
    final audioBitrateSubscription = playerAudioBitrateSubscription;
    final videoBitrateSubscription = playerVideoBitrateSubscription;

    playerLogSubscription = null;
    playerWidthSubscription = null;
    playerHeightSubscription = null;
    playerVideoParamsSubscription = null;
    playerAudioParamsSubscription = null;
    playerPlaylistSubscription = null;
    playerTracksSubscription = null;
    playerAudioBitrateSubscription = null;
    playerVideoBitrateSubscription = null;
    _fpsListenerAttached = false;
    final fpsPlayer = _fpsPlayer;
    _fpsPlayer = null;
    final fpsObserved = _fpsObserved.toList();
    _fpsObserved.clear();

    await logSubscription?.cancel();
    await widthSubscription?.cancel();
    await heightSubscription?.cancel();
    await videoParamsSubscription?.cancel();
    await audioParamsSubscription?.cancel();
    await playlistSubscription?.cancel();
    await tracksSubscription?.cancel();
    await audioBitrateSubscription?.cancel();
    await videoBitrateSubscription?.cancel();
    for (final property in fpsObserved) {
      try {
        await fpsPlayer?.unobserveProperty(property);
      } catch (_) {}
    }
  }
}
