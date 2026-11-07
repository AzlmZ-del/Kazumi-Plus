import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ImageCacheService {
  Stream<File> _files() async* {
    final temporary = await getTemporaryDirectory();
    final directory =
        Directory(p.join(temporary.path, DefaultCacheManager.key));
    if (!await directory.exists()) return;
    yield* directory
        .list(recursive: true, followLinks: false)
        .where((entry) => entry is File)
        .cast<File>();
  }

  Future<int> sizeInBytes() async {
    var bytes = 0;
    await for (final file in _files()) {
      // 枚举过程中可能正好有文件到期。
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.file) bytes += stat.size;
    }
    return bytes;
  }

  Future<void> clear() async {
    // 连孤儿文件一起算，但这份快照之后才缓存进来的图片不碰。
    final files = await _files().toList();
    await DefaultCacheManager().emptyCache();
    for (final file in files) {
      try {
        await file.delete();
      } on PathNotFoundException {
        // 已经被缓存管理器删掉了。
      }
    }
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }
}
