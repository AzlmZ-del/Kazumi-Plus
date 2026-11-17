import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/bean/widget/image_preview.dart';
import 'package:photo_view/photo_view.dart';

void main() {
  group('双击缩放循环', () {
    test('整图双击跳到原尺寸', () {
      expect(
        nextDoubleTapScaleState(PhotoViewScaleState.initial),
        PhotoViewScaleState.originalSize,
      );
    });

    test('原尺寸双击回到整图', () {
      expect(
        nextDoubleTapScaleState(PhotoViewScaleState.originalSize),
        PhotoViewScaleState.initial,
      );
    });

    test('两步循环不会经过铺满档', () {
      // photo_view 默认是 整图 → 铺满 → 原尺寸 → 整图，铺满会把竖图
      // 上下裁掉一大截。这里钉住「铺满」永远不是双击的落点。
      var state = PhotoViewScaleState.initial;
      for (var i = 0; i < 10; i++) {
        state = nextDoubleTapScaleState(state);
        expect(state, isNot(PhotoViewScaleState.covering));
      }
    });

    test('来回切换稳定在两个状态之间', () {
      var state = nextDoubleTapScaleState(PhotoViewScaleState.initial);
      expect(state, PhotoViewScaleState.originalSize);
      state = nextDoubleTapScaleState(state);
      expect(state, PhotoViewScaleState.initial);
      state = nextDoubleTapScaleState(state);
      expect(state, PhotoViewScaleState.originalSize);
    });

    test('捏合缩放后的中间态双击一律收回整图', () {
      // 用户自己捏到一半再双击，预期是还原而不是继续放大。
      for (final state in const [
        PhotoViewScaleState.zoomedIn,
        PhotoViewScaleState.zoomedOut,
        PhotoViewScaleState.covering,
      ]) {
        expect(nextDoubleTapScaleState(state), PhotoViewScaleState.initial);
      }
    });
  });
}
