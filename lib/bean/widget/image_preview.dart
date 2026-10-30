import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/dialog.dart';
import 'package:kazumi/bean/dialog/material_bottom_sheet.dart';
import 'package:kazumi/bean/widget/loading_indicator.dart';
import 'package:kazumi/bean/widget/media_error_widget.dart';
import 'package:kazumi/bean/widget/split_list_row.dart';
import 'package:kazumi/services/network/image_saver.dart';
import 'package:kazumi/utils/device.dart';

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

  /// 判定「轻点」的最大位移（逻辑像素），超过就当成拖拽或翻页滑动。
  static const double _tapSlop = 12.0;

  /// 判定「轻点」的最大按住时长，超过就当成即将长按。
  static const int _tapMaxMillis = 400;

  /// 未放大时算作「就是初始大小」的容差，避免浮点误差把整图判成已放大。
  static const double _zoomTolerance = 1.05;

  Offset? _pointerDownPosition;
  int _pointerDownMillis = 0;

  /// 这一次按压过程中同时按下过的最大手指数。
  /// 多指（捏合缩放）抬起时不能当成轻点，否则刚缩回整图就被关掉。
  int _pointerPeak = 0;
  int _pointerActive = 0;

  /// 防止一次点击同时触发「立即关闭」与手势回退，重复 pop 会把下层页面也带走。
  bool _closing = false;

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

  /// 当前图片是否被放大过（相比打开时的整图大小）。
  bool get _isZoomedIn {
    final baseline = _initialScales[_activeScaleKey];
    final current = _activePhotoViewController?.scale;
    if (baseline == null || current == null) return false;
    return current > baseline * _zoomTolerance;
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

  /// 长按任意位置弹出保存菜单。
  ///
  /// 菜单用底部弹层而不是右键菜单位置，手机与桌面同一套；
  /// 长按整屏都算数，不要求按在图片像素上。
  Future<void> _handleLongPress() async {
    final index = _currentIndex;
    final imageUrl = widget.imageUrls[index];
    final action = await showAdaptiveBottomSheet<_ImageAction>(
      context: context,
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MaterialBottomSheetHeader(
            title: '图片',
            onClose: () => Navigator.of(sheetContext).pop(),
          ),
          Padding(
            padding: materialBottomSheetContentPadding,
            child: SplitListGroup(
              children: [
                ListTile(
                  leading: const Icon(Icons.download_rounded),
                  title: const Text('保存图片'),
                  subtitle: Text(
                    isDesktop() ? '选择位置另存为图片' : '保存到系统相册',
                  ),
                  onTap: () =>
                      Navigator.of(sheetContext).pop(_ImageAction.save),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (!mounted || action != _ImageAction.save) return;
    await _saveImage(imageUrl, index);
  }

  Future<void> _saveImage(String imageUrl, int index) async {
    final base = widget.fileBaseName?.trim();
    final fileName = (base == null || base.isEmpty)
        ? ImageSaver.safeName(_fileNameFromUrl(imageUrl), fallback: '图片')
        : (widget.imageUrls.length > 1 ? '$base-${index + 1}' : base);
    final result = await ImageSaver.save(
      imageUrl: imageUrl,
      fileName: fileName,
    );
    if (!mounted) return;
    switch (result.status) {
      case ImageSaveStatus.saved:
        KazumiDialog.showToast(
          message: isDesktop() ? '图片已保存' : '已保存到相册',
        );
      case ImageSaveStatus.cancelled:
        break;
      case ImageSaveStatus.failed:
        KazumiDialog.showToast(message: result.message);
    }
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

  /// 记录按下的位置与时刻，给「轻点立即关闭」用。
  void _handlePointerDown(PointerDownEvent event) {
    _pointerActive++;
    if (_pointerActive > _pointerPeak) _pointerPeak = _pointerActive;
    if (_pointerDownPosition == null) {
      _pointerDownPosition = event.position;
      _pointerDownMillis = DateTime.now().millisecondsSinceEpoch;
    }
  }

  /// 抬起时判断是不是一次「轻点」。
  ///
  /// 未放大时直接关闭，不等双击判定窗口的 300 ms —— 这是收回迟滞的主要来源。
  /// 已放大时不动，交给外层手势：双击复位、单击退出照旧。
  void _handlePointerUp(PointerUpEvent event) {
    if (_pointerActive > 0) _pointerActive--;
    final down = _pointerDownPosition;
    final peak = _pointerPeak;
    if (_pointerActive == 0) {
      // 所有手指都离开了，这一轮判定结束。
      _pointerDownPosition = null;
      _pointerPeak = 0;
    }
    if (down == null || _closing) return;
    if (peak > 1) return;
    if ((event.position - down).distance > _tapSlop) return;
    final held = DateTime.now().millisecondsSinceEpoch - _pointerDownMillis;
    if (held > _tapMaxMillis) return;
    if (_isZoomedIn) return;
    _closePreview();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (_pointerActive > 0) _pointerActive--;
    if (_pointerActive == 0) {
      _pointerDownPosition = null;
      _pointerPeak = 0;
    }
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
    return Listener(
      onPointerSignal: _handlePointerSignal,
      onPointerDown: _handlePointerDown,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      child: GestureDetector(
        // 放大状态下才靠这里关闭（指针通道此时已主动让路）。
        onTap: _closePreview,
        onLongPress: _handleLongPress,
        child: PhotoView(
          imageProvider: CachedNetworkImageProvider(widget.imageUrls.first),
          controller: _photoViewController,
          scaleStateController: _scaleStateController,
          // 打开即整图可见（长边贴合、不裁切），想放大再自己捏。
          // 不要用 covered：封面是竖图，铺满会把上下裁掉一大截。
          initialScale: PhotoViewComputedScale.contained,
          minScale: PhotoViewComputedScale.contained,
          maxScale: PhotoViewComputedScale.covered * 3,
          backgroundDecoration: const BoxDecoration(color: Colors.black),
          heroAttributes: widget.heroTag != null
              ? PhotoViewHeroAttributes(tag: widget.heroTag!)
              : null,
          loadingBuilder: (context, event) => const Center(
            child: LoadingIndicator(),
          ),
          errorBuilder: (context, error, stackTrace) => _buildErrorWidget(),
        ),
      ),
    );
  }

  Widget _buildGallery() {
    return Listener(
      onPointerSignal: _handlePointerSignal,
      onPointerDown: _handlePointerDown,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      child: GestureDetector(
        onTap: _closePreview,
        onLongPress: _handleLongPress,
        child: PhotoViewGallery.builder(
          pageController: _pageController,
          itemCount: widget.imageUrls.length,
          onPageChanged: (index) => setState(() => _currentIndex = index),
          backgroundDecoration: const BoxDecoration(color: Colors.black),
          loadingBuilder: (context, event) => const Center(
            child: LoadingIndicator(),
          ),
          builder: (context, index) {
            final imageUrl = widget.imageUrls[index];
            final controller = _galleryControllers.putIfAbsent(
              index,
              PhotoViewController.new,
            );
            final scaleStateController =
                _galleryScaleStateControllers.putIfAbsent(
              index,
              PhotoViewScaleStateController.new,
            );
            // 每页都记一次自己的整图基准，翻页后判定「是否放大」才不会串。
            _watchBaseline(index, controller);
            return PhotoViewGalleryPageOptions(
              imageProvider: CachedNetworkImageProvider(imageUrl),
              controller: controller,
              scaleStateController: scaleStateController,
              initialScale: PhotoViewComputedScale.contained,
              minScale: PhotoViewComputedScale.contained,
              maxScale: PhotoViewComputedScale.covered * 3,
              heroAttributes: index == _currentIndex
                  ? PhotoViewHeroAttributes(tag: _heroTagForIndex(index))
                  : null,
              errorBuilder: (context, error, stackTrace) => _buildErrorWidget(),
            );
          },
        ),
      ),
    );
  }
}

/// 图片预览长按菜单里选中的动作。
enum _ImageAction { save }
