import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Persistent app folder on the device's internal storage:
///   <internal storage>/Android/data/com.ananta.ott/files/AnantaOTT/
///     epg/    programme guide cache (epg_cache.json)
///     logos/  channel logo image cache
/// The folder is created natively on first launch (no permission needed).
class AnantaStorage {
  AnantaStorage._();

  static const MethodChannel _ch = MethodChannel('com.ananta.ott/installer');
  static Future<Directory>? _root;

  static Future<Directory> root() => _root ??= _resolve();

  static Future<Directory> _resolve() async {
    String? path;
    try {
      path = await _ch.invokeMethod<String>('getDataDir');
    } catch (_) {}
    final dir = Directory(path ?? '${Directory.systemTemp.path}/AnantaOTT');
    try {
      await dir.create(recursive: true);
    } catch (_) {}
    return dir;
  }

  static Future<Directory> _sub(String name) async {
    final dir = Directory('${(await root()).path}/$name');
    try {
      await dir.create(recursive: true);
    } catch (_) {}
    return dir;
  }

  static Future<File> epgFile() async =>
      File('${(await _sub('epg')).path}/epg_cache.json');

  /// Channel logo cache stored in the AnantaOTT/logos folder.
  static final CacheManager logoCache = CacheManager(
    Config(
      'ananta_logos',
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: 1000,
      fileSystem: _FolderFileSystem(),
    ),
  );
}

class _FolderFileSystem implements FileSystem {
  @override
  Future<File> createFile(String name) async {
    final dir = await AnantaStorage._sub('logos');
    return File('${dir.path}/$name');
  }
}
