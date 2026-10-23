import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// On-device storage for the programme guide (EPG) and the channel logos.
///
/// Layout (private app storage, works on every Android phone / TV box):
///   <app support dir>/ananta_data/
///     epg/                 raw EPG downloads (.xml.gz), parsed guide cache,
///                          HTTP validators (ETag / Last-Modified)
///     channel_logos/       the whole `channel_logos` folder of the GitHub
///                          repository, mirrored file by file
///     logos_manifest.json  what exists remotely / what is stored locally
///
/// Everything is refreshed automatically: EPG files use conditional requests
/// (only re-downloaded when the server copy changed) and the logo folder is
/// diffed against the repository so only new / changed logos are fetched and
/// deleted ones are removed.
const String _repoOwner = 'Abidananta';
const String _repoName = 'Ananta-Stream-ott';
const String _repoBranch = 'main';
const String _logoFolder = 'channel_logos';
const String _userAgent = 'AnantaOTT/1.0';
const Duration _logoSyncEvery = Duration(hours: 12);

class EpgFile {
  const EpgFile(this.file, {required this.changed, required this.offline});

  /// Local copy of the EPG source.
  final File file;

  /// True when new data was downloaded (or the local copy differs from before).
  final bool changed;

  /// True when the network was unavailable and the stored copy is used.
  final bool offline;
}

class LocalStore {
  LocalStore._();
  static final LocalStore instance = LocalStore._();

  /// Bumped whenever logos are added/changed so the UI can repaint.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  Directory? _epgDir;
  Directory? _logoDir;
  Future<void>? _initFuture;
  bool _ready = false;

  final Set<String> _localLogos = <String>{};
  Map<String, String> _remoteLogos = <String, String>{}; // name -> version token
  Map<String, String> _localTokens = <String, String>{}; // name -> token on disk
  int _logoSyncedAt = 0;
  Map<String, dynamic> _epgMeta = <String, dynamic>{};

  bool _syncing = false;
  final Set<String> _inflight = <String>{};
  final Set<String> _failed = <String>{};
  final List<String> _pending = <String>[];
  int _active = 0;

  // ------------------------------------------------------------------
  // Setup
  // ------------------------------------------------------------------
  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    try {
      final base = await getApplicationSupportDirectory();
      final root = Directory('${base.path}/ananta_data');
      _epgDir = await Directory('${root.path}/epg').create(recursive: true);
      _logoDir = await Directory('${root.path}/channel_logos').create(recursive: true);
      await for (final entity in _logoDir!.list()) {
        if (entity is! File) continue;
        final name = _baseName(entity.path);
        if (name.endsWith('.tmp')) {
          try { await entity.delete(); } catch (_) {}
        } else if (_validLogoName(name)) {
          _localLogos.add(name);
        }
      }
      final manifest = await _readJson(File('${root.path}/logos_manifest.json'));
      if (manifest != null) {
        _logoSyncedAt = (manifest['savedAt'] as num?)?.toInt() ?? 0;
        _remoteLogos = _stringMap(manifest['remote']);
        _localTokens = _stringMap(manifest['local']);
      }
      final meta = await _readJson(File('${root.path}/epg_meta.json'));
      if (meta != null) _epgMeta = meta;
      _ready = true;
      _bump();
    } catch (error) {
      debugPrint('Local store unavailable: $error');
    }
  }

  bool get isReady => _ready;
  int get localLogoCount => _localLogos.length;
  int get remoteLogoCount => _remoteLogos.length;

  String get summary {
    if (!_ready) return '';
    final total = _remoteLogos.isEmpty ? _localLogos.length : _remoteLogos.length;
    return '${_localLogos.length}/$total logos stored on device';
  }

  // ------------------------------------------------------------------
  // Logos
  // ------------------------------------------------------------------

  /// True once we know which logo files exist (remote listing or local copy).
  bool get hasLogoListing => _remoteLogos.isNotEmpty || _localLogos.length > 20;

  bool knowsLogo(String name) =>
      _localLogos.contains(name) || _remoteLogos.containsKey(name);

  /// The stored copy of [name], or null when it is not on the device (yet).
  File? logoFile(String name) {
    if (!_ready || !_localLogos.contains(name)) return null;
    return File('${_logoDir!.path}/$name');
  }

  /// True when the repository listing is known and does not contain [name].
  bool logoMissingRemotely(String name) =>
      _remoteLogos.isNotEmpty && !_remoteLogos.containsKey(name) && !_localLogos.contains(name);

  /// Downloads one logo in the background (used when a channel needs a logo
  /// that has not been mirrored yet).
  void requestLogo(String name) {
    if (!_ready || !_validLogoName(name)) return;
    if (_localLogos.contains(name) || _failed.contains(name) || _inflight.contains(name)) return;
    if (logoMissingRemotely(name)) return;
    _inflight.add(name);
    _pending.add(name);
    _pumpQueue();
  }

  void _pumpQueue() {
    while (_active < 4 && _pending.isNotEmpty) {
      final name = _pending.removeAt(0);
      _active++;
      _downloadLogo(name, null).then((ok) {
        if (ok) {
          _localLogos.add(name);
          _bump();
        } else {
          _failed.add(name);
        }
      }).whenComplete(() {
        _active--;
        _inflight.remove(name);
        _pumpQueue();
      });
    }
  }

  Uri _rawLogoUri(String name) => Uri.parse(
      'https://raw.githubusercontent.com/$_repoOwner/$_repoName/$_repoBranch/$_logoFolder/$name');

  Future<bool> _downloadLogo(String name, http.Client? client) async {
    try {
      final headers = const {'User-Agent': _userAgent};
      final response = client != null
          ? await client.get(_rawLogoUri(name), headers: headers).timeout(const Duration(seconds: 25))
          : await http.get(_rawLogoUri(name), headers: headers).timeout(const Duration(seconds: 25));
      if (response.statusCode != 200 || response.bodyBytes.length < 64) return false;
      final type = response.headers['content-type'] ?? '';
      if (type.startsWith('text/')) return false; // an error page, not an image
      await _atomicWrite(File('${_logoDir!.path}/$name'), response.bodyBytes);
      return true;
    } catch (error) {
      debugPrint('Logo download failed ($name): $error');
      return false;
    }
  }

  /// Mirrors the repository's channel_logos folder into local storage.
  /// Cheap when nothing changed (one small listing request). Safe to call
  /// often: it only runs every 12 hours unless [force] is set.
  Future<void> syncLogos({bool force = false}) async {
    await init();
    if (!_ready || _syncing) return;
    final age = DateTime.now().millisecondsSinceEpoch - _logoSyncedAt;
    final stale = _logoSyncedAt == 0 || age < 0 || age > _logoSyncEvery.inMilliseconds;
    if (!force && !stale && _remoteLogos.isNotEmpty) return;
    _syncing = true;
    final client = http.Client();
    try {
      final remote = await _fetchRemoteListing(client);
      if (remote == null || remote.isEmpty) return;

      final todo = remote.entries
          .where((e) => !_localLogos.contains(e.key) || _localTokens[e.key] != e.value)
          .map((e) => e.key)
          .toList();

      var replacedExisting = false;
      var next = 0;
      var sinceNotify = 0;
      Future<void> worker() async {
        while (true) {
          final i = next++;
          if (i >= todo.length) return;
          final name = todo[i];
          final existed = _localLogos.contains(name);
          final ok = await _downloadLogo(name, client);
          if (ok) {
            if (existed) replacedExisting = true;
            _localLogos.add(name);
            _localTokens[name] = remote[name] ?? '';
            _failed.remove(name);
            if (++sinceNotify >= 25) {
              sinceNotify = 0;
              _bump();
            }
          }
        }
      }

      await Future.wait(List.generate(6, (_) => worker()));

      // Remove logos that no longer exist in the repository.
      if (remote.length >= 10) {
        for (final name in _localLogos.toList()) {
          if (remote.containsKey(name)) continue;
          try { await File('${_logoDir!.path}/$name').delete(); } catch (_) {}
          _localLogos.remove(name);
          _localTokens.remove(name);
        }
      }
      if (replacedExisting) PaintingBinding.instance.imageCache.clear();

      _remoteLogos = remote;
      _logoSyncedAt = DateTime.now().millisecondsSinceEpoch;
      await _saveLogoManifest();
      _bump();
      debugPrint('Logo sync done: ${_localLogos.length}/${remote.length} stored, ${todo.length} updated');
    } catch (error) {
      debugPrint('Logo sync failed: $error');
    } finally {
      client.close();
      _syncing = false;
    }
  }

  Future<Map<String, String>?> _fetchRemoteListing(http.Client client) async {
    // 1) GitHub tree API (exact blob SHAs).
    try {
      final response = await client.get(
        Uri.parse('https://api.github.com/repos/$_repoOwner/$_repoName/git/trees/$_repoBranch?recursive=1'),
        headers: const {'Accept': 'application/vnd.github+json', 'User-Agent': _userAgent},
      ).timeout(const Duration(seconds: 25));
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        final tree = decoded is Map ? decoded['tree'] : null;
        if (tree is List) {
          final out = <String, String>{};
          for (final item in tree) {
            if (item is! Map) continue;
            final path = item['path']?.toString() ?? '';
            if (item['type'] != 'blob' || !path.startsWith('$_logoFolder/')) continue;
            final name = path.substring(_logoFolder.length + 1);
            if (!_validLogoName(name)) continue;
            out[name] = item['sha']?.toString() ?? '';
          }
          if (out.isNotEmpty) return out;
        }
      }
    } catch (error) {
      debugPrint('GitHub logo listing failed: $error');
    }
    // 2) jsDelivr file listing (no API rate limit) as a fallback.
    try {
      final response = await client.get(
        Uri.parse('https://data.jsdelivr.com/v1/packages/gh/$_repoOwner/$_repoName@$_repoBranch?structure=flat'),
        headers: const {'User-Agent': _userAgent},
      ).timeout(const Duration(seconds: 25));
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        final files = decoded is Map ? decoded['files'] : null;
        if (files is List) {
          final out = <String, String>{};
          for (final item in files) {
            if (item is! Map) continue;
            final path = item['name']?.toString() ?? '';
            final prefix = '/$_logoFolder/';
            if (!path.startsWith(prefix)) continue;
            final name = path.substring(prefix.length);
            if (!_validLogoName(name)) continue;
            out[name] = item['hash']?.toString() ?? '';
          }
          if (out.isNotEmpty) return out;
        }
      }
    } catch (error) {
      debugPrint('jsDelivr logo listing failed: $error');
    }
    return null;
  }

  Future<void> _saveLogoManifest() async {
    final root = _logoDir!.parent;
    await _atomicWrite(
      File('${root.path}/logos_manifest.json'),
      utf8.encode(jsonEncode({
        'savedAt': _logoSyncedAt,
        'remote': _remoteLogos,
        'local': _localTokens,
      })),
    );
  }

  // ------------------------------------------------------------------
  // EPG
  // ------------------------------------------------------------------

  /// Makes sure the local copy of an EPG source is current.
  ///
  /// Sends If-None-Match / If-Modified-Since so an unchanged file is not
  /// downloaded again. When offline, the stored copy is returned so the guide
  /// can still be rebuilt. Returns null if there is neither network nor a copy.
  Future<EpgFile?> fetchEpg(String url) async {
    await init();
    if (!_ready) return null;
    final key = _epgKey(url);
    final file = File('${_epgDir!.path}/$key');
    final exists = await file.exists();
    final meta = (_epgMeta[key] is Map) ? Map<String, dynamic>.from(_epgMeta[key] as Map) : <String, dynamic>{};
    try {
      final headers = <String, String>{
        'User-Agent': _userAgent,
        'Accept': '*/*',
        'Accept-Encoding': 'gzip',
      };
      if (exists) {
        final etag = meta['etag']?.toString() ?? '';
        final modified = meta['lastModified']?.toString() ?? '';
        if (etag.isNotEmpty) headers['If-None-Match'] = etag;
        if (modified.isNotEmpty) headers['If-Modified-Since'] = modified;
      }
      final response = await http.get(Uri.parse(url), headers: headers).timeout(const Duration(seconds: 45));
      if (response.statusCode == 304 && exists) {
        return EpgFile(file, changed: false, offline: false);
      }
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        var changed = true;
        if (exists && await file.length() == response.bodyBytes.length) {
          final old = await file.readAsBytes();
          if (listEquals(old, response.bodyBytes)) changed = false;
        }
        if (changed) await _atomicWrite(file, response.bodyBytes);
        _epgMeta[key] = <String, dynamic>{
          'etag': response.headers['etag'] ?? '',
          'lastModified': response.headers['last-modified'] ?? '',
          'savedAt': DateTime.now().millisecondsSinceEpoch,
        };
        unawaited(_saveEpgMeta());
        return EpgFile(file, changed: changed, offline: false);
      }
    } catch (error) {
      debugPrint('EPG download failed ($url): $error');
    }
    if (exists) return EpgFile(file, changed: false, offline: true);
    return null;
  }

  /// Forget the HTTP validators of a source whose stored file could not be
  /// parsed, so the next refresh downloads it again unconditionally.
  void invalidateEpg(String url) {
    _epgMeta.remove(_epgKey(url));
    unawaited(_saveEpgMeta());
  }

  Future<void> _saveEpgMeta() async {
    try {
      final root = _epgDir!.parent;
      await _atomicWrite(File('${root.path}/epg_meta.json'), utf8.encode(jsonEncode(_epgMeta)));
    } catch (error) {
      debugPrint('EPG meta not saved: $error');
    }
  }

  File? get _parsedGuideFile =>
      _epgDir == null ? null : File('${_epgDir!.path}/guide_parsed_v2.json');

  /// The parsed 3-day guide saved by the last successful refresh.
  Future<String?> readParsedGuide() async {
    await init();
    try {
      final file = _parsedGuideFile;
      if (file == null || !await file.exists()) return null;
      return await file.readAsString();
    } catch (error) {
      debugPrint('Parsed guide unreadable: $error');
      return null;
    }
  }

  Future<void> writeParsedGuide(String json) async {
    await init();
    try {
      final file = _parsedGuideFile;
      if (file == null) return;
      await _atomicWrite(file, utf8.encode(json));
    } catch (error) {
      debugPrint('Parsed guide not saved: $error');
    }
  }

  // ------------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------------
  void _bump() => revision.value++;

  static String _baseName(String path) => path.substring(path.lastIndexOf('/') + 1);

  static bool _validLogoName(String name) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*\.(png|jpe?g|webp)$', caseSensitive: false).hasMatch(name);

  static String _epgKey(String url) {
    final safe = url.replaceAll(RegExp(r'[^A-Za-z0-9.]+'), '_');
    return safe.length > 90 ? safe.substring(safe.length - 90) : safe;
  }

  static Map<String, String> _stringMap(dynamic raw) {
    if (raw is! Map) return <String, String>{};
    return raw.map<String, String>((key, value) => MapEntry(key.toString(), value.toString()));
  }

  static Future<Map<String, dynamic>?> _readJson(File file) async {
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _atomicWrite(File target, List<int> bytes) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(target.path);
  }
}
