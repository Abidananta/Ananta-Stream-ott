import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps an "Ananta OTT" folder in the device's internal storage:
///
///   Ananta OTT/
///     epg/                 cached EPG files, one per source (+ sources.json)
///     logos/<group>/       channel logos, one sub-folder per channel group
///
/// With "All files access" (Android 11+) / storage permission (Android 6-10)
/// the folder is created at the top of the internal storage, so it shows up in
/// the file manager. Without it the app-specific external folder is used.
class StorageService {
  StorageService._();

  static const MethodChannel _channel = MethodChannel('com.ananta.ott/storage');

  static String? _rootPath;
  static bool _public = false;
  static DateTime _resolvedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Sync access for widgets (null until [root] resolved once).
  static String? get rootPathSync => _rootPath;
  static bool get isPublic => _public;

  static String safeName(String value, {String fallback = 'Other', int max = 60}) {
    var s = value.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]+'), '_').trim();
    s = s.replaceAll(RegExp(r'\s+'), ' ').replaceAll(RegExp(r'^\.+'), '');
    if (s.length > max) s = s.substring(0, max).trim();
    return s.isEmpty ? fallback : s;
  }

  /// Resolves (and creates) the root folder. Re-asks Android every 20 s so a
  /// permission granted later in Settings is picked up without a restart.
  static Future<Directory?> root({bool force = false}) async {
    if (!Platform.isAndroid) return null;
    final fresh = DateTime.now().difference(_resolvedAt).inSeconds < 20;
    if (!force && fresh && _rootPath != null) return Directory(_rootPath!);
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('getStorageRoot');
      final path = res?['path'] as String?;
      if (path == null || path.isEmpty) return null;
      _rootPath = path;
      _public = res?['public'] == true;
      _resolvedAt = DateTime.now();
      final dir = Directory(path);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    } catch (e) {
      debugPrint('Storage root error: $e');
      return null;
    }
  }

  static Future<Directory?> subDir(String name) async {
    final r = await root();
    if (r == null) return null;
    try {
      final d = Directory('${r.path}/$name');
      if (!d.existsSync()) d.createSync(recursive: true);
      return d;
    } catch (e) {
      debugPrint('Storage dir error ($name): $e');
      return null;
    }
  }

  /// Copies [file] to the public folder Documents/Ananta OTT/[dir]/ (visible in
  /// every file manager, no permission needed on Android 10+). Only used when
  /// the full "Ananta OTT" folder at the top of the storage is not available.
  static Future<void> mirror(File file, String dir, {bool overwrite = false}) async {
    if (!Platform.isAndroid || _public) return;
    try {
      final name = file.uri.pathSegments.last;
      await _channel.invokeMethod<bool>('mirrorFile', {
        'path': file.path,
        'dir': dir,
        'name': name,
        'overwrite': overwrite,
      });
    } catch (e) {
      debugPrint('Storage mirror error: $e');
    }
  }

  static const String _readme =
      'Ananta OTT cache\r\n'
      '\r\n'
      'epg\\    programme guide files (3-day EPG) and status.txt\r\n'
      'logos\\  channel logos, one folder per channel group\r\n'
      '\r\n'
      'The app re-creates anything you delete here.\r\n';

  /// Called once at startup: creates the folders and (once only) asks Android
  /// for the access that makes the folder visible in the file manager.
  static Future<void> setup() async {
    if (!Platform.isAndroid) return;
    try {
      await root(force: true);
      final logos = await subDir('logos');
      await subDir('epg');
      if (logos != null) {
        final nomedia = File('${logos.path}/.nomedia'); // keep logos out of the gallery
        if (!nomedia.existsSync()) nomedia.createSync();
      }
      // A small README makes the folder appear in the file manager right away
      // (before the first logo / guide file has been downloaded).
      final r = await root();
      if (r != null) {
        final readme = File('${r.path}/README.txt');
        if (!readme.existsSync()) readme.writeAsStringSync(_readme);
        await mirror(readme, '', overwrite: true);
      }
      if (!_public) {
        // Give the user a moment to see the app first, then ask once.
        await Future<void>.delayed(const Duration(seconds: 4));
        await _channel.invokeMethod<bool>('requestStorageAccessOnce');
      }
    } catch (e) {
      debugPrint('Storage setup error: $e');
    }
  }
}

// ---------------------------------------------------------------------------
// EPG sources: every file in the repository's /epg folder
// ---------------------------------------------------------------------------

class EpgSource {
  const EpgSource(this.name, this.url, {this.path = '', this.altUrls = const []});
  final String name;
  final String url;

  /// Other places to try when [url] fails or serves outdated data
  /// (e.g. the copy in the repository's /epg folder).
  final List<String> altUrls;

  /// Path inside the repository's /epg folder (e.g. `tataplay/epg.xml.gz`).
  /// Also the path of the copy bundled in the APK under assets/epg/.
  final String path;
}

/// EPG files that ship inside the APK (assets/epg/...), used as an offline
/// seed when a source can neither be downloaded nor read from the epg folder.
class EpgBundled {
  EpgBundled._();

  static const List<String> paths = [
    'epg.xml.gz',
    'tataplay/epg.xml.gz',
    'jiotv/epg.xml.gz',
  ];

  static Future<Uint8List?> read(String path) async {
    if (path.isEmpty) return null;
    try {
      final data = await rootBundle.load('assets/epg/$path');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      return null;
    }
  }
}

class EpgSourceResolver {
  EpgSourceResolver._();

  static const String _api =
      'https://api.github.com/repos/Abidananta/Ananta-Stream-ott/contents/epg?ref=main';
  static const String _prefsKey = 'ananta_epg_sources_v2';

  static bool _isData(String n) =>
      n.endsWith('.xml') || n.endsWith('.xml.gz') || n.endsWith('.gz') || n.endsWith('.xmltv');
  static bool _isList(String n) =>
      n.endsWith('.txt') || n.endsWith('.list') || n.endsWith('.m3u') || n.endsWith('.csv');

  static final RegExp _epgLikeUrl =
      RegExp(r'(\.xml|\.xml\.gz|\.gz|\.xmltv)(\?.*)?$|epg', caseSensitive: false);

  // The three well-known feeds and where their copy lives in /epg (and assets).
  static const Map<String, String> _knownPaths = {
    'epg.xml.gz': 'epg.xml.gz',
    'tsepg.xml.gz': 'tataplay/epg.xml.gz',
    'jioepg.xml.gz': 'jiotv/epg.xml.gz',
  };

  static String _pathForUrl(String url) {
    final seg = Uri.tryParse(url)?.pathSegments;
    if (seg == null || seg.isEmpty) return '';
    return _knownPaths[seg.last] ?? '';
  }

  static const Map<String, String> _headers = {
    'User-Agent': 'AnantaOTT/1.0',
    'Accept': 'application/vnd.github+json',
  };

  /// All EPG sources found in /epg. Falls back to the last known list, then to
  /// [fallbackUrls] when the folder cannot be read or is empty.
  static Future<List<EpgSource>> resolve(List<String> fallbackUrls) async {
    final found = <EpgSource>[];
    try {
      await _walk(_api, found, 0);
    } catch (e) {
      debugPrint('EPG folder listing failed: $e');
    }
    if (found.isEmpty) {
      try {
        await _listViaCdn(found);
      } catch (e) {
        debugPrint('EPG CDN listing failed: $e');
      }
    }
    // De-duplicate by URL, keep order.
    final seen = <String>{};
    final unique = [for (final s in found) if (seen.add(s.url)) s];
    if (unique.isNotEmpty) await _remember(unique);
    final base = unique.isNotEmpty ? unique : await _recall();
    return _withLive(base, fallbackUrls);
  }

  /// The live feeds always come first (they are refreshed every day). A file
  /// of the /epg folder that is the same feed becomes its backup (altUrls);
  /// every other file of the folder is added as its own source.
  static const String _upstreamRaw = 'https://raw.githubusercontent.com/mitthu786/tvepg/main/';
  static const String _upstreamCdn = 'https://cdn.jsdelivr.net/gh/mitthu786/tvepg@main/';

  static List<EpgSource> _withLive(List<EpgSource> folder, List<String> liveUrls) {
    final result = <EpgSource>[];
    final usedPaths = <String>{};
    for (final u in liveUrls) {
      final path = _pathForUrl(u);
      if (path.isEmpty) {
        result.add(EpgSource(_nameFromUrl(u), u));
        continue;
      }
      // This repo's /epg copy first (direct raw link, so it works even when the
      // GitHub API listing fails), then upstream GitHub, the short-link feed
      // and the CDN mirror. Outdated copies are skipped by the loader.
      String? repoUrl;
      for (final e in folder) {
        if (e.path == path) repoUrl = e.url;
      }
      repoUrl ??= '$_repoRaw$path';
      final alts = <String>['$_upstreamRaw$path', u, '$_upstreamCdn$path']
        ..removeWhere((x) => x == repoUrl);
      result.add(EpgSource(path, repoUrl, path: path, altUrls: alts));
      usedPaths.add(path);
    }
    for (final e in folder) {
      if (usedPaths.contains(e.path) || liveUrls.contains(e.url)) continue;
      result.add(e);
    }
    return result;
  }

  static Future<void> _walk(String apiUrl, List<EpgSource> out, int depth) async {
    final res = await http.get(Uri.parse(apiUrl), headers: _headers).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return;
    final decoded = jsonDecode(res.body);
    if (decoded is! List) return;
    for (final item in decoded) {
      if (item is! Map) continue;
      final type = item['type']?.toString();
      final name = (item['name']?.toString() ?? '');
      final lower = name.toLowerCase();
      if (name.startsWith('.')) continue;
      if (type == 'dir' && depth < 2) {
        final next = item['url']?.toString();
        if (next != null) await _walk(next, out, depth + 1);
        continue;
      }
      if (type != 'file') continue;
      final download = item['download_url']?.toString();
      if (download == null || download.isEmpty) continue;
      final repoPath = item['path']?.toString() ?? name;
      final rel = repoPath.startsWith('epg/') ? repoPath.substring(4) : repoPath;
      await _ingest(name, rel, download, out);
    }
  }

  /// One file of the /epg folder: an EPG data file, or a list of EPG URLs.
  static Future<void> _ingest(String name, String rel, String download, List<EpgSource> out) async {
    final lower = name.toLowerCase();
    if (name.startsWith('.')) return;
    if (_isData(lower)) {
      out.add(EpgSource(rel, download, path: rel));
    } else if (_isList(lower)) {
      try {
        final listRes = await http
            .get(Uri.parse(download), headers: const {'User-Agent': 'AnantaOTT/1.0'})
            .timeout(const Duration(seconds: 15));
        if (listRes.statusCode != 200) return;
        final urls = RegExp(r'''https?://[^\s"',<>\]\[]+''').allMatches(utf8.decode(listRes.bodyBytes, allowMalformed: true));
        for (final m in urls) {
          final u = m.group(0)!;
          if (!_epgLikeUrl.hasMatch(u)) continue; // skip logos / websites
          out.add(EpgSource(_nameFromUrl(u), u, path: _pathForUrl(u)));
        }
      } catch (e) {
        debugPrint('EPG list file failed ($name): $e');
      }
    }
  }

  static const String _repoRaw = 'https://raw.githubusercontent.com/Abidananta/Ananta-Stream-ott/main/epg/';
  static const String _cdnList = 'https://data.jsdelivr.com/v1/package/gh/Abidananta/Ananta-Stream-ott@main/flat';

  /// Same folder listing through the jsDelivr API: used when the GitHub API
  /// refuses (rate limit) or is unreachable.
  static Future<void> _listViaCdn(List<EpgSource> out) async {
    final res = await http.get(Uri.parse(_cdnList), headers: const {'User-Agent': 'AnantaOTT/1.0'}).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return;
    final decoded = jsonDecode(res.body);
    final files = decoded is Map ? decoded['files'] : null;
    if (files is! List) return;
    for (final f in files) {
      final name = (f is Map ? f['name'] : null)?.toString() ?? '';
      if (!name.startsWith('/epg/')) continue;
      final rel = name.substring(5);
      await _ingest(rel.split('/').last, rel, '$_repoRaw$rel', out);
    }
  }

  static String _nameFromUrl(String url) {
    final uri = Uri.tryParse(url);
    final seg = (uri != null && uri.pathSegments.isNotEmpty) ? uri.pathSegments.last : 'epg';
    return '${uri?.host ?? 'src'}_${seg.isEmpty ? 'epg' : seg}';
  }

  static Future<void> _remember(List<EpgSource> sources) async {
    try {
      final data = jsonEncode([for (final s in sources) {'name': s.name, 'url': s.url, 'path': s.path}]);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, data);
      final dir = await StorageService.subDir('epg');
      if (dir != null) {
        final f = File('${dir.path}/sources.json');
        await f.writeAsString(data);
        await StorageService.mirror(f, 'epg', overwrite: true);
      }
    } catch (e) {
      debugPrint('EPG sources save failed: $e');
    }
  }

  static Future<List<EpgSource>> _recall() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return const [];
      final list = jsonDecode(raw) as List;
      return [for (final e in list) EpgSource(e['name'].toString(), e['url'].toString(), path: (e['path'] ?? '').toString())];
    } catch (_) {
      return const [];
    }
  }
}

/// Raw EPG files kept in Ananta OTT/epg so the guide still loads offline.
class EpgDiskCache {
  EpgDiskCache._();

  static String _fileName(EpgSource s) {
    final base = StorageService.safeName(s.name, fallback: 'epg', max: 80);
    final h = s.url.hashCode.toUnsigned(32).toRadixString(16);
    final dot = base.lastIndexOf('.');
    // keep the extension at the end: tsepg.xml.gz -> tsepg_<hash>.xml.gz
    final ext = base.toLowerCase().endsWith('.xml.gz')
        ? '.xml.gz'
        : (dot > 0 ? base.substring(dot) : '');
    final stem = ext.isEmpty ? base : base.substring(0, base.length - ext.length);
    return '${stem}_$h$ext';
  }

  static Future<void> save(EpgSource s, List<int> bytes) async {
    try {
      final dir = await StorageService.subDir('epg');
      if (dir == null) return;
      final f = File('${dir.path}/${_fileName(s)}');
      final tmp = File('${f.path}.${DateTime.now().microsecondsSinceEpoch}.part');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(f.path);
      await StorageService.mirror(f, 'epg', overwrite: true);
    } catch (e) {
      debugPrint('EPG file save failed (${s.name}): $e');
    }
  }

  static bool _restoring = false;

  /// Human-readable result of the last EPG load (Ananta OTT/epg/status.txt):
  /// which source answered, how many programmes, until when.
  static Future<void> writeStatus(String text) async {
    try {
      final dir = await StorageService.subDir('epg');
      if (dir != null) {
        final f = File('${dir.path}/status.txt');
        await f.writeAsString(text);
        await StorageService.mirror(f, 'epg', overwrite: true);
      }
    } catch (_) {}
  }

  static bool _hasDataFiles(Directory dir) {
    try {
      for (final e in dir.listSync(followLinks: false)) {
        if (e is! File) continue;
        final n = e.uri.pathSegments.last.toLowerCase();
        if ((n.endsWith('.gz') || n.endsWith('.xml')) && e.lengthSync() > 0) return true;
      }
    } catch (_) {}
    return false;
  }

  /// Re-creates the epg folder and its files when they are missing, e.g. after
  /// the user deleted them in the file manager. Cheap when everything is there
  /// (one directory listing). Missing files are downloaded again; if the
  /// network is not available the copy bundled in the APK is written instead,
  /// so the folder is never left empty.
  static Future<void> restoreIfMissing(List<String> fallbackUrls) async {
    if (_restoring || !Platform.isAndroid) return;
    _restoring = true;
    try {
      await StorageService.root(force: true); // also re-creates "Ananta OTT"
      final dir = await StorageService.subDir('epg');
      if (dir == null || _hasDataFiles(dir)) return;
      final logos = await StorageService.subDir('logos');
      if (logos != null) {
        final nomedia = File('${logos.path}/.nomedia');
        if (!nomedia.existsSync()) nomedia.createSync();
      }
      final sources = await EpgSourceResolver.resolve(fallbackUrls);
      for (final s in sources) {
        final f = File('${dir.path}/${_fileName(s)}');
        if (f.existsSync() && f.lengthSync() > 0) continue;
        List<int>? bytes;
        if (s.url.isNotEmpty) {
          try {
            final r = await http
                .get(Uri.parse(s.url), headers: const {'User-Agent': 'AnantaOTT/1.0', 'Accept': '*/*'})
                .timeout(const Duration(seconds: 60));
            if (r.statusCode == 200 && r.bodyBytes.isNotEmpty) bytes = r.bodyBytes;
          } catch (e) {
            debugPrint('EPG restore download failed (${s.name}): $e');
          }
        }
        bytes ??= await EpgBundled.read(s.path);
        if (bytes != null) await save(s, bytes);
      }
    } catch (e) {
      debugPrint('EPG folder restore failed: $e');
    } finally {
      _restoring = false;
    }
  }

  static Future<Uint8List?> read(EpgSource s) async {
    try {
      final dir = await StorageService.subDir('epg');
      if (dir == null) return null;
      final f = File('${dir.path}/${_fileName(s)}');
      if (!f.existsSync()) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Channel logos: Ananta OTT/logos/<group>/<channel>.png
// ---------------------------------------------------------------------------

class LogoStore {
  LogoStore._();

  static final Map<String, String?> _known = {}; // url -> existing file path
  static final Map<String, DateTime> _verifiedAt = {};
  static final Set<String> _failed = {};
  static final Set<String> _queued = {};
  static int _active = 0;
  static final List<Future<void> Function()> _pending = [];

  static String? _pathFor(String url, String group) {
    final root = StorageService.rootPathSync;
    if (root == null) return null;
    final seg = Uri.tryParse(url)?.pathSegments;
    final file = StorageService.safeName(
        (seg != null && seg.isNotEmpty) ? seg.last : url.hashCode.toString(),
        fallback: 'logo.png');
    return '$root/logos/${StorageService.safeName(group)}/$file';
  }

  /// Local file when the logo is already stored, otherwise the network image
  /// (and the logo is saved to the folder in the background).
  static ImageProvider provider(String url, String group) {
    final path = _pathFor(url, group);
    if (path != null) {
      final known = _known.putIfAbsent(url, () {
        try {
          final f = File(path);
          return (f.existsSync() && f.lengthSync() > 0) ? path : null;
        } catch (_) {
          return null;
        }
      });
      if (known != null) {
        // The user may delete files in the file manager: re-check now and then.
        final now = DateTime.now();
        final last = _verifiedAt[url];
        if (last == null || now.difference(last).inSeconds > 20) {
          _verifiedAt[url] = now;
          try {
            final f = File(known);
            if (!f.existsSync() || f.lengthSync() == 0) {
              _known.remove(url);
              _failed.remove(url);
              _enqueue(url, group, path);
              return _small(CachedNetworkImageProvider(url, maxWidth: _logoPx));
            }
          } catch (_) {}
        }
        return _small(FileImage(File(known)));
      }
      _enqueue(url, group, path);
    }
    return _small(CachedNetworkImageProvider(url, maxWidth: _logoPx));
  }

  // Logos are shown at ~60px: decoding the full-size PNG for every row made
  // the channel list stutter on TV boxes.
  static const int _logoPx = 160;
  static ImageProvider _small(ImageProvider p) {
    // Separate returns: a single `a ? b : c` infers type Object with newer
    // cached_network_image versions and fails to compile.
    if (p is CachedNetworkImageProvider) return p;
    return ResizeImage(p, width: _logoPx);
  }

  static void _enqueue(String url, String group, String path) {
    if (_failed.contains(url) || !_queued.add(url)) return;
    _pending.add(() => _download(url, path));
    _pump();
  }

  static void _pump() {
    while (_active < 3 && _pending.isNotEmpty) {
      final job = _pending.removeAt(0);
      _active++;
      job().whenComplete(() {
        _active--;
        _pump();
      });
    }
  }

  static Future<void> _download(String url, String path) async {
    try {
      final res = await http
          .get(Uri.parse(url), headers: const {'User-Agent': 'AnantaOTT/1.0'})
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
        _failed.add(url);
        return;
      }
      final f = File(path);
      await f.parent.create(recursive: true);
      await f.writeAsBytes(res.bodyBytes, flush: true);
      _known[url] = path;
      // Public copy (Documents/Ananta OTT/logos/<group>) when the full-access
      // folder is not available.
      final parts = path.split('/');
      final group = parts.length >= 2 ? parts[parts.length - 2] : '';
      await StorageService.mirror(f, group.isEmpty ? 'logos' : 'logos/$group');
    } catch (e) {
      _failed.add(url);
      debugPrint('Logo save failed ($url): $e');
    } finally {
      _queued.remove(url);
    }
  }
}
