import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

import 'package:kazumi/bean/dialog/image_save_sheet.dart';
import 'package:kazumi/bean/widget/loading_indicator.dart';
import 'package:kazumi/bean/widget/media_error_widget.dart';
import 'package:kazumi/services/network/image_saver.dart';
import 'package:kazumi/utils/device.dart';

/// 双击的缩放循环：整图 ⇄ 原尺寸。
///
/// photo_view 默认是 整图 → 铺满 → 原尺寸 → 整图 三步循环，中间那一档
/// 会裁掉竖图上下大截，对看图没有意义。这里收成两步：没放大就跳到原尺寸
/// （1 图片像素 = 1 逻辑像素），已放大就收回整图。
PhotoViewScaleState nextDoubleTapScaleState(PhotoViewScaleState actual) {
  if (actual == PhotoViewScaleState.initial) {
    return PhotoViewScaleState.originalSize;
  }
  return PhotoViewScaleState.initial;
}

class ImageViewerRouteArgs {
  ImageViewerRouteArgs({
    required List<String> imageUrls,
    this.initialIndex = 0,
    this.heroTag,
    this.fileBaseName,
  }) : imageUrls = List.unmodifiable(imageUrls);

  final List<String> imageUrls;
  final int initialIndex;
  final Object? heroTag;
  final String? fileBaseName;
}

class ImageViewer extends StatefulWidget {
  static const String routePath = '/image-preview';

  final List<String> imageUrls;
  final int initialIndex;
  final Object? heroTag;

  /// 长按保存时的文件名（不含扩展名）。为空时从图片 URL 推导。
  final String? fileBaseName;

  ImageViewer({
    super.key,
    required List<String> imageUrls,
    this.initialIndex = 0,
    this.heroTag,
    this.fileBaseName,
  }) : imageUrls = List.unmodifiable(imageUrls);

  static Object heroTagFor(String imageUrl, int index) => '$imageUrl-$index';

  static Future<void> show(
    BuildContext context, {
    required List<String> imageUrls,
    int initialIndex = 0,
    Object? heroTag,
    String? fileBaseName,
  }) async {
    if (imageUrls.isEmpty) return;

    final index = initialIndex.clamp(0, imageUrls.length - 1);
    final effectiveHeroTag = heroTag ??
        (imageUrls.length > 1
            ? ImageViewer.heroTagFor(imageUrls[index], index)
            : imageUrls[index]);
    await context.pushNamed(
      routePath,
      arguments: ImageViewerRouteArgs(
        imageUrls: imageUrls,
        initialIndex: index,
        heroTag: effectiveHeroTag,
        fileBaseName: fileBaseName,
      ),
    );
  }

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> {
  late final PhotoViewController _photoViewController;
  late final PhotoViewScaleStateController _scaleStateController;
  late final PageController _pageController;
  late int _currentIndex;
  final Map<int, PhotoViewController> _galleryControllers = {};
  final Map<int, PhotoViewScaleStateController> _galleryScaleStateControllers =
      {};
  final Map<int, double?> _initialScales = {};

  static const double _wheelScaleStep = 1.1;

  static const double _minScaleFactor = 1.0;

  static const double _maxScaleFactor = 6.0;

  /// 防止一次点击同时触发「立即关闭」与手势回退，重复 pop 会把下层页面也带走。
  bool _closing = false;

  /// 判定「轻点」的最大位移（逻辑像素），超过就当成拖拽或翻页滑动。
  static const double _tapSlop = 12.0;

  /// 判定「轻点」的最大按住时长，超过就当成即将长按。
  static const int _tapMaxMillis = 400;

  Offset? _pointerDownPosition;
  int _pointerDownMillis = 0;

  /// 这一次按压过程中同时按下过的最大手指数。
  /// 多指（捏合缩放）抬起时不能当成轻点，否则刚缩回整图就被关掉。
  int _pointerPeak = 0;
  int _pointerActive = 0;

  /// 点击图片之外的黑色区域收起预览。
  ///
  /// 不用 GestureDetector.onTap：那会与 photo_view 内部的手势识别器抢，
  /// 双击缩放会时灵时不灵。指针通道只观察不争夺，抬手时再自己判定。
  ///
  /// **必须点在图片范围之外**才算数：点在图片上要留给双击缩放，
  /// 之前不限位置，导致点一下图整页就关了，双击永远没机会发生。
  void _handlePointerDown(PointerDownEvent event) {
    _pointerActive++;
    if (_pointerActive > _pointerPeak) _pointerPeak = _pointerActive;
    if (_pointerDownPosition == null) {
      _pointerDownPosition = event.position;
      _pointerDownMillis = DateTime.now().millisecondsSinceEpoch;
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (_pointerActive > 0) _pointerActive--;
    final down = _pointerDownPosition;
    final peak = _pointerPeak;
    if (_pointerActive == 0) {
      _pointerDownPosition = null;
      _pointerPeak = 0;
    }
    if (down == null || _closing) return;
    if (peak > 1) return;
    if ((event.position - down).distance > _tapSlop) return;
    final held = DateTime.now().millisecondsSinceEpoch - _pointerDownMillis;
    if (held > _tapMaxMillis) return;
    // 放大状态下点击留给双击复位，不关闭。
    if (_isZoomedIn) return;
    // 点在图片上不关：那是双击缩放的区域。
    if (_isInsideImage(down)) return;
    _closePreview();
  }

  /// 上一次布局算出的图片显示区域（相对图片预览组件的本地坐标）。
  Rect? _imageRect;
  Size _viewportSize = Size.zero;

  /// 各图已知的原始宽高比（宽 / 高）。解出前为空，按「铺满」处理。
  final Map<String, double> _aspectRatios = {};

  /// 订阅 [url] 的图片流，拿到真实尺寸后记录宽高比并刷新显示矩形。
  void _trackAspectRatio(String url) {
    if (_aspectRatios.containsKey(url)) return;
    final stream =
        CachedNetworkImageProvider(url).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      _aspectRatios[url] = info.image.width / info.image.height;
      stream.removeListener(listener);
      if (mounted) {
        setState(() {
          _imageRect = _computeImageRect(_viewportSize, url);
        });
      }
    }, onError: (_, _) => stream.removeListener(listener));
    stream.addListener(listener);
  }

  /// 按视口与当前图宽高比，算出 contained 下的显示矩形。
  Rect? _computeImageRect(Size viewport, String url) {
    final ratio = _aspectRatios[url];
    if (ratio == null || ratio <= 0 || viewport.isEmpty) return null;
    return _containedRect(viewport, ratio);
  }

  /// [position] 是否落在图片当前显示的像素范围内。
  ///
  /// 不读 photo_view 的内部变换矩阵：那要反解控制器状态，且缩放后
  /// 还要换算屏幕坐标。本页 initialScale/minScale 都是 contained，
  /// 未放大时图片就是居中的等比矩形，按几何关系直接算更稳。
  /// 未放大是点黑边关闭的前提，所以只按整图矩形判断就够了。
  bool _isInsideImage(Offset position) {
    final rect = _imageRect;
    if (rect == null) return true; // 尺寸未知时当作点在图上，宁可不让关。
    return rect.contains(position);
  }

  /// 按 [viewport] 与图片原始宽高比，算出 contained 下的显示矩形。
  Rect _containedRect(Size viewport, double aspectRatio) {
    if (viewport.isEmpty || aspectRatio <= 0) {
      return Rect.fromLTWH(0, 0, viewport.width, viewport.height);
    }
    final viewportAspect = viewport.width / viewport.height;
    if (aspectRatio > viewportAspect) {
      // 图更宽：左右贴边，上下留黑边。
      final height = viewport.width / aspectRatio;
      final top = (viewport.height - height) / 2;
      return Rect.fromLTWH(0, top, viewport.width, height);
    }
    // 图更高：上下贴边，左右留黑边。
    final width = viewport.height * aspectRatio;
    final left = (viewport.width - width) / 2;
    return Rect.fromLTWH(left, 0, width, viewport.height);
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (_pointerActive > 0) _pointerActive--;
    if (_pointerActive == 0) {
      _pointerDownPosition = null;
      _pointerPeak = 0;
    }
  }

  /// 当前图片是否被放大过（相比打开时的整图大小）。
  bool get _isZoomedIn {
    final baseline = _initialScales[_activeScaleKey];
    final current = _activePhotoViewController?.scale;
    if (baseline == null || current == null) return false;
    return current > baseline * 1.05;
  }

  /// 各控制器上「整图状态」的基准缩放值记录订阅，销毁时要一并取消。
  final Map<int, StreamSubscription<PhotoViewControllerValue>>
      _baselineSubscriptions = {};

  bool get _isMultiImage => widget.imageUrls.length > 1;

  /// 记录某张图「整图状态」的缩放基准。
  ///
  /// photo_view 没有单独的 initialScale 概念可读，只能取它排完版后
  /// 第一次上报的 scale —— 那一帧正是 contained 值。
  void _watchBaseline(int key, PhotoViewController controller) {
    if (_baselineSubscriptions.containsKey(key)) return;
    _baselineSubscriptions[key] = controller.outputStateStream.listen((value) {
      if (_initialScales[key] == null && value.scale != null) {
        _initialScales[key] = value.scale;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _photoViewController = PhotoViewController();
    _scaleStateController = PhotoViewScaleStateController();
    _pageController = PageController(initialPage: widget.initialIndex);
    if (!_isMultiImage) {
      _watchBaseline(-1, _photoViewController);
    }
  }

  @override
  void dispose() {
    for (final subscription in _baselineSubscriptions.values) {
      subscription.cancel();
    }
    _baselineSubscriptions.clear();
    _photoViewController.dispose();
    _scaleStateController.dispose();
    for (final controller in _galleryControllers.values) {
      controller.dispose();
    }
    for (final controller in _galleryScaleStateControllers.values) {
      controller.dispose();
    }
    _pageController.dispose();
    super.dispose();
  }

  PhotoViewController? get _activePhotoViewController {
    if (_isMultiImage) {
      return _galleryControllers[_currentIndex];
    }
    return _photoViewController;
  }

  PhotoViewScaleStateController? get _activeScaleStateController {
    if (_isMultiImage) {
      return _galleryScaleStateControllers[_currentIndex];
    }
    return _scaleStateController;
  }

  int get _activeScaleKey => _isMultiImage ? _currentIndex : -1;

  /// 长按任意位置弹出保存卡片。
  ///
  /// 卡片与详情页封面长按共用同一处实现（[showImageSaveSheet]），
  /// 长按整屏都算数，不要求按在图片像素上。
  Future<void> _handleLongPress() async {
    final index = _currentIndex;
    await showImageSaveSheet(
      context,
      imageUrl: widget.imageUrls[index],
      fileBaseName: _fileNameFor(index),
    );
  }

  /// 保存时用的文件名（不含扩展名）：有外部基名就拼序号，否则从 URL 推导。
  String _fileNameFor(int index) {
    final base = widget.fileBaseName?.trim();
    if (base == null || base.isEmpty) {
      return ImageSaver.safeName(
        _fileNameFromUrl(widget.imageUrls[index]),
        fallback: '图片',
      );
    }
    return widget.imageUrls.length > 1 ? '$base-${index + 1}' : base;
  }

  /// 从图片 URL 里抠出文件名（去掉扩展名），推导不出就用空串交给兜底。
  static String _fileNameFromUrl(String imageUrl) {
    final segments = Uri.tryParse(imageUrl)?.pathSegments;
    if (segments == null || segments.isEmpty) return '';
    final last = segments.last;
    final dot = last.lastIndexOf('.');
    return dot > 0 ? last.substring(0, dot) : last;
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;

    final photoViewController = _activePhotoViewController;
    final scaleStateController = _activeScaleStateController;
    if (photoViewController == null || scaleStateController == null) return;

    final scaleKey = _activeScaleKey;
    final currentScale =
        photoViewController.scale ?? _initialScales[scaleKey] ?? 1.0;
    _initialScales[scaleKey] ??= currentScale;

    final factor =
        event.scrollDelta.dy < 0 ? _wheelScaleStep : 1 / _wheelScaleStep;
    final minScale = _initialScales[scaleKey]! * _minScaleFactor;
    final maxScale = _initialScales[scaleKey]! * _maxScaleFactor;
    final newScale = (currentScale * factor).clamp(minScale, maxScale);

    if (newScale == currentScale) return;

    photoViewController.scale = newScale;
    scaleStateController.scaleState = PhotoViewScaleState.zoomedIn;
  }

  void _closePreview() {
    if (_closing) return;
    _closing = true;
    context.pop();
  }

  Object _heroTagForIndex(int index) {
    if (index == widget.initialIndex && widget.heroTag != null) {
      return widget.heroTag!;
    }
    return ImageViewer.heroTagFor(widget.imageUrls[index], index);
  }

  void _goToPreviousImage() {
    if (_currentIndex <= 0) return;
    _pageController.previousPage(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
    );
  }

  void _goToNextImage() {
    if (_currentIndex >= widget.imageUrls.length - 1) return;
    _pageController.nextPage(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
    );
  }

  Widget _buildNavButton({
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(
          icon,
          color: onPressed != null ? Colors.white : Colors.white38,
          size: 32,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          _isMultiImage ? _buildGallery() : _buildSingleImage(),
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            right: 16,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                shape: BoxShape.circle,
              ),
              child: IconButton(
                onPressed: _closePreview,
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ),
          ),
          if (_isMultiImage)
            Positioned(
              bottom: MediaQuery.of(context).padding.bottom + 24,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    '${_currentIndex + 1} / ${widget.imageUrls.length}',
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ),
            ),
          if (isDesktop() && _isMultiImage) ...[
            Positioned(
              left: 16,
              top: 0,
              bottom: 0,
              child: Center(
                child: _buildNavButton(
                  icon: Icons.chevron_left,
                  onPressed: _currentIndex > 0 ? _goToPreviousImage : null,
                ),
              ),
            ),
            Positioned(
              right: 16,
              top: 0,
              bottom: 0,
              child: Center(
                child: _buildNavButton(
                  icon: Icons.chevron_right,
                  onPressed: _currentIndex < widget.imageUrls.length - 1
                      ? _goToNextImage
                      : null,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildErrorWidget() => const MediaErrorWidget(
        title: '图片加载失败',
        errMsg: '请检查网络连接，返回后重新打开图片。',
        icon: Icons.broken_image_outlined,
      );

  Widget _buildSingleImage() {
    final url = widget.imageUrls.first;
    _trackAspectRatio(url);
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        if (viewport != _viewportSize) {
          _viewportSize = viewport;
          // 布局阶段不能直接 setState，等这一帧结束再写回矩形。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final rect = _computeImageRect(viewport, url);
            if (rect != _imageRect) setState(() => _imageRect = rect);
          });
        }
        return Listener(
          onPointerSignal: _handlePointerSignal,
          onPointerDown: _handlePointerDown,
          onPointerUp: _handlePointerUp,
          onPointerCancel: _handlePointerCancel,
          child: GestureDetector(
            // 只绑长按。双击与缩放交给 photo_view 内部识别器，
            // 外层再绑 onTap/onDoubleTap 会与它抢手势，双击时灵时不灵。
            // 点黑边收起走上面的指针通道，不经过 GestureDetector。
            // 桌面端补右键：鼠标没有长按习惯，右键才是「另存为」的直觉。
            onLongPress: _handleLongPress,
            onSecondaryTap: isDesktop() ? _handleLongPress : null,
            child: PhotoView(
              imageProvider: CachedNetworkImageProvider(url),
              controller: _photoViewController,
              scaleStateController: _scaleStateController,
              scaleStateCycle: nextDoubleTapScaleState,
              // 打开即整图可见（长边贴合、不裁切），想放大再自己捏。
              // 不要用 covered：封面是竖图，铺满会把上下裁掉一大截。
              initialScale: PhotoViewComputedScale.contained,
              minScale: PhotoViewComputedScale.contained,
              maxScale: PhotoViewComputedScale.covered * 3,
              backgroundDecoration: const BoxDecoration(color: Colors.black),
              heroAttributes: widget.heroTag != null
                  ? PhotoViewHeroAttributes(tag: widget.heroTag!)
                  : null,
              loadingBuilder: (context, event) =>
                  const Center(child: LoadingIndicator()),
              errorBuilder: (context, error, stackTrace) => _buildErrorWidget(),
            ),
          ),
        );
      },
    );
  }

  Widget _buildGallery() {
    final currentUrl = widget.imageUrls[_currentIndex];
    _trackAspectRatio(currentUrl);
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        if (viewport != _viewportSize) {
          _viewportSize = viewport;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final rect = _computeImageRect(viewport, currentUrl);
            if (rect != _imageRect) setState(() => _imageRect = rect);
          });
        }
        return Listener(
          onPointerSignal: _handlePointerSignal,
          onPointerDown: _handlePointerDown,
          onPointerUp: _handlePointerUp,
          onPointerCancel: _handlePointerCancel,
          child: GestureDetector(
            onLongPress: _handleLongPress,
            onSecondaryTap: isDesktop() ? _handleLongPress : null,
            child: PhotoViewGallery.builder(
              pageController: _pageController,
              itemCount: widget.imageUrls.length,
              onPageChanged: (index) {
                setState(() {
                  _currentIndex = index;
                  // 翻页后图片区域跟着换，重算黑边范围。
                  _imageRect = _computeImageRect(
                    _viewportSize,
                    widget.imageUrls[index],
                  );
                });
              },
              backgroundDecoration: const BoxDecoration(color: Colors.black),
              loadingBuilder: (context, event) =>
                  const Center(child: LoadingIndicator()),
              builder: (context, index) {
                final imageUrl = widget.imageUrls[index];
                final controller = _galleryControllers.putIfAbsent(
                  index,
                  PhotoViewController.new,
                );
                final scaleStateController = _galleryScaleStateControllers
                    .putIfAbsent(index, PhotoViewScaleStateController.new);
                // 每页都记一次自己的整图基准，翻页后判定「是否放大」才不会串。
                _watchBaseline(index, controller);
                return PhotoViewGalleryPageOptions(
                  imageProvider: CachedNetworkImageProvider(imageUrl),
                  controller: controller,
                  scaleStateController: scaleStateController,
                  scaleStateCycle: nextDoubleTapScaleState,
                  initialScale: PhotoViewComputedScale.contained,
                  minScale: PhotoViewComputedScale.contained,
                  maxScale: PhotoViewComputedScale.covered * 3,
                  heroAttributes: index == _currentIndex
                      ? PhotoViewHeroAttributes(tag: _heroTagForIndex(index))
                      : null,
                  errorBuilder: (context, error, stackTrace) =>
                      _buildErrorWidget(),
                );
              },
            ),
          ),
        );
      },
    );
  }
}
