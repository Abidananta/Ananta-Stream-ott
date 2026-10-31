import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter, PlatformDispatcher;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'update_checker.dart';
import 'notice_banner.dart';
import 'splash_screen.dart';
import 'glass.dart';
import 'exo_player.dart';
import 'animated_tv_logo.dart';
import 'local_store.dart';
import 'logo_badge.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

const String appName = 'Ananta OTT';
const MethodChannel _pipChannel = MethodChannel('com.ananta.ott/pip');
const String playlistUrl =
    'https://raw.githubusercontent.com/anantaabid24/Ananta-Ott/refs/heads/main/channels.m3u';
const String ptvStreamUrl =
    'http://103.185.24.134:3001/ptv/index.m3u8';
const List<String> epgSourceUrls = [
  'https://avkb.short.gy/tsepg.xml.gz',
  'https://avkb.short.gy/jioepg.xml.gz',
  'https://avkb.short.gy/epg.xml.gz',
];

const Color accentColor = Color(0xFF9B87FF);
const Color backgroundColor = Color(0xFF090914);
const Color glassColor = Color(0xFF211F35);
// Live blur over the video costs GPU time on weak TV boxes. The TV panels use
// the same frosted-glass gradient without live blur by default; set to true
// for a real blur on powerful devices.
const bool kTvLiveBlur = false;

String _epgAttribute(String text, String name) {
  final match = RegExp('\\b${RegExp.escape(name)}\\s*=\\s*["\\x27]([^"\\x27]*)', caseSensitive: false).firstMatch(text);
  return match?.group(1) ?? '';
}

String _epgDecodeText(String value) => value
    .replaceAll('<![CDATA[', '')
    .replaceAll(']]>', '')
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&')
    .trim();

String _epgTagText(String block, String tag) {
  final match = RegExp('<$tag\\b[^>]*>(.*?)</$tag>', caseSensitive: false, dotAll: true).firstMatch(block);
  return match == null ? '' : _epgDecodeText(match.group(1) ?? '');
}

DateTime? _epgParseTime(String value) {
  final match = RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(?:\s*([+-])(\d{2})(\d{2}))?').firstMatch(value.trim());
  if (match == null) return null;
  try {
    final clockAsUtc = DateTime.utc(
      int.parse(match.group(1)!), int.parse(match.group(2)!), int.parse(match.group(3)!),
      int.parse(match.group(4)!), int.parse(match.group(5)!), int.parse(match.group(6)!),
    );
    final sign = match.group(7);
    if (sign == null) return clockAsUtc;
    final offset = int.parse(match.group(8)!) * 60 + int.parse(match.group(9)!);
    return clockAsUtc.subtract(Duration(minutes: sign == '+' ? offset : -offset));
  } catch (_) {
    return null;
  }
}

// Runs in a background isolate so decompression and XMLTV scanning do not
// block the TV player's frame rendering.
Map<String, dynamic> _parseEpgPayload(List<int> payload) {
  var bytes = payload;
  if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
    bytes = gzip.decode(bytes);
  }
  final xml = utf8.decode(bytes, allowMalformed: true);
  final namesById = <String, List<String>>{};
  final logosById = <String, String>{};
  final channelPattern = RegExp(r'<channel\b([^>]*)>(.*?)</channel\s*>', caseSensitive: false, dotAll: true);
  for (final match in channelPattern.allMatches(xml)) {
    final id = _epgAttribute(match.group(1) ?? '', 'id').trim();
    if (id.isEmpty) continue;
    final names = RegExp(r'<display-name\b[^>]*>(.*?)</display-name\s*>', caseSensitive: false, dotAll: true)
        .allMatches(match.group(2) ?? '')
        .map((m) => _epgDecodeText(m.group(1) ?? ''))
        .where((name) => name.isNotEmpty).toSet().toList();
    if (names.isNotEmpty) namesById[id] = names;
    final iconMatch = RegExp(r'<icon\b([^>]*)\/?\s*>', caseSensitive: false).firstMatch(match.group(2) ?? '');
    final iconUrl = _epgAttribute(iconMatch?.group(1) ?? '', 'src').trim();
    if (iconUrl.startsWith('https://') || iconUrl.startsWith('http://')) logosById[id] = iconUrl;
  }
  final now = DateTime.now().toUtc();
  final programmes = <Map<String, dynamic>>[];
  final programmePattern = RegExp(r'<programme\b([^>]*)>(.*?)</programme\s*>', caseSensitive: false, dotAll: true);
  for (final match in programmePattern.allMatches(xml)) {
    final attrs = match.group(1) ?? '';
    final body = match.group(2) ?? '';
    final id = _epgAttribute(attrs, 'channel').trim();
    if (id.isEmpty) continue;
    final start = _epgParseTime(_epgAttribute(attrs, 'start'));
    final stop = _epgParseTime(_epgAttribute(attrs, 'stop'));
    if (start == null || stop == null ||
        !stop.isAfter(now.subtract(const Duration(days: 3))) ||
        start.isAfter(now.add(const Duration(days: 3)))) continue;
    final title = _epgTagText(body, 'title');
    if (title.isEmpty) continue;
    programmes.add(<String, dynamic>{
      'id': id,
      'title': title,
      'description': _epgTagText(body, 'desc'),
      'start': start.millisecondsSinceEpoch,
      'stop': stop.millisecondsSinceEpoch,
    });
  }
  return <String, dynamic>{'namesById': namesById, 'logosById': logosById, 'programmes': programmes};
}

Map<String, List<EpgProgram>> _epgMapFromJsonTop(dynamic raw) {
  final result = <String, List<EpgProgram>>{};
  if (raw is! Map) return result;
  // Keep a rolling three-day guide on device: programmes that have ended
  // are discarded, while the current and next three days remain available.
  final now = DateTime.now().toUtc();
  final cutoff = now.subtract(const Duration(hours: 6));
  final horizon = now.add(const Duration(days: 3));
  for (final entry in raw.entries) {
    if (entry.value is! List) continue;
    final list = <EpgProgram>[];
    for (final item in entry.value as List) {
      if (item is! Map) continue;
      try {
        final start = DateTime.fromMillisecondsSinceEpoch(item['start'] as int, isUtc: true);
        final stop = DateTime.fromMillisecondsSinceEpoch(item['stop'] as int, isUtc: true);
        if (!stop.isAfter(cutoff) || start.isAfter(horizon)) continue;
        list.add(EpgProgram(
          title: item['title']?.toString() ?? '',
          description: item['description']?.toString() ?? '',
          start: start,
          stop: stop,
        ));
      } catch (_) {}
    }
    list.sort((a, b) => a.start.compareTo(b.start));
    if (list.isNotEmpty) result[entry.key.toString()] = list;
  }
  return result;
}

// Decodes the saved EPG cache off the UI thread.
Map<String, dynamic> _decodeEpgCacheIsolate(String cached) {
  final decoded = jsonDecode(cached);
  if (decoded is! Map) return const <String, dynamic>{};
  Map<String, String> logos(dynamic raw) => raw is Map
      ? raw.map<String, String>((k, v) => MapEntry(k.toString(), v.toString()))
      : <String, String>{};
  return <String, dynamic>{
    'savedAt': decoded['savedAt'] is int ? decoded['savedAt'] : 0,
    'byId': _epgMapFromJsonTop(decoded['byId']),
    'byName': _epgMapFromJsonTop(decoded['byName']),
    'logosById': logos(decoded['logosById']),
    'logosByName': logos(decoded['logosByName']),
  };
}

// ---- Playlist prefetch (runs while the splash animation plays) ------------
List<Channel> _parseM3uIsolate(String content) {
  String attr(String line, String attribute) {
    final pattern = RegExp('$attribute\\s*=\\s*["\\x27]([^"\\x27]*)', caseSensitive: false);
    return pattern.firstMatch(line)?.group(1) ?? '';
  }
  final result = <Channel>[];
  String? name;
  String group = 'Live TV';
  String logo = '';
  String tvgId = '';
  String tvgName = '';
  for (final rawLine in content.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXTINF')) {
      final comma = line.lastIndexOf(',');
      name = comma >= 0 ? line.substring(comma + 1).trim() : 'Unknown channel';
      group = attr(line, 'group-title');
      logo = attr(line, 'tvg-logo');
      tvgId = attr(line, 'tvg-id');
      tvgName = attr(line, 'tvg-name');
      if (group.isEmpty) group = 'Live TV';
    } else if (!line.startsWith('#') && name != null) {
      final uri = Uri.tryParse(line);
      if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty) {
        result.add(Channel(name: name, url: line, group: group, logo: logo, tvgId: tvgId, tvgName: tvgName));
      }
      name = null;
      group = 'Live TV';
      logo = '';
      tvgId = '';
      tvgName = '';
    }
  }
  return result;
}

Future<List<Channel>> _fetchAndParsePlaylist() async {
  final baseUri = Uri.parse(playlistUrl);
  final query = Map<String, String>.from(baseUri.queryParameters);
  query['_refresh'] = DateTime.now().millisecondsSinceEpoch.toString();
  final response = await http
      .get(baseUri.replace(queryParameters: query), headers: const {
        'User-Agent': 'AnantaOTT/1.0',
        'Accept': '*/*',
        'Cache-Control': 'no-cache',
        'Pragma': 'no-cache',
      })
      .timeout(const Duration(seconds: 25));
  if (response.statusCode != 200) {
    throw Exception('Playlist server returned HTTP ${response.statusCode}');
  }
  final parsed = await compute(_parseM3uIsolate, response.body);
  if (parsed.isEmpty) throw Exception('No valid channels found in the M3U file.');
  return parsed;
}

Future<List<Channel>>? _prefetchedPlaylist;
void _startPlaylistPrefetch() {
  final f = _fetchAndParsePlaylist();
  _prefetchedPlaylist = f;
  // Avoid an unhandled-error crash if nobody awaits it (the page falls back
  // to its own fetch when the prefetch failed).
  f.then<void>((_) {}, onError: (Object e) { debugPrint('Playlist prefetch failed: $e'); });
}

// Online crash/error reporting (Sentry). The DSN is injected at build time
// (--dart-define=SENTRY_DSN=...) or uses the default below. Empty disables it.
const String _sentryDsn = String.fromEnvironment(
  'SENTRY_DSN',
  defaultValue:
      'https://1f47bca2ee1bb03fcc7cfe60d0e97b5e@o4512278363111424.ingest.us.sentry.io/4512278716743680',
);
final RegExp _urlPattern = RegExp(r'https?://\S+');

String _scrub(String? v) => (v ?? '').replaceAll(_urlPattern, '[url]');

Future<void> _startApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  ErrorWidget.builder = (details) => const SizedBox.shrink();
  _startPlaylistPrefetch();
  runApp(const AnantaOttApp());
}

Future<void> main() async {
  if (_sentryDsn.isEmpty) {
    // Crash-safe startup without reporting.
    runZonedGuarded<void>(() => _startApp(),
        (error, stack) => debugPrint('Zone error: $error'));
    return;
  }
  await SentryFlutter.init(
    (options) {
      options.dsn = _sentryDsn;
      options.sendDefaultPii = false;
      options.attachScreenshot = false;
      options.tracesSampleRate = 0;
      options.maxBreadcrumbs = 30;
      options.environment = kReleaseMode ? 'release' : 'debug';
      // Never send stream/playlist URLs: drop network breadcrumbs and strip
      // links from error messages.
      options.beforeBreadcrumb = (crumb, hint) {
        final c = crumb?.category ?? '';
        if (c == 'http' || c == 'xhr' || c == 'navigation') return null;
        return crumb;
      };
      options.beforeSend = (event, hint) {
        final exceptions = event.exceptions
            ?.map((e) => e.copyWith(value: _scrub(e.value)))
            .toList();
        return event.copyWith(exceptions: exceptions);
      };
    },
    appRunner: () => _startApp(),
  );
}

final ValueNotifier<Size> _noVideoSize = ValueNotifier<Size>(Size.zero);

/// Quality label from the real decoded video size (width is checked too so
/// wide-cropped 1080p such as 1920x800 is still FHD).
String? _videoQualityLabel(Size size) {
  final w = size.width, h = size.height;
  if (w <= 0 || h <= 0) return null;
  if (w >= 3200 || h >= 2000) return '4K';
  if (w >= 2400 || h >= 1400) return '2K';
  if (w >= 1800 || h >= 1000) return 'FHD';
  if (w >= 1200 || h >= 700) return 'HD';
  return 'SD';
}

Widget _qualityBadge(Size size) {
  final label = _videoQualityLabel(size);
  if (label == null) return const SizedBox.shrink();
  final color = switch (label) {
    '4K' => const Color(0xFFFFC107),
    '2K' => const Color(0xFFFF9800),
    'FHD' => const Color(0xFF4CAF50),
    'HD' => const Color(0xFF42A5F5),
    _ => Colors.white54,
  };
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: color.withOpacity(0.18),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color.withOpacity(0.8), width: 1.2),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.8, color: color),
    ),
  );
}

/// Sizes the player to the device: full screen when [fullscreen], otherwise a
/// 16:9 box spanning the full width (capped so it never eats the whole screen).
class _PlayerBox extends StatelessWidget {
  final bool fullscreen;
  final Color color;
  final Widget child;
  const _PlayerBox({required this.fullscreen, required this.color, required this.child});
  @override
  Widget build(BuildContext context) {
    if (fullscreen) {
      return Container(width: double.infinity, height: double.infinity, color: color, child: child);
    }
    final media = MediaQuery.of(context);
    final w = media.size.width;
    final maxH = media.size.height * 0.45;
    final h = (w * 9 / 16).clamp(0.0, maxH).toDouble();
    return Container(width: double.infinity, height: h, color: color, child: child);
  }
}

class Channel {
  final String name;
  final String url;
  final String group;
  final String logo;
  final String tvgId;
  final String tvgName;
  const Channel({
    required this.name,
    required this.url,
    this.group = 'Live TV',
    this.logo = '',
    this.tvgId = '',
    this.tvgName = '',
  });
}

class EpgProgram {
  final String title;
  final String description;
  final DateTime start;
  final DateTime stop;
  const EpgProgram({
    required this.title,
    required this.description,
    required this.start,
    required this.stop,
  });

  bool isAiringAt(DateTime time) => !time.isBefore(start) && time.isBefore(stop);
}

const Channel ptvChannel = Channel(
  name: 'PTV ',
  url: ptvStreamUrl,
  group: 'Sports',
);

class AnantaOttApp extends StatelessWidget {
  const AnantaOttApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        visualDensity: VisualDensity.standard,
        materialTapTargetSize: MaterialTapTargetSize.padded,
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: backgroundColor,
        colorScheme: ColorScheme.fromSeed(
          seedColor: accentColor,
          brightness: Brightness.dark,
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xE61B1832),
          contentTextStyle: const TextStyle(color: Colors.white),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.white.withOpacity(0.16)),
          ),
        ),
      ),
      home: AnantaSplashScreen(next: (_) => const AnantaHomePage()),
    );
  }
}

class AnantaHomePage extends StatefulWidget {
  const AnantaHomePage({super.key});
  @override
  State<AnantaHomePage> createState() => _AnantaHomePageState();
}

class _AnantaHomePageState extends State<AnantaHomePage> with WidgetsBindingObserver {
  final TextEditingController _searchController = TextEditingController();
  List<Channel> _channels = [ptvChannel];
  Set<String> _favorites = {};
  AnantaPlayerController? _player;
  AnantaPlayerController? _pendingPlayer;
  Channel? _selectedChannel;
  Timer? _controlsTimer;
  String _selectedCategory = 'All';
  String _searchQuery = '';
  String _status = 'Ready';
  String? _playerError;
  bool _loadingPlaylist = false;
  bool _connecting = false;
  bool _showFavoritesOnly = false;
  bool _controlsVisible = true;
  bool _fullscreen = false;
  bool _fullscreenTransitioning = false;
  bool _fullscreenOnTv = false;
  // TV starts with an unobstructed full-screen player; Enter opens the rail.
  bool _tvSidebarVisible = false;
  bool _tvShowingCategories = false;
  bool _tvEpgVisible = false;
  bool _tvEpgSelectionMode = false;
  bool _channelInfoVisible = false;
  Timer? _channelInfoTimer;
  bool _epgLoading = false;
  int _tvFocusedEpgIndex = 0;
  int _tvEpgSelectedDayOffset = 0;
  // Which (channel, day) the guide list was last auto-positioned for, so the
  // list jumps to the programme that is on air whenever the guide is opened.
  String _tvEpgAnchor = '';
  int _tvEpgAnchorIndex = 0;
  final GlobalKey _tvEpgAnchorKey = GlobalKey();
  int _tvFocusedChannelIndex = 0;
  int _tvFocusedCategoryIndex = 0;
  final ScrollController _tvChannelScrollController = ScrollController();
  final ScrollController _tvCategoryScrollController = ScrollController();
  final FocusNode _tvPlayerFocusNode = FocusNode(debugLabel: 'tv-player');
  final FocusNode _tvSearchFocusNode = FocusNode(debugLabel: 'tv-channel-search');
  final Map<String, FocusNode> _tvChannelFocusNodes = {};
  Map<String, List<EpgProgram>> _epgById = {};
  Map<String, List<EpgProgram>> _epgByName = {};
  Map<String, List<EpgProgram>> _epgByChannelUrl = {};
  Map<String, String> _epgLogosById = {};
  Map<String, String> _epgLogosByName = {};
  Map<String, String> _indiaLogosByName = {};
  bool _indiaLogoIndexLoading = false;
  String _epgStatus = 'Loading programme guide…';
  Timer? _epgClock;
  Timer? _epgRefreshTimer;
  Timer? _storeNotifyTimer;
  int _epgSavedAt = 0;
  bool _epgInitDone = false;
  final Map<String, String> _logoUrlCache = {};
  Timer? _playbackHealthTimer;
  DateTime? _bufferingStartedAt;
  int _runtimeRetryCount = 0;
  final ScrollController _tvEpgScrollController = ScrollController();
  int _playlistRequestId = 0;
  int _playRequestId = 0;
  // Picture-in-Picture state (Android 8+). While true, only the video is drawn.
  bool _inPip = false;
  bool _pausedForBackground = false;
  bool _userPaused = false;
  int _stallTicks = 0;
  Duration? _lastHealthPosition;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pipChannel.setMethodCallHandler(_onPipCall);
    // Check the hosted version manifest after the first frame so update prompts
    // can safely use this page's BuildContext.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        AppUpdateChecker.checkForUpdate(context).then((_) {
          if (mounted) _focusTvPlayer(); // give the remote back to the player
        });
      }
    });
    // Announcement banner (phones/tablets; the native side ignores TV).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) NoticeService.instance.start(context);
    });
    _loadFavorites();
    _loadPlaylist();
    // Local storage for the EPG files and the channel_logos folder. Logos that
    // are already on the device are shown from disk immediately.
    LocalStore.instance.revision.addListener(_onStoreChanged);
    unawaited(LocalStore.instance.init().then((_) {
      if (mounted) setState(() {});
    }));
    Future<void>.delayed(const Duration(seconds: 12), () {
      if (mounted) unawaited(LocalStore.instance.syncLogos());
    });
    // Heavy guide work starts after the first channel is on screen, so channel
    // opening and the first frames stay smooth.
    Future<void>.delayed(const Duration(seconds: 8), () {
      if (mounted) _initializeEpg();
    });
    // Keep the TV player key handler focused from the first frame so physical
    // Android TV remotes can deliver D-pad events even before the first tap.
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusTvPlayer());
    _epgClock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    _epgRefreshTimer = Timer.periodic(const Duration(hours: 2), (_) {
      unawaited(_loadEpg());
      unawaited(LocalStore.instance.syncLogos()); // self-throttled to 12 h
    });
    // Watchdog: reconnect automatically when a live stream errors, ends,
    // freezes (position stops advancing) or buffers for too long.
    _playbackHealthTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || _connecting || _selectedChannel == null) return;
      if (_userPaused || _pausedForBackground) {
        _stallTicks = 0;
        _lastHealthPosition = null;
        return;
      }
      final player = _player;
      if (player == null) return;
      final value = player.value;
      var needsRecovery = value.hasError || value.isCompleted;
      if (!needsRecovery) {
        if (value.isBuffering) {
          _bufferingStartedAt ??= DateTime.now();
          _stallTicks = 0;
          if (DateTime.now().difference(_bufferingStartedAt!) >= const Duration(seconds: 24)) {
            needsRecovery = true;
          }
        } else {
          _bufferingStartedAt = null;
          final position = value.position;
          final frozen = !value.isPlaying ||
              (_lastHealthPosition != null && position == _lastHealthPosition);
          _lastHealthPosition = position;
          if (frozen) {
            if (++_stallTicks >= 3) needsRecovery = true;
          } else {
            _stallTicks = 0;
            _runtimeRetryCount = 0;
          }
        }
      }
      if (needsRecovery && _runtimeRetryCount < 10) {
        _runtimeRetryCount++;
        _stallTicks = 0;
        _bufferingStartedAt = null;
        _lastHealthPosition = null;
        debugPrint('Stream stalled; reconnecting (attempt $_runtimeRetryCount)');
        _playChannel(_selectedChannel!, retryAttempt: _runtimeRetryCount);
      }
    });
  }

  // Xiaomi Mi Box / Android TV remote handling. Focus and index are managed
  // explicitly, and KeyRepeatEvent is supported so held D-pad directions browse
  // long channel lists smoothly rather than moving only one row per press.
  void _focusTvChannel(int index, {bool requestFocus = true}) {
    final channels = _visibleChannels;
    if (channels.isEmpty) return;
    final safeIndex = index.clamp(0, channels.length - 1).toInt();
    setState(() {
      _tvFocusedChannelIndex = safeIndex;
      _tvSidebarVisible = true;
      _tvEpgVisible = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_tvChannelScrollController.hasClients) return;
      // Scroll first so ListView builds the destination row before requesting
      // its FocusNode. Requesting focus before this point fails for off-screen
      // rows and makes UP/DOWN appear to stop working on Android TV.
      // Use an immediate scroll for D-pad repeat events. Queuing an animation
      // for every repeated key caused focus to lag behind the remote on Mi Box.
      final target = (safeIndex * 96.0).clamp(
        0.0,
        _tvChannelScrollController.position.maxScrollExtent,
      ).toDouble();
      if ((_tvChannelScrollController.offset - target).abs() > 1) {
        _tvChannelScrollController.jumpTo(target);
      }
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !requestFocus) return;
      final node = _tvChannelFocusNodes[channels[safeIndex].url];
      if (node != null && node.canRequestFocus) node.requestFocus();
    });
  }

  void _focusTvPlayer() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tvPlayerFocusNode.canRequestFocus) return;
      // The update dialog owns the remote while it is open.
      if (AppUpdateChecker.dialogOpen.value) return;
      _tvPlayerFocusNode.requestFocus();
    });
  }

  void _focusTvCategory(int index) {
    final categories = _categories;
    if (categories.isEmpty) return;
    setState(() {
      _tvSidebarVisible = true;
      _tvShowingCategories = true;
      _tvFocusedCategoryIndex = index.clamp(0, categories.length - 1).toInt();
    });
    FocusManager.instance.primaryFocus?.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tvCategoryScrollController.hasClients) return;
      final target = (_tvFocusedCategoryIndex * 58.0).clamp(
        0.0, _tvCategoryScrollController.position.maxScrollExtent,
      ).toDouble();
      if ((_tvCategoryScrollController.offset - target).abs() > 1) {
        _tvCategoryScrollController.jumpTo(target);
      }
    });
    _focusTvPlayer();
  }

  void _moveTvCategory(int delta) {
    final categories = _categories;
    if (categories.isEmpty) return;
    setState(() {
      _tvFocusedCategoryIndex =
          (_tvFocusedCategoryIndex + delta).clamp(0, categories.length - 1).toInt();
    });
    // Keep the currently focused player key handler active while browsing;
    // do not unfocus/refocus on every repeated D-pad event.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tvCategoryScrollController.hasClients) return;
      final target = (_tvFocusedCategoryIndex * 58.0).clamp(
        0.0, _tvCategoryScrollController.position.maxScrollExtent,
      ).toDouble();
      if ((_tvCategoryScrollController.offset - target).abs() > 1) {
        _tvCategoryScrollController.jumpTo(target);
      }
    });
  }

  void _showTvChannels({int? index}) {
    if (!mounted) return;
    final channels = _visibleChannels;
    final safeIndex = channels.isEmpty
        ? 0
        : (index ?? _tvFocusedChannelIndex).clamp(0, channels.length - 1).toInt();
    // One state update only: the old implementation called _focusTvChannel,
    // which performed a second setState and another scroll/focus pass on every
    // Enter press. On low-memory TV boxes that made the live video stutter.
    setState(() {
      _tvShowingCategories = false;
      _tvSidebarVisible = true;
      _tvEpgVisible = false;
      _tvEpgSelectionMode = false;
      _tvFocusedChannelIndex = safeIndex;
    });
    FocusManager.instance.primaryFocus?.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_tvChannelScrollController.hasClients || channels.isEmpty) return;
      final maxExtent = _tvChannelScrollController.position.maxScrollExtent;
      final target = (safeIndex * 96.0).clamp(0.0, maxExtent).toDouble();
      if ((_tvChannelScrollController.offset - target).abs() > 1) {
        _tvChannelScrollController.jumpTo(target);
      }
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final focus = _tvChannelFocusNodes[channels[safeIndex].url];
      if (focus != null && focus.canRequestFocus) focus.requestFocus();
    });
  }

  void _showChannelInfoFor10Seconds() {
    _channelInfoTimer?.cancel();
    if (!mounted) return;
    setState(() => _channelInfoVisible = true);
    _channelInfoTimer = Timer(const Duration(seconds: 15), () {
      if (mounted) setState(() => _channelInfoVisible = false);
    });
  }

  void _moveTvEpgSelection(int delta, Channel channel) {
    final schedule = _tvEpgDaySchedule(channel);
    if (schedule.isEmpty) return;
    _tvFocusedEpgIndex = (_tvFocusedEpgIndex + delta).clamp(0, schedule.length - 1).toInt();
    _scrollTvEpgToIndex(_tvFocusedEpgIndex);
    if (mounted) setState(() {});
  }

  void _scrollTvEpgToIndex(int index) {
    if (!_tvEpgScrollController.hasClients) return;
    final position = _tvEpgScrollController.position;
    // Guide rows have variable height; this estimate keeps keyboard selection
    // near the viewport while ListView remains the source of truth for scrolling.
    final target = (index * 118.0).clamp(0.0, position.maxScrollExtent).toDouble();
    _tvEpgScrollController.animateTo(target,
        duration: const Duration(milliseconds: 110), curve: Curves.easeOut);
  }

  void _scrollTvEpg(int delta) {
    if (!_tvEpgScrollController.hasClients) return;
    final position = _tvEpgScrollController.position;
    final target = (_tvEpgScrollController.offset + delta * 150.0)
        .clamp(0.0, position.maxScrollExtent).toDouble();
    _tvEpgScrollController.animateTo(target,
        duration: const Duration(milliseconds: 120), curve: Curves.easeOut);
  }

  KeyEventResult _handleRemoteKey(FocusNode node, KeyEvent event) {
    if (AppUpdateChecker.dialogOpen.value) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final primaryContext = FocusManager.instance.primaryFocus?.context;
    final key = event.logicalKey;
    final isUpKey = key == LogicalKeyboardKey.arrowUp;
    final isDownKey = key == LogicalKeyboardKey.arrowDown;
    final isConfirmKey = key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA;
    // Some TV remotes emit confirm-key repeat events when the button is held.
    // Do not repeatedly rebuild the sidebar or issue duplicate playback requests.
    if (isConfirmKey && event is KeyRepeatEvent) return KeyEventResult.handled;
    final channels = _visibleChannels;
    final categories = _categories;
    final editingSearch = primaryContext?.widget is EditableText;

    // Search remains usable with the TV keyboard. D-pad UP opens categories;
    // DOWN moves into results, avoiding a focus trap inside the text field.
    if (editingSearch) {
      if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.gameButtonA) {
        FocusManager.instance.primaryFocus?.unfocus();
        _showTvChannels(index: 0);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        FocusManager.instance.primaryFocus?.unfocus();
        _showTvChannels(index: 0);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        _focusTvCategory(_categories.indexOf(_selectedCategory).clamp(0, categories.length - 1).toInt());
        return KeyEventResult.handled;
      }
      if (key != LogicalKeyboardKey.escape && key != LogicalKeyboardKey.browserBack) {
        return KeyEventResult.ignored;
      }
    }

    if (isUpKey || isDownKey) {
      final delta = isDownKey ? 1 : -1;
      if (_tvSidebarVisible && _tvEpgVisible && !_tvShowingCategories) {
        final preview = _tvEpgPreviewChannel(channels);
        if (_tvEpgSelectionMode && preview != null) {
          _moveTvEpgSelection(delta, preview);
        } else {
          _scrollTvEpg(delta);
        }
        return KeyEventResult.handled;
      }
      if (!_tvSidebarVisible && isUpKey) {
        if (_selectedChannel != null) _showChannelInfoFor10Seconds();
        // Reclaim focus after the remote event so subsequent D-pad presses
        // continue to reach the player handler rather than a stale overlay.
        _focusTvPlayer();
        return KeyEventResult.handled;
      }
      if (_tvShowingCategories) {
        _moveTvCategory(delta);
        return KeyEventResult.handled;
      }
      if (channels.isEmpty) return KeyEventResult.handled;
      if (!_tvSidebarVisible) {
        // The hidden rail is deliberately inert. Only Enter/Select may open it;
        // directional keys must never zap or reveal channels unexpectedly.
        return KeyEventResult.handled;
      }
      final currentFocus = FocusManager.instance.primaryFocus;
      if (currentFocus == _tvSearchFocusNode) {
        FocusManager.instance.primaryFocus?.unfocus();
        _showTvChannels(index: 0);
      } else {
        _focusTvChannel((_tvFocusedChannelIndex + delta).clamp(0, channels.length - 1).toInt());
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.gameButtonA) {
      if (!_tvSidebarVisible) {
        final current = channels.indexWhere((c) => c.url == _selectedChannel?.url);
        _showTvChannels(index: current >= 0 ? current : _tvFocusedChannelIndex);
      } else if (_tvSidebarVisible && _tvEpgVisible) {
        // Guide browsing is a separate remote mode. Enter must not zap the
        // channel while the 3-day EPG selection rail is active.
        return KeyEventResult.handled;
      } else if (_tvShowingCategories) {
        if (categories.isNotEmpty) {
          final category = categories[_tvFocusedCategoryIndex.clamp(0, categories.length - 1)];
          setState(() {
            _selectedCategory = category;
            _tvShowingCategories = false;
            _tvFocusedChannelIndex = 0;
          });
          _searchController.clear();
          _searchQuery = '';
          _showTvChannels(index: 0);
        }
      } else if (channels.isNotEmpty) {
        final index = _tvFocusedChannelIndex.clamp(0, channels.length - 1).toInt();
        _playChannel(channels[index]);
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft) {
      if (_tvSidebarVisible && !_tvShowingCategories) {
        setState(() { _tvEpgVisible = false; _tvEpgSelectionMode = false; });
        _focusTvCategory(_categories.indexOf(_selectedCategory).clamp(0, categories.length - 1).toInt());
      } else if (_tvShowingCategories) {
        _showTvChannels(index: _tvFocusedChannelIndex);
      } else {
        // Hidden sidebar: ignore Left. Do not alter channel or player controls.
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowRight) {
      if (_tvShowingCategories) {
        _showTvChannels(index: _tvFocusedChannelIndex);
      } else if (_tvSidebarVisible && !_tvEpgVisible) {
        // First Right opens the 3-day guide without interrupting playback.
        setState(() { _tvEpgVisible = true; _tvEpgSelectionMode = true; _tvFocusedEpgIndex = 0; _tvEpgSelectedDayOffset = 0; _tvEpgAnchor = ''; });
      } else if (_tvSidebarVisible && _tvEpgVisible) {
        // Second Right enables the guide selection rail; Up/Down now browse
        // every programme rather than moving channel focus.
        setState(() => _tvEpgSelectionMode = !_tvEpgSelectionMode);
      } else {
        // Hidden sidebar: ignore Right as well; Enter is the only opener.
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.browserBack) {
      if (_tvShowingCategories) {
        _showTvChannels(index: _tvFocusedChannelIndex);
        return KeyEventResult.handled;
      }
      if (_tvSidebarVisible) {
        setState(() { _tvSidebarVisible = false; _tvEpgVisible = false; _tvEpgSelectionMode = false; });
        FocusManager.instance.primaryFocus?.unfocus();
        _focusTvPlayer();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleChannelTileKey(FocusNode node, KeyEvent event, int index) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final channels = _visibleChannels;

    // A tile can retain focus after the overlay is hidden. Never allow that
    // stale tile focus to select/zap a channel while the sidebar is invisible.
    // Enter's first action in this state is ONLY to reopen the sidebar.
    if (!_tvSidebarVisible) {
      if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.gameButtonA) {
        _showTvChannels(index: _tvFocusedChannelIndex);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
      final delta = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      if (_tvEpgVisible) {
        final preview = _tvEpgPreviewChannel(channels);
        if (_tvEpgSelectionMode && preview != null) {
          _moveTvEpgSelection(delta, preview);
        } else {
          _scrollTvEpg(delta);
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp && index == 0) {
        _tvSearchFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      _focusTvChannel((index + delta).clamp(0, channels.length - 1).toInt());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.gameButtonA) {
      if (_tvEpgVisible) return KeyEventResult.handled;
      if (index >= 0 && index < channels.length) _playChannel(channels[index]);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
      return _handleRemoteKey(node, event);
    }
    return KeyEventResult.ignored;
  }

  // Android TV keeps the video edge-to-edge. The channel rail is an overlay,
  // so showing it never shrinks the player; selecting/zapping hides it immediately.
  Widget _buildTvLayout(List<Channel> channels) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: Focus(
              focusNode: _tvPlayerFocusNode,
              autofocus: true,
              onKeyEvent: _handleRemoteKey,
              child: _buildPlayer(fullscreen: true),
            ),
          ),
        ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          top: 0,
          bottom: 0,
          left: _tvSidebarVisible ? 0 : -330,
          width: 310,
          child: IgnorePointer(
            ignoring: !_tvSidebarVisible,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 100),
              opacity: _tvSidebarVisible ? 1 : 0,
              child: RepaintBoundary(
                child: Glass(
                    borderRadius: const BorderRadius.horizontal(right: Radius.circular(26)),
                    tint: const Color(0xFF14112B),
                    strength: 1.05,
                    blur: kTvLiveBlur ? 18 : 0,
                    child: SafeArea(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Padding(
                            padding: EdgeInsets.fromLTRB(18, 12, 12, 8),
                            child: Row(
                              children: [
                                Icon(Icons.blur_on, color: accentColor, size: 26),
                                SizedBox(width: 8),
                                Expanded(child: Text('ANANTA OTT', style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.0,
                                  fontSize: 16,
                                ))),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                            child: TextField(
                              focusNode: _tvSearchFocusNode,
                              controller: _searchController,
                              textInputAction: TextInputAction.search,
                              onSubmitted: (_) {
                                FocusScope.of(context).unfocus();
                                if (_visibleChannels.isNotEmpty) {
                                  FocusManager.instance.primaryFocus?.unfocus();
                                  _showTvChannels(index: 0);
                                }
                              },
                              onChanged: (value) {
                                setState(() {
                                  _searchQuery = value;
                                  _tvFocusedChannelIndex = 0;
                                  _tvShowingCategories = false;
                                });
                              },
                              style: const TextStyle(fontSize: 14),
                              decoration: InputDecoration(
                                hintText: 'Search channels',
                                prefixIcon: const Icon(Icons.search, size: 20),
                                suffixIcon: _searchQuery.isEmpty ? null : IconButton(
                                  tooltip: 'Clear search',
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() {
                                      _searchQuery = '';
                                      _tvFocusedChannelIndex = 0;
                                    });
                                  },
                                  icon: const Icon(Icons.clear, size: 18),
                                ),
                                filled: true,
                                fillColor: Colors.white.withOpacity(0.07),
                                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: Colors.white.withOpacity(0.10)),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: Colors.white.withOpacity(0.10)),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: const BorderSide(color: accentColor, width: 1.5),
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            child: Row(
                              children: [
                                Expanded(child: Text(_tvShowingCategories ? 'CATEGORIES' : 'CHANNELS', style: const TextStyle(
                                  color: Colors.white70, fontSize: 11,
                                  fontWeight: FontWeight.bold, letterSpacing: 1.2,
                                ))),
                                Text(_tvShowingCategories ? '${_categories.length}' : '${channels.length}', style: const TextStyle(
                                  color: Colors.white54, fontSize: 11,
                                )),
                                IconButton(
                                  tooltip: _tvShowingCategories ? 'Show channels' : 'Browse categories',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () {
                                    if (_tvShowingCategories) { _showTvChannels(index: _tvFocusedChannelIndex); }
                                    else { _focusTvCategory(_categories.indexOf(_selectedCategory).clamp(0, _categories.length - 1).toInt()); }
                                  },
                                  icon: Icon(_tvShowingCategories ? Icons.live_tv : Icons.category_outlined, color: accentColor, size: 19),
                                ),
                                IconButton(
                                  tooltip: _showFavoritesOnly ? 'Show all channels' : 'Show favorites',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () => setState(() => _showFavoritesOnly = !_showFavoritesOnly),
                                  icon: FavoriteHeart(on: _showFavoritesOnly, size: 21, offColor: Colors.white70),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: _tvShowingCategories
                                ? ListView.builder(
                                    controller: _tvCategoryScrollController,
                                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                                    itemCount: _categories.length,
                                    itemExtent: 58,
                                    itemBuilder: (context, index) {
                                      final category = _categories[index];
                                      final focused = index == _tvFocusedCategoryIndex;
                                      final selected = category == _selectedCategory;
                                      final count = category == 'All'
                                          ? _channels.length
                                          : _channels.where((c) => c.group == category).length;
                                      return Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
                                        child: AnimatedContainer(
                                          duration: const Duration(milliseconds: 100),
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.topLeft,
                                              end: Alignment.bottomRight,
                                              colors: focused
                                                  ? [accentColor.withOpacity(0.55), accentColor.withOpacity(0.22)]
                                                  : [Colors.white.withOpacity(0.10), Colors.white.withOpacity(0.03)],
                                            ),
                                            borderRadius: BorderRadius.circular(16),
                                            border: Border.all(color: focused ? Colors.white.withOpacity(0.9) : (selected ? accentColor.withOpacity(0.6) : Colors.white.withOpacity(0.12)), width: focused ? 2 : 1),
                                            boxShadow: focused ? [BoxShadow(color: accentColor.withOpacity(0.45), blurRadius: 16)] : null,
                                          ),
                                          child: ListTile(
                                            dense: true,
                                            leading: Icon(category == 'All' ? Icons.apps_rounded : Icons.folder_outlined, color: selected ? accentColor : Colors.white70, size: 20),
                                            title: Text(category, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, fontWeight: selected ? FontWeight.bold : FontWeight.normal)),
                                            trailing: Text('$count', style: const TextStyle(color: Colors.white54, fontSize: 11)),
                                            onTap: () {
                                              setState(() {
                                                _selectedCategory = category;
                                                _tvFocusedCategoryIndex = index;
                                                _tvShowingCategories = false;
                                                _tvFocusedChannelIndex = 0;
                                              });
                                              _searchController.clear();
                                              _searchQuery = '';
                                              _showTvChannels(index: 0);
                                            },
                                          ),
                                        ),
                                      );
                                    },
                                  )
                                : channels.isEmpty
                                    ? const Center(child: Text('No channels found', style: TextStyle(color: Colors.white60)))
                                    : ListView.builder(
                                        controller: _tvChannelScrollController,
                                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                                        itemCount: channels.length,
                                        itemExtent: 96,
                                        itemBuilder: (context, index) => _buildTvChannelTile(channels[index], index),
                                      ),
                          ),
                        ],
                      ),
                    ),
                ),
              ),
            ),
          ),
        ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          top: 0,
          bottom: 0,
          left: (_tvSidebarVisible && _tvEpgVisible && !_tvShowingCategories) ? 310 : -360,
          width: 350,
          // Guide is an overlay beside the rail; it never resizes the video.
          child: IgnorePointer(
            ignoring: !_tvSidebarVisible || !_tvEpgVisible || _tvShowingCategories,
            child: AnimatedOpacity(
            duration: const Duration(milliseconds: 90),
            opacity: _tvSidebarVisible && _tvEpgVisible && !_tvShowingCategories ? 1 : 0,
            child: Builder(builder: (context) {
              final preview = _tvEpgPreviewChannel(channels);
              return preview == null ? const SizedBox.shrink() : _buildTvEpgPanel(preview);
            }),
          ),
          ),
        ),
      ],
    );
  }

  Widget _buildTvChannelTile(Channel channel, int index) {
    final selected = _selectedChannel?.url == channel.url;
    final favorite = _favorites.contains(channel.url);
    final focusNode = _tvChannelFocusNodes.putIfAbsent(
      channel.url, () => FocusNode(debugLabel: 'channel-${channel.name}'),
    );
    final focusedByIndex = index == _tvFocusedChannelIndex;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
      child: Focus(
        focusNode: focusNode,
        autofocus: focusedByIndex,
        onFocusChange: (hasFocus) {
          if (hasFocus && mounted && _tvFocusedChannelIndex != index) {
            setState(() => _tvFocusedChannelIndex = index);
          }
        },
        onKeyEvent: (node, event) => _handleChannelTileKey(node, event, index),
        child: Builder(builder: (context) {
          final focused = Focus.of(context).hasFocus || focusedByIndex;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: focused
                    ? [accentColor.withOpacity(0.55), accentColor.withOpacity(0.22)]
                    : selected
                        ? [Colors.white.withOpacity(0.20), Colors.white.withOpacity(0.07)]
                        : [Colors.white.withOpacity(0.09), Colors.white.withOpacity(0.025)],
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: focused ? Colors.white.withOpacity(0.9) : Colors.white.withOpacity(0.12),
                width: focused ? 2 : 1,
              ),
              boxShadow: focused ? [BoxShadow(color: accentColor.withOpacity(0.45), blurRadius: 16)] : null,
            ),
            child: ListTile(
              focusColor: Colors.transparent,
              hoverColor: Colors.transparent,
              dense: false,
              minVerticalPadding: 5,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              leading: _glassAvatar(channel, 30),
              title: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, fontWeight: selected ? FontWeight.bold : FontWeight.w500)),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_epgLabel(channel), maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: _epgForChannel(channel) == null ? Colors.white38 : const Color(0xFFC9BEFF), fontSize: 10, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 4),
                  ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(
                    value: _epgProgress(_epgForChannel(channel)), minHeight: 3,
                    backgroundColor: Colors.white12,
                    valueColor: const AlwaysStoppedAnimation<Color>(accentColor),
                  )),
                  const SizedBox(height: 3),
                  Text(channel.group, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 10)),
                ],
              ),
              trailing: favorite
                  ? const FavoriteHeart(on: true, size: 19)
                  : const Icon(Icons.chevron_right_rounded, color: Colors.white38, size: 20),
              onTap: () => _playChannel(channel),
            ),
          );
        }),
      ),
    );
  }

  // --------------------------------------------------
  // GLASS EFFECT
  // --------------------------------------------------
  Widget _glass({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(10),
    double radius = 16,
    Color color = glassColor,
    double blur = 14,
  }) {
    // Frosted glass: blurred backdrop + tinted gradient + light edge. Used for
    // the few large/overlay panels (search, player bar, controls, info card);
    // long lists use blur: 0 for speed.
    return Glass(
      radius: radius,
      padding: padding,
      tint: color.withOpacity(1),
      strength: color.opacity < 1 ? (color.opacity + 0.25).clamp(0.5, 1.0).toDouble() : 0.9,
      blur: blur,
      child: child,
    );
  }

  // --------------------------------------------------
  // FAVORITES
  // --------------------------------------------------
  Future<void> _loadFavorites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _favorites =
            (prefs.getStringList('ananta_favorites') ?? []).toSet();
      });
    } catch (e) {
      debugPrint('Favorites error: $e');
    }
  }

  Future<void> _saveFavorites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        'ananta_favorites',
        _favorites.toList(),
      );
    } catch (e) {
      debugPrint('Saving favorites failed: $e');
    }
  }

  Future<void> _toggleFavorite(Channel channel) async {
    setState(() {
      if (_favorites.contains(channel.url)) {
        _favorites.remove(channel.url);
      } else {
        _favorites.add(channel.url);
      }
    });
    await _saveFavorites();
  }

  // --------------------------------------------------
  // M3U PARSER
  // --------------------------------------------------
  String _attribute(String line, String attribute) {
    final pattern = RegExp(
      '$attribute\\s*=\\s*["\\x27]([^"\\x27]*)',
      caseSensitive: false,
    );
    return pattern.firstMatch(line)?.group(1) ?? '';
  }

  List<Channel> _parseM3u(String content) {
    final result = <Channel>[];
    final lines = content.split(RegExp(r'\r?\n'));
    String? name;
    String group = 'Live TV';
    String logo = '';
    String tvgId = '';
    String tvgName = '';
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXTINF')) {
        final comma = line.lastIndexOf(',');
        name = comma >= 0
            ? line.substring(comma + 1).trim()
            : 'Unknown channel';
        group = _attribute(line, 'group-title');
        logo = _attribute(line, 'tvg-logo');
        tvgId = _attribute(line, 'tvg-id');
        tvgName = _attribute(line, 'tvg-name');
        if (group.isEmpty) group = 'Live TV';
      } else if (!line.startsWith('#') && name != null) {
        final uri = Uri.tryParse(line);
        if (uri != null &&
            (uri.scheme == 'http' || uri.scheme == 'https') &&
            uri.host.isNotEmpty) {
          result.add(
            Channel(
              name: name,
              url: line,
              group: group,
              logo: logo,
              tvgId: tvgId,
              tvgName: tvgName,
            ),
          );
        }
        name = null;
        group = 'Live TV';
        logo = '';
        tvgId = '';
        tvgName = '';
      }
    }
    return result;
  }

  // --------------------------------------------------
  // EPG / XMLTV
  // --------------------------------------------------
  String _normalizeEpgName(String value) {
    var name = value.toLowerCase().trim();
    name = name.replaceAll(RegExp(r'\b(hd|fhd|uhd|4k|sd|hevc|h265|live|tv)\b', caseSensitive: false), ' ');
    return name.replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  Future<void> _loadIndiaLogoIndex() async {
    if (_indiaLogoIndexLoading) return;
    _indiaLogoIndexLoading = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('ananta_india_logo_index_v1');
      if (cached != null && cached.isNotEmpty) {
        try {
          final decoded = jsonDecode(cached) as Map<String, dynamic>;
          final map = decoded.map<String, String>((key, value) => MapEntry(key, value.toString()));
          if (map.isNotEmpty && mounted) setState(() => _indiaLogosByName = map);
        } catch (_) {}
      }
      // Use GitHub's tree API rather than HTML scraping; it returns stable file
      // paths that can be converted into direct raw image URLs.
      final response = await http.get(
        Uri.parse('https://api.github.com/repos/tv-logo/tv-logos/git/trees/main?recursive=1'),
        headers: const {'Accept': 'application/vnd.github+json', 'User-Agent': 'AnantaOTT/1.0'},
      ).timeout(const Duration(seconds: 18));
      if (response.statusCode != 200) return;
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final tree = decoded['tree'];
      if (tree is! List) return;
      final map = <String, String>{};
      for (final item in tree) {
        if (item is! Map) continue;
        final path = item['path']?.toString() ?? '';
        if (!path.startsWith('countries/india/')) continue;
        if (!RegExp(r'\.(png|jpe?g|webp)$', caseSensitive: false).hasMatch(path)) continue;
        final file = path.split('/').last.replaceFirst(RegExp(r'\.[^.]+$'), '');
        var base = file.toLowerCase().replaceAll('_', '-');
        base = base.replaceFirst(RegExp(r'-in$'), '').replaceAll('-', ' ');
        final normalized = _normalizeEpgName(base);
        if (normalized.isEmpty) continue;
        final url = 'https://raw.githubusercontent.com/tv-logo/tv-logos/main/$path';
        map.putIfAbsent(normalized, () => url);
        // Also index the exact filename spelling before HD/SD tokens are removed.
        final fullNormalized = _normalizeEpgName(file.replaceAll('-', ' '));
        if (fullNormalized.isNotEmpty) map.putIfAbsent(fullNormalized, () => url);
      }
      if (map.isNotEmpty) {
        await prefs.setString('ananta_india_logo_index_v1', jsonEncode(map));
        if (mounted) setState(() => _indiaLogosByName = map);
      }
    } catch (error) {
      debugPrint('India TV logo index unavailable: $error');
    } finally {
      _indiaLogoIndexLoading = false;
    }
  }

  Future<void> _initializeEpg() async {
    // Always show the on-device guide first. Only fetch on startup when the
    // cache is absent/expired; a cache younger than two hours is never fetched
    // again just because the app was reopened.
    final cacheIsFresh = await _loadCachedEpg();
    if (!mounted) return;
    _epgInitDone = true;
    // Even a "fresh" cache is revalidated cheaply later by the refresh timer;
    // the stored EPG files make this work offline too.
    if (!cacheIsFresh) unawaited(_loadEpg());
  }

  Map<String, dynamic> _epgMapToJson(Map<String, List<EpgProgram>> source) => {
    for (final entry in source.entries)
      entry.key: entry.value.map((program) => <String, dynamic>{
        'title': program.title,
        'description': program.description,
        'start': program.start.millisecondsSinceEpoch,
        'stop': program.stop.millisecondsSinceEpoch,
      }).toList(),
  };

  Map<String, List<EpgProgram>> _epgMapFromJson(dynamic raw) => _epgMapFromJsonTop(raw);

  Future<bool> _loadCachedEpg() async {
    try {
      // The parsed guide now lives in a file in the app's local storage.
      // Older versions kept it in SharedPreferences; read that once if needed.
      var cached = await LocalStore.instance.readParsedGuide();
      if (cached == null || cached.isEmpty) {
        final prefs = await SharedPreferences.getInstance();
        cached = prefs.getString('ananta_epg_3day_cache_v1');
      }
      if (cached == null || cached.isEmpty) return false;
      final decoded = await compute(_decodeEpgCacheIsolate, cached);
      if (decoded.isEmpty) return false;
      final savedAt = decoded['savedAt'] as int;
      _epgSavedAt = savedAt;
      final age = DateTime.now().millisecondsSinceEpoch - savedAt;
      final cacheIsFresh = savedAt > 0 && age >= 0 &&
          age < const Duration(hours: 2).inMilliseconds;
      final byId = Map<String, List<EpgProgram>>.from(decoded['byId'] as Map);
      final byName = Map<String, List<EpgProgram>>.from(decoded['byName'] as Map);
      final logosById = Map<String, String>.from(decoded['logosById'] as Map);
      final logosByName = Map<String, String>.from(decoded['logosByName'] as Map);
      if (!mounted || (byId.isEmpty && byName.isEmpty && logosById.isEmpty)) return false;
      setState(() {
        _epgById = byId;
        _epgByName = byName;
        _epgLogosById = logosById;
        _epgLogosByName = logosByName;
        _epgStatus = cacheIsFresh
            ? 'Using saved programme guide'
            : 'Using saved guide; refresh pending';
        _rebuildEpgChannelIndex();
      });
      return cacheIsFresh;
    } catch (error) {
      debugPrint('Cached EPG could not be loaded: $error');
      return false;
    }
  }

  Future<void> _saveCachedEpg(
    Map<String, List<EpgProgram>> byId,
    Map<String, List<EpgProgram>> byName,
    Map<String, String> logosById,
    Map<String, String> logosByName,
  ) async {
    try {
      await LocalStore.instance.writeParsedGuide(jsonEncode({
        'savedAt': _epgSavedAt == 0 ? DateTime.now().millisecondsSinceEpoch : _epgSavedAt,
        'byId': _epgMapToJson(byId),
        'byName': _epgMapToJson(byName),
        'logosById': logosById,
        'logosByName': logosByName,
      }));
      // Drop the old SharedPreferences copy (it could be several MB).
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('ananta_epg_3day_cache_v1');
    } catch (error) {
      debugPrint('Cached EPG could not be saved: $error');
    }
  }

  Future<void> _loadEpg() async {
    if (_epgLoading) return;
    _epgLoading = true;
    try {
    final candidatesById = <String, List<EpgProgram>>{};
    // Hash sets avoid quadratic list scans when EPG feeds contain overlapping
    // programmes from multiple providers. This is important on low-memory TV boxes.
    final seenProgramsById = <String, Set<String>>{};
    final namesById = <String, List<String>>{};
    final logosById = <String, String>{};
    final logosByName = <String, String>{};
    var successfulSources = 0;
    // 1) Bring the stored EPG files up to date (conditional download: a file
    //    that did not change on the server is not downloaded again).
    final epgFiles = <MapEntry<String, EpgFile>>[];
    for (final source in epgSourceUrls) {
      final stored = await LocalStore.instance.fetchEpg(source);
      if (stored != null) epgFiles.add(MapEntry(source, stored));
    }
    if (!mounted) return;
    if (epgFiles.isEmpty) {
      if (_epgById.isEmpty && _epgByName.isEmpty) {
        setState(() => _epgStatus = 'Programme guide unavailable');
      }
      return;
    }
    if (epgFiles.every((entry) => !entry.value.changed) &&
        (_epgById.isNotEmpty || _epgByName.isNotEmpty)) {
      // Nothing new on the server (or offline): keep the guide already loaded.
      setState(() {
        _epgStatus = epgFiles.any((entry) => entry.value.offline)
            ? 'Offline: using stored programme guide'
            : 'Programme guide is up to date';
      });
      if (!epgFiles.any((entry) => entry.value.offline)) {
        _epgSavedAt = DateTime.now().millisecondsSinceEpoch;
      }
      return;
    }
    // 2) Parse the stored files (off the UI thread).
    for (final entry in epgFiles) {
      final source = entry.key;
      try {
        final bytes = await entry.value.file.readAsBytes();
        final parsed = await compute(_parseEpgPayload, bytes);
        final sourceNames = (parsed['namesById'] as Map).map<String, List<String>>(
          (key, value) => MapEntry(key.toString(), (value as List).map((item) => item.toString()).toList()),
        );
        for (final entry in sourceNames.entries) {
          final existing = namesById.putIfAbsent(entry.key, () => <String>[]);
          for (final name in entry.value) {
            if (!existing.contains(name)) existing.add(name);
          }
        }
        final rawSourceLogos = parsed['logosById'];
        if (rawSourceLogos is Map) {
          for (final entry in rawSourceLogos.entries) {
            final url = entry.value.toString();
            if (url.startsWith('http://') || url.startsWith('https://')) logosById.putIfAbsent(entry.key.toString(), () => url);
          }
        }
        for (final entry in sourceNames.entries) {
          final logo = logosById[entry.key];
          if (logo != null) {
            for (final name in entry.value) logosByName.putIfAbsent(_normalizeEpgName(name), () => logo);
          }
        }
        final sourcePrograms = parsed['programmes'] as List;
        for (final raw in sourcePrograms) {
          final item = raw as Map;
          final id = item['id'].toString();
          final program = EpgProgram(
            title: item['title'].toString(),
            // Long descriptions bloat SharedPreferences and can stall low-RAM TVs.
            description: (item['description']?.toString() ?? '').substring(0, (item['description']?.toString() ?? '').length.clamp(0, 400).toInt()),
            start: DateTime.fromMillisecondsSinceEpoch(item['start'] as int, isUtc: true),
            stop: DateTime.fromMillisecondsSinceEpoch(item['stop'] as int, isUtc: true),
          );
          final list = candidatesById.putIfAbsent(id, () => <EpgProgram>[]);
          final key = '${program.start.millisecondsSinceEpoch}|${program.title}';
          final seen = seenProgramsById.putIfAbsent(id, () => <String>{});
          if (seen.add(key)) list.add(program);
        }
        successfulSources++;
      } catch (error) {
        debugPrint('EPG source failed ($source): $error');
        LocalStore.instance.invalidateEpg(source);
      }
    }

    final byId = <String, List<EpgProgram>>{};
    final byName = <String, List<EpgProgram>>{};
    final seenProgramsByName = <String, Set<String>>{};
    final epgNow = DateTime.now().toUtc();
    final keepAfter = epgNow.subtract(const Duration(hours: 6));
    final keepUntil = epgNow.add(const Duration(days: 3));
    for (final entry in candidatesById.entries) {
      final programs = entry.value
        .where((p) => p.stop.isAfter(keepAfter) && p.start.isBefore(keepUntil))
        .toList()
        ..sort((a, b) => a.start.compareTo(b.start));
      if (programs.isNotEmpty) byId[entry.key] = programs;
      for (final name in namesById[entry.key] ?? const <String>[]) {
        final normalized = _normalizeEpgName(name);
        if (normalized.isEmpty || programs.isEmpty) continue;
        final list = byName.putIfAbsent(normalized, () => <EpgProgram>[]);
        final seen = seenProgramsByName.putIfAbsent(normalized, () => <String>{});
        for (final program in programs) {
          final key = '${program.start.millisecondsSinceEpoch}|${program.title}';
          if (seen.add(key)) list.add(program);
        }
      }
    }
    for (final list in byName.values) {
      list.sort((a, b) => a.start.compareTo(b.start));
    }
    if (!mounted) return;
    // Publish the newly parsed guide immediately; disk/cache persistence runs
    // asynchronously so slow storage on TV boxes cannot delay the UI update.
    setState(() {
      if (byId.isNotEmpty || byName.isNotEmpty) {
        _epgById = byId;
        _epgByName = byName;
        _epgLogosById = logosById;
        _epgLogosByName = logosByName;
        _epgStatus = 'Guide loaded from $successfulSources source(s)';
        _epgSavedAt = DateTime.now().millisecondsSinceEpoch;
      } else if (_epgById.isEmpty && _epgByName.isEmpty) {
        _epgStatus = 'Programme guide unavailable';
      }
      _rebuildEpgChannelIndex();
    });
    if (byId.isNotEmpty || byName.isNotEmpty) {
      unawaited(_saveCachedEpg(byId, byName, logosById, logosByName));
    }
    debugPrint('EPG loaded: ${byId.length} channel IDs, ${byName.length} names from $successfulSources sources');
    } finally {
      _epgLoading = false;
    }
  }

  EpgProgram? _pickCurrentProgram(List<EpgProgram>? programs) {
    if (programs == null || programs.isEmpty) return null;
    final now = DateTime.now().toUtc();
    for (final program in programs) {
      if (program.isAiringAt(now)) return program;
    }
    for (final program in programs) {
      if (program.start.isAfter(now)) return program;
    }
    return null;
  }

  // Sister channels differ only by a number ("Zee Anmol" / "Zee Anmol 2",
  // "Star Sports 1" / "Star Sports 2"). These helpers make sure such channels
  // never borrow each other's guide.
  String _epgStripCountry(String normalized) {
    final stripped = normalized.replaceFirst(RegExp(r'(india|in)$'), '');
    return stripped.length >= 3 ? stripped : normalized;
  }

  String _epgTrailingNumber(String normalized) {
    final m = RegExp(r'(\d+)$').firstMatch(_epgStripCountry(normalized));
    return m == null ? '' : m.group(1)!;
  }

  List<EpgProgram> _resolveEpgCandidates(Channel channel) {
    final name = _normalizeEpgName(channel.name);
    final wantedNumber = _epgTrailingNumber(name);
    // A playlist id/name may be shared by sister channels (e.g. tvg-id
    // "ZeeAnmol.in" on both "Zee Anmol" and "Zee Anmol 2"). Accept it only
    // when its trailing number agrees with the channel's own name.
    bool numberAgrees(String normalizedKey) =>
        wantedNumber == _epgTrailingNumber(normalizedKey);

    final id = channel.tvgId.trim();
    if (id.isNotEmpty) {
      final normalizedId = _normalizeEpgName(id);
      if (numberAgrees(normalizedId)) {
        final direct = _epgById[id];
        if (direct != null && direct.isNotEmpty) return direct;
        for (final entry in _epgById.entries) {
          if (_normalizeEpgName(entry.key) == normalizedId) return entry.value;
        }
      }
    }
    final playlistName = _normalizeEpgName(channel.tvgName);
    if (playlistName.isNotEmpty && numberAgrees(playlistName)) {
      final playlistNameMatch = _epgByName[playlistName];
      if (playlistNameMatch != null && playlistNameMatch.isNotEmpty) return playlistNameMatch;
    }
    final directName = _epgByName[name];
    if (directName != null && directName.isNotEmpty) return directName;
    // Same name with only a country suffix ("starplus" vs "starplusin").
    if (name.length >= 5) {
      final base = _epgStripCountry(name);
      for (final entry in _epgByName.entries) {
        if (entry.value.isEmpty) continue;
        final key = entry.key;
        if (key.length < 5) continue;
        if (_epgStripCountry(key) == base && numberAgrees(key)) return entry.value;
      }
    }
    return const <EpgProgram>[];
  }

  // Lazy cache: resolving EPG candidates for every channel up-front blocked the
  // UI thread for seconds. Entries are now filled on demand and memoised.
  void _rebuildEpgChannelIndex() {
    _epgByChannelUrl = <String, List<EpgProgram>>{};
  }

  List<EpgProgram> _epgCandidatesCached(Channel channel) {
    final cached = _epgByChannelUrl[channel.url];
    if (cached != null) return cached;
    final resolved = _resolveEpgCandidates(channel);
    _epgByChannelUrl[channel.url] = resolved;
    return resolved;
  }

  EpgProgram? _epgForChannel(Channel channel) =>
      _pickCurrentProgram(_epgCandidatesCached(channel));

  /// Round channel logo in a glass ring (stored copy on disk when available).
  Widget _glassAvatar(Channel channel, double radius) {
    final logo = _logoImage(channel);
    return Container(
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white.withOpacity(0.55), accentColor.withOpacity(0.25)],
        ),
      ),
      child: CircleAvatar(
        radius: radius - 2.5,
        backgroundColor: const Color(0xFF1B1836),
        backgroundImage: logo,
        onBackgroundImageError: logo == null ? null : (_, __) {},
        child: logo == null ? Icon(Icons.live_tv, color: accentColor, size: radius * 0.9) : null,
      ),
    );
  }

  /// Round, transparent channel logo for the mobile list. An animated play
  /// icon shows inside the circle until the logo loads, then the logo replaces it.
  Widget _logoCard(Channel channel, double size, {bool selected = false}) {
    return LogoBadge(
      image: _logoImage(channel),
      size: size,
      selected: selected,
      accent: accentColor,
    );
  }

  String _logoForChannel(Channel channel) {
    final cached = _logoUrlCache[channel.url];
    if (cached != null) return cached;
    final resolved = _resolveLogoUrl(channel);
    _logoUrlCache[channel.url] = resolved;
    return resolved;
  }

  String _resolveLogoUrl(Channel channel) {
    // Logos come ONLY from this app's channel_logos folder in the user's
    // repository. That folder is mirrored into the device's local storage by
    // LocalStore; this method only decides which file name belongs to a
    // channel. Playlist tvg-logo and EPG artwork are deliberately not used.
    String slugFor(String value) {
      var name = value.toLowerCase().trim();
      // The logo filenames retain quality suffixes: "Star Plus HD" must map
      // to star-plus-hd-in.png, while "Big Magic" maps to big-magic-in.png.
      name = name.replaceAll(RegExp(r'\[(?:in|india)\]|\((?:in|india)\)', caseSensitive: false), ' ');
      name = name.replaceAll('&', ' and ');
      name = name.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
      name = name.replaceAll(RegExp(r'-+'), '-');
      name = name.replaceAll(RegExp(r'^-|-$'), '');
      if (name.isEmpty) return '';
      if (!name.endsWith('-in')) name = '$name-in';
      return name;
    }

    const base = 'https://raw.githubusercontent.com/Abidananta/Ananta-Stream-ott/main/channel_logos/';
    final candidates = <String>[];
    for (final raw in <String>[channel.name, channel.tvgName]) {
      final slug = slugFor(raw);
      if (slug.isNotEmpty && !candidates.contains(slug)) candidates.add(slug);
    }
    if (candidates.isEmpty) return '';
    final store = LocalStore.instance;
    if (!store.hasLogoListing) {
      // File list not known yet (first start, offline): same behaviour as
      // before, first candidate; it is fetched on demand and stored.
      return '$base${candidates.first}.png';
    }
    for (final slug in candidates) {
      if (store.knowsLogo('$slug.png')) return '$base$slug.png';
    }
    // Retry without the quality suffix (e.g. "Star Plus HD" -> star-plus-in).
    for (final slug in candidates) {
      final plain = slug
          .replaceFirst(RegExp(r'-(hd|fhd|uhd|sd|4k)-in$'), '-in');
      if (plain != slug && store.knowsLogo('$plain.png')) return '$base$plain.png';
    }
    return '';
  }

  /// Logo image for a channel: the copy stored on the device when available,
  /// otherwise the network (and it is stored for next time).
  ImageProvider? _logoImage(Channel channel) {
    final url = _logoForChannel(channel);
    if (url.isEmpty) return null;
    final name = url.substring(url.lastIndexOf('/') + 1);
    final store = LocalStore.instance;
    final file = store.logoFile(name);
    if (file != null) return ResizeImage(FileImage(file), width: 192);
    if (store.logoMissingRemotely(name)) return null;
    store.requestLogo(name);
    return CachedNetworkImageProvider(url);
  }

  double _epgProgress(EpgProgram? program) {
    if (program == null || !program.stop.isAfter(program.start)) return 0;
    final now = DateTime.now().toUtc();
    return (now.difference(program.start).inMilliseconds / program.stop.difference(program.start).inMilliseconds).clamp(0.0, 1.0).toDouble();
  }

  List<EpgProgram> _epgScheduleForChannel(Channel channel) {
    final source = _epgCandidatesCached(channel);
    final now = DateTime.now().toUtc();
    final start = now.subtract(const Duration(days: 3));
    final end = now.add(const Duration(days: 3));
    final sorted = source.where((p) => p.stop.isAfter(start) && p.start.isBefore(end)).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    return _resolveEpgOverlaps(sorted);
  }

  /// Several EPG feeds describe the same channel with slightly different
  /// start times, which used to make 2-3 programmes show as "NOW" at once.
  /// Keep a single non-overlapping timeline: a programme that starts before
  /// the previous one ended is dropped when it is a duplicate / contained in
  /// it, otherwise it replaces the previous one only if the previous one has
  /// already ended by the time it starts (tolerance 2 min for sloppy feeds).
  List<EpgProgram> _resolveEpgOverlaps(List<EpgProgram> sorted) {
    final result = <EpgProgram>[];
    for (final program in sorted) {
      if (!program.stop.isAfter(program.start)) continue;
      if (result.isEmpty) {
        result.add(program);
        continue;
      }
      final last = result.last;
      final overlap = last.stop.difference(program.start);
      if (overlap <= const Duration(minutes: 2)) {
        result.add(program);
      } else if (program.stop.isAfter(last.stop.add(const Duration(minutes: 10))) &&
          program.start.difference(last.start) > const Duration(minutes: 20)) {
        // Genuinely different, later programme from another feed: cut the
        // previous one at this start so only one programme is live.
        result[result.length - 1] = EpgProgram(
          title: last.title,
          description: last.description,
          start: last.start,
          stop: program.start,
        );
        result.add(program);
      }
      // else: duplicate of the previous programme from another feed; skip.
    }
    return result;
  }

  /// Programmes of [channel] that fall on the day picked in the TV guide tabs.
  List<EpgProgram> _tvEpgDaySchedule(Channel channel) {
    final today = DateTime.now();
    final dayStart = DateTime(today.year, today.month, today.day)
        .add(Duration(days: _tvEpgSelectedDayOffset));
    final dayEnd = dayStart.add(const Duration(days: 1));
    return _epgScheduleForChannel(channel).where((program) {
      return program.stop.toLocal().isAfter(dayStart) &&
          program.start.toLocal().isBefore(dayEnd);
    }).toList();
  }

  /// Index of the programme on air now (0 when the selected day is not today
  /// or nothing is airing).
  int _tvEpgCurrentIndex(List<EpgProgram> schedule) {
    if (_tvEpgSelectedDayOffset != 0) return 0;
    final now = DateTime.now().toUtc();
    final index = schedule.indexWhere((p) => p.isAiringAt(now));
    if (index >= 0) return index;
    final next = schedule.indexWhere((p) => p.start.isAfter(now));
    return next < 0 ? 0 : next;
  }

  /// Scrolls the guide list so the programme at [index] sits at the top.
  void _positionTvEpgAt(int index, [int attempt = 0]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _tvEpgAnchorKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx, alignment: 0.0, duration: Duration.zero);
        return;
      }
      if (!_tvEpgScrollController.hasClients) {
        if (attempt < 8) _positionTvEpgAt(index, attempt + 1);
        return;
      }
      // Rows are built lazily: jump near the row, then retry until the real
      // row exists and can be measured.
      final position = _tvEpgScrollController.position;
      _tvEpgScrollController.jumpTo((index * 112.0).clamp(0.0, position.maxScrollExtent).toDouble());
      if (attempt < 8) _positionTvEpgAt(index, attempt + 1);
    });
  }

  Channel? _tvEpgPreviewChannel(List<Channel> channels) {
    if (_tvShowingCategories) return _selectedChannel;
    if (channels.isEmpty) return _selectedChannel;
    final index = _tvFocusedChannelIndex.clamp(0, channels.length - 1).toInt();
    return channels[index];
  }

  String _formatEpgTime(DateTime value) {
    final local = value.toLocal();
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute ${local.hour >= 12 ? 'PM' : 'AM'}';
  }

  Widget _buildTvEpgPanel(Channel channel) {
    final localToday = DateTime.now();
    final schedule = _tvEpgDaySchedule(channel);
    final anchor = '${channel.url}|$_tvEpgSelectedDayOffset';
    if (_tvEpgAnchor != anchor) {
      // Guide just opened / channel or day changed: start on the live programme.
      _tvEpgAnchor = anchor;
      _tvEpgAnchorIndex = _tvEpgCurrentIndex(schedule);
      _tvFocusedEpgIndex = _tvEpgAnchorIndex;
      if (schedule.isNotEmpty) _positionTvEpgAt(_tvEpgAnchorIndex);
    }
    final now = DateTime.now().toUtc();
    return Glass(
      borderRadius: const BorderRadius.horizontal(right: Radius.circular(26)),
      tint: const Color(0xFF1A1536),
      strength: 1.0,
      blur: kTvLiveBlur ? 18 : 0,
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_tvEpgSelectionMode ? '3-DAY TV GUIDE · SELECT WITH UP/DOWN' : '3-DAY TV GUIDE · PRESS RIGHT TO NAVIGATE', style: const TextStyle(fontSize: 10, letterSpacing: 0.7, color: Color(0xFFC9BEFF), fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(channel.name.trim(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              Text(channel.group, style: const TextStyle(fontSize: 11, color: Colors.white60)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Row(
              children: List.generate(3, (dayOffset) {
                final day = DateTime(localToday.year, localToday.month, localToday.day)
                    .add(Duration(days: dayOffset));
                final selected = _tvEpgSelectedDayOffset == dayOffset;
                final label = dayOffset == 0 ? 'TODAY' : dayOffset == 1 ? 'TOMORROW' : '${['MON','TUE','WED','THU','FRI','SAT','SUN'][day.weekday - 1]} ${day.day}/${day.month}';
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () {
                        setState(() {
                          _tvEpgSelectedDayOffset = dayOffset;
                          _tvFocusedEpgIndex = 0;
                          _tvEpgAnchor = ''; // re-anchor: live programme for today, top otherwise
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 3),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: selected
                                ? [accentColor.withOpacity(0.60), accentColor.withOpacity(0.25)]
                                : [Colors.white.withOpacity(0.10), Colors.white.withOpacity(0.03)],
                          ),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: selected ? Colors.white.withOpacity(0.85) : Colors.white.withOpacity(0.12), width: selected ? 1.5 : 1),
                          boxShadow: selected ? [BoxShadow(color: accentColor.withOpacity(0.35), blurRadius: 12)] : null,
                        ),
                        child: Text(label, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: selected ? Colors.white : Colors.white70)),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          Expanded(
            child: schedule.isEmpty
              ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_epgStatus == 'Loading programme guide…' ? 'Loading guide…' : 'No 3-day guide available for this channel', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60, fontSize: 12))))
              : Scrollbar(
                  controller: _tvEpgScrollController,
                  thumbVisibility: true,
                  child: ListView.builder(
                  controller: _tvEpgScrollController,
                  physics: const ClampingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                  itemCount: schedule.length,
                  itemBuilder: (context, index) {
                    final program = schedule[index];
                    final current = program.isAiringAt(now);
                    final previous = index == 0 ? null : schedule[index - 1];
                    final newDay = previous == null || previous.start.toLocal().year != program.start.toLocal().year || previous.start.toLocal().month != program.start.toLocal().month || previous.start.toLocal().day != program.start.toLocal().day;
                    final localStart = program.start.toLocal();
                    final dayLabel = '${['Mon','Tue','Wed','Thu','Fri','Sat','Sun'][localStart.weekday - 1]}, ${localStart.day.toString().padLeft(2, '0')}/${localStart.month.toString().padLeft(2, '0')}';
                    return Column(key: index == _tvEpgAnchorIndex ? _tvEpgAnchorKey : null, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      if (newDay) Padding(padding: const EdgeInsets.fromLTRB(4, 8, 4, 5), child: Text(dayLabel, style: const TextStyle(color: Color(0xFFC9BEFF), fontSize: 11, fontWeight: FontWeight.bold))),
                      Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.all(9),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: index == _tvFocusedEpgIndex && _tvEpgSelectionMode
                                ? [accentColor.withOpacity(0.55), accentColor.withOpacity(0.22)]
                                : current
                                    ? [accentColor.withOpacity(0.38), accentColor.withOpacity(0.12)]
                                    : [Colors.white.withOpacity(0.08), Colors.white.withOpacity(0.025)],
                          ),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: index == _tvFocusedEpgIndex && _tvEpgSelectionMode
                              ? Colors.white.withOpacity(0.95) : current ? accentColor.withOpacity(0.75) : Colors.white.withOpacity(0.11), width: index == _tvFocusedEpgIndex && _tvEpgSelectionMode ? 2 : 1),
                          boxShadow: index == _tvFocusedEpgIndex && _tvEpgSelectionMode ? [BoxShadow(color: accentColor.withOpacity(0.4), blurRadius: 14)] : null,
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Text(_formatEpgTime(program.start), style: const TextStyle(fontSize: 10, color: Colors.white60, fontWeight: FontWeight.w600)),
                            const Spacer(),
                            if (current) const Text('NOW', style: TextStyle(fontSize: 9, color: Color(0xFFD6CCFF), fontWeight: FontWeight.bold, letterSpacing: 1)),
                          ]),
                          const SizedBox(height: 4),
                          Text(program.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: current ? FontWeight.bold : FontWeight.w500)),
                          if (program.description.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(program.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.white60, height: 1.2)),
                          ],
                          if (current) ...[
                            const SizedBox(height: 7),
                            ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(
                              value: program.stop.isAfter(program.start) ? (now.difference(program.start).inMilliseconds / program.stop.difference(program.start).inMilliseconds).clamp(0.0, 1.0).toDouble() : 0.0,
                              minHeight: 3,
                              backgroundColor: Colors.white12,
                              valueColor: const AlwaysStoppedAnimation<Color>(accentColor),
                            )),
                          ],
                        ]),
                      ),
                    ]);
                  },
                ),
                ),
          ),
        ]),
      ),
    );
  }

  String _epgLabel(Channel channel) {
    final program = _epgForChannel(channel);
    if (program == null) {
      return _epgStatus == 'Loading programme guide…' ? 'Loading programme info…' : 'Programme info unavailable';
    }
    final prefix = program.isAiringAt(DateTime.now().toUtc()) ? 'NOW' : 'UP NEXT';
    return '$prefix · ${program.title}';
  }

  // --------------------------------------------------
  // PLAYLIST REFRESH
  // --------------------------------------------------
  Future<void> _loadPlaylist() async {
    if (_loadingPlaylist) return;
    final requestId = ++_playlistRequestId;
    setState(() {
      _loadingPlaylist = true;
      _status = 'Loading latest playlist...';
    });
    try {
      List<Channel> parsed;
      final prefetch = _prefetchedPlaylist;
      _prefetchedPlaylist = null; // use the splash-time prefetch only once
      try {
        parsed = prefetch != null ? await prefetch : await _fetchAndParsePlaylist();
      } catch (_) {
        parsed = await _fetchAndParsePlaylist();
      }
      final updated = <Channel>[ptvChannel];
      final seen = <String>{ptvChannel.url};
      for (final channel in parsed) {
        if (seen.add(channel.url)) {
          updated.add(channel);
        }
      }
      if (!mounted || requestId != _playlistRequestId) return;
      final shouldAutoPlayFirstChannel = _selectedChannel == null;
      final groups = updated.map((c) => c.group).toSet();
      setState(() {
        _channels = updated;
        if (_selectedCategory != 'All' &&
            !groups.contains(_selectedCategory)) {
          _selectedCategory = 'All';
        }
        _status = '${updated.length} channels loaded';
        _rebuildEpgChannelIndex();
      });
      // Start the first channel from the loaded playlist automatically on app
      // launch (skip the built-in PTV utility entry when playlist channels exist).
      if (shouldAutoPlayFirstChannel && mounted) {
        final firstPlaylistChannel = updated.length > 1 ? updated[1] : updated.first;
        unawaited(_playChannel(firstPlaylistChannel));
      }
    } catch (e) {
      debugPrint('Playlist refresh error: $e');
      if (!mounted || requestId != _playlistRequestId) return;
      setState(() {
        _status = 'Refresh failed; existing channels retained';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Playlist refresh failed: $e'),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: _loadPlaylist,
          ),
        ),
      );
    } finally {
      if (mounted && requestId == _playlistRequestId) {
        setState(() => _loadingPlaylist = false);
      }
    }
  }

  // --------------------------------------------------
  // PLAYER CONTROLS AUTO-HIDE
  // --------------------------------------------------
  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(
      const Duration(seconds: 2),
      () {
        if (!mounted) return;
        if (_player?.value.isInitialized == true) {
          setState(() {
            _controlsVisible = false;
          });
        }
      },
    );
  }

  void _showPlayerControls() {
    if (!mounted) return;
    setState(() {
      _controlsVisible = true;
    });
    if (_player?.value.isInitialized == true) {
      _scheduleControlsHide();
    }
  }

  void _togglePlayerControls() {
    if (_controlsVisible) {
      _controlsTimer?.cancel();
      setState(() => _controlsVisible = false);
    } else {
      _showPlayerControls();
    }
  }

  // --------------------------------------------------
  // PLAYBACK
  // --------------------------------------------------
  Future<void> _playChannel(Channel channel, {int retryAttempt = 0}) async {
    if (!mounted) return;
    // Every selection supersedes the previous pending request. Do not block
    // channel changes while a stream is buffering, and keep the current player
    // alive until a replacement stream is actually ready.
    if (retryAttempt == 0 && _selectedChannel?.url == channel.url && _player?.value.isInitialized == true) {
      // Choosing the currently playing channel cancels any other stream that
      // is still buffering instead of leaving a stale request running.
      ++_playRequestId;
      final pending = _pendingPlayer;
      _pendingPlayer = null;
      if (pending != null) { try { await pending.dispose(); } catch (_) {} }
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _tvSidebarVisible = false;
        _tvEpgVisible = false;
        _tvEpgSelectionMode = false;
      });
      _showChannelInfoFor10Seconds();
      _focusTvPlayer();
      return;
    }
    final requestId = ++_playRequestId;
    final oldPlayer = _player;
    final previousPending = _pendingPlayer;
    _pendingPlayer = null;
    if (previousPending != null) {
      try { await previousPending.dispose(); } catch (_) {}
    }
    // Keep the current player visible while the next channel opens. This avoids
    // a black frame during channel changes and lets viewers keep the last video
    // frame if the network temporarily drops. Dispose the old player only after
    // the replacement has successfully started.
    if (!mounted || requestId != _playRequestId) return;
    _controlsTimer?.cancel();
    final controller = AnantaPlayerController.networkUrl(
      Uri.parse(channel.url),
      httpHeaders: const {
        'User-Agent': 'VLC/3.0.20 LibVLC/3.0.20',
        'Accept': '*/*',
        'Connection': 'keep-alive',
      },
      videoPlayerOptions: null,
    );
    _pendingPlayer = controller;
    setState(() {
      // Hide the channel rail immediately on selection, rather than waiting
      // for the new stream to initialize. This keeps the TV picture clear
      // while buffering and prevents the sidebar from lingering over video.
      _tvSidebarVisible = false;
      _tvEpgVisible = false;
      _tvEpgSelectionMode = false;
      // Keep the committed channel identity in sync with the video still on
      // screen. The selected channel is committed only after its first frame.
      _playerError = null;
      _connecting = true;
      _controlsVisible = true;
      _status = 'Buffering ${channel.name}...';
    });
    _showChannelInfoFor10Seconds();
    // The current channel keeps playing untouched until the new stream has
    // its first frame; only then is it swapped (and the old player released).
    try {
      _pendingPlayer = controller;
      if (mounted) setState(() {}); // Mount the hidden video surface before waiting for metadata.
      await controller.initialize().timeout(const Duration(seconds: 20));
      if (!mounted || requestId != _playRequestId) {
        await controller.dispose();
        return;
      }
      if (controller.value.hasError) {
        throw Exception(
          controller.value.errorDescription ?? 'Player error',
        );
      }

      // Start playback, then mount the new Video widget immediately. Do not
      // wait for width/height metadata before committing the player: on some
      // Android TV streams the audio can start first and reports video
      // dimensions late (or not at all). Keeping that player pending means its
      // Video widget is never mounted, so audio can be heard while the screen
      // stays black with a permanent buffering spinner.
      await controller.setVolume(0.0);
      await controller.play();
      await controller.waitForVideoReady().timeout(const Duration(seconds: 12));
      if (!mounted || requestId != _playRequestId) {
        await controller.dispose();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await controller.setVolume(1.0);
      if (!mounted || requestId != _playRequestId) {
        await controller.dispose();
        return;
      }
      _pendingPlayer = null;
      setState(() {
        _player = controller;
        _selectedChannel = channel;
        _status = 'Playing ${channel.name}';
        _connecting = false;
        _runtimeRetryCount = 0;
        _userPaused = false;
        _stallTicks = 0;
        _lastHealthPosition = null;
        _bufferingStartedAt = null;
        _tvSidebarVisible = false;
        _tvEpgVisible = false;
        _tvEpgSelectionMode = false;
      });
      _showChannelInfoFor10Seconds();
      _focusTvPlayer();
      if (oldPlayer != null && oldPlayer != controller) {
        try { await oldPlayer.dispose(); } catch (_) {}
      }
      // Only now does the new channel take audio focus (the old one is gone).
      await controller.setAudioFocus(true);
      await WakelockPlus.enable();
      _syncPipAutoEnter();
      _scheduleControlsHide();
    } on TimeoutException {
      try { await controller.dispose(); } catch (_) {}
      if (!mounted || requestId != _playRequestId) return;
      _pendingPlayer = null;
      setState(() {
        _playerError = retryAttempt < 6 ? 'Connection interrupted. Retrying (${retryAttempt + 1}/6)…' : 'Stream timed out after 6 retries.';
        _status = 'Stream timed out';
        _connecting = false;
      });
      if (retryAttempt < 6) {
        await Future.delayed(Duration(seconds: 1 + retryAttempt));
        if (mounted && requestId == _playRequestId) {
          await _playChannel(channel, retryAttempt: retryAttempt + 1);
        }
      }
    } catch (e) {
      debugPrint('Playback error for ${channel.url}: $e');
      try { await controller.dispose(); } catch (_) {}
      if (!mounted || requestId != _playRequestId) return;
      _pendingPlayer = null;
      setState(() {
        _playerError = retryAttempt < 6 ? 'Stream interrupted. Retrying (${retryAttempt + 1}/6)…' : 'Unable to play after 6 retries.';
        _status = 'Playback failed';
        _connecting = false;
      });
      if (retryAttempt < 6) {
        await Future.delayed(Duration(seconds: 1 + retryAttempt));
        if (mounted && requestId == _playRequestId) {
          await _playChannel(channel, retryAttempt: retryAttempt + 1);
        }
      }
    }

  }

  Future<void> _togglePlayback() async {
    final player = _player;
    if (player == null || !player.value.isInitialized) return;
    try {
      if (player.value.isPlaying) {
        _userPaused = true;
        await player.pause();
        await WakelockPlus.disable();
      } else {
        _userPaused = false;
        await player.play();
        await WakelockPlus.enable();
      }
      if (!mounted) return;
      setState(() {});
      _syncPipAutoEnter();
      _showPlayerControls();
    } catch (e) {
      debugPrint('Playback control error: $e');
    }
  }

  Future<void> _changeChannel(int direction) async {
    final list = _visibleChannels;
    if (list.isEmpty) return;
    final currentIndex = list.indexWhere(
      (channel) => channel.url == _selectedChannel?.url,
    );
    final nextIndex = currentIndex == -1
        ? (direction > 0 ? 0 : list.length - 1)
        : (currentIndex + direction + list.length) % list.length;
    await _playChannel(list[nextIndex]);
  }

  // --------------------------------------------------
  // FULLSCREEN: landscape video, smooth return to phone portrait.
  // TVs remain landscape when fullscreen is closed.
  // --------------------------------------------------
  Future<void> _setFullscreen(bool value) async {
    if (_fullscreenTransitioning || value == _fullscreen) return;
    _fullscreenTransitioning = true;

    try {
      if (value) {
        final media = MediaQuery.maybeOf(context);
        _fullscreenOnTv = media != null &&
            media.size.width >= 850 &&
            media.size.width > media.size.height;

        if (mounted) {
          setState(() {
            _fullscreen = true;
            _controlsVisible = true;
          });
        }
        await SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        await SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.immersiveSticky,
        );
      } else {
        // Switch back to the normal player layout immediately. Android then
        // animates the physical rotation instead of keeping the fullscreen
        // widget until the orientation Future completes.
        if (mounted) {
          setState(() {
            _fullscreen = false;
            _controlsVisible = true;
          });
        }

        if (_fullscreenOnTv) {
          await SystemChrome.setPreferredOrientations(const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]);
        } else {
          await SystemChrome.setPreferredOrientations(const [
            DeviceOrientation.portraitUp,
          ]);
        }
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }

      if (mounted) {
        setState(() {
          _controlsVisible = true;
        });
      }
      _scheduleControlsHide();
    } catch (error) {
      debugPrint('Fullscreen/orientation transition error: $error');
    } finally {
      _fullscreenTransitioning = false;
    }
  }

  Future<bool> _handleBack() async {
    if (_fullscreen) {
      await _setFullscreen(false);
      return false;
    }

    final media = MediaQuery.maybeOf(context);
    final tvMode = media != null &&
        media.size.width >= 850 &&
        media.size.width > media.size.height;

    if (tvMode && _tvSidebarVisible) {
      // First BACK closes the channel rail. A subsequent BACK is allowed to
      // leave the app instead of reopening/toggling the rail forever.
      setState(() { _tvSidebarVisible = false; _tvEpgVisible = false; _tvEpgSelectionMode = false; });
      FocusManager.instance.primaryFocus?.unfocus();
      _focusTvPlayer();
      return false;
    }

    // Let Android handle BACK when the TV sidebar is already hidden.
    return true;
  }

  // --------------------------------------------------
  // CATEGORY FILTERS
  // --------------------------------------------------
  List<String> get _categories {
    final groups = _channels
        .map((channel) => channel.group.trim())
        .where((group) => group.isNotEmpty)
        .toSet()
        .toList();
    groups.sort(
      (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
    );
    return ['All', ...groups];
  }

  List<Channel> get _visibleChannels {
    final query = _searchQuery.trim().toLowerCase();
    return _channels.where((channel) {
      final matchesCategory = _selectedCategory == 'All' ||
          channel.group == _selectedCategory;
      final matchesSearch =
          channel.name.toLowerCase().contains(query) ||
          channel.group.toLowerCase().contains(query);
      final matchesFavorite = !_showFavoritesOnly ||
          _favorites.contains(channel.url);
      return matchesCategory && matchesSearch && matchesFavorite;
    }).toList();
  }

  // --------------------------------------------------
  // PLAYER UI
  // --------------------------------------------------
  // The player subtree is keyed globally so Flutter MOVES it (instead of
  // rebuilding it) when the layout changes, e.g. when Android enters
  // Picture-in-Picture. This keeps the same video texture alive, so the last
  // frame stays on screen instead of flashing white/black.
  final GlobalKey _playerKey = GlobalKey(debugLabel: 'ananta-player');

  Widget _buildPlayer({required bool fullscreen}) =>
      KeyedSubtree(key: _playerKey, child: _buildPlayerBody(fullscreen: fullscreen));

  Widget _buildPlayerBody({required bool fullscreen}) {
    final media = MediaQuery.of(context);
    final tvMode = media.size.width >= 850 && media.size.width > media.size.height;
    final player = _player;
    final initialized = player?.value.isInitialized == true;
    // In Picture-in-Picture nothing opaque is painted behind the video, so no
    // white/black box shows before the first frame arrives.
    final pipNow = _inPip || _looksLikePip(media.size);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: initialized ? _togglePlayerControls : null,
      child: _PlayerBox(
        fullscreen: fullscreen,
        color: pipNow ? Colors.transparent : Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Keep rendering the committed player while a replacement channel
            // initializes. The pending controller is deliberately not used here:
            // it may have no video frames yet and would show a black screen.
            if (initialized)
              Positioned.fill(
                child: ColoredBox(
                  color: pipNow ? Colors.transparent : Colors.black,
                  child: TweenAnimationBuilder<double>(
                    key: ValueKey<AnantaPlayerController>(player!),
                    tween: Tween<double>(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 450),
                    curve: Curves.easeOut,
                    builder: (context, v, child) => Opacity(opacity: v, child: child),
                    child: VideoPlayer(player),
                  ),
                ),
              )
            else if (!pipNow)
              Center(
                child: _connecting
                    ? Opacity(
                        opacity: 0.35,
                        child: Image.asset(
                          'assets/ananta_launcher_icon.png',
                          width: 72,
                          height: 72,
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        ),
                      )
                    : Icon(
                        _playerError == null
                            ? Icons.live_tv
                            : Icons.error_outline,
                        size: 48,
                        color: _playerError == null
                            ? accentColor
                            : Colors.redAccent,
                      ),
              ),
            // Keep the pending decoder's Video widget mounted but invisible.
            // On Android TV, video output metadata may not arrive until the
            // ExoPlayer video texture is attached. This lets the current channel
            // remain visible while the replacement warms up off-screen.
            if (_pendingPlayer != null && _pendingPlayer != player)
              Positioned.fill(
                child: IgnorePointer(
                  child: Opacity(
                    opacity: 0.01,
                    child: VideoPlayer(_pendingPlayer!),
                  ),
                ),
              ),
            // Top-right status badge, never covering the picture: "Switching
            // channel…" while a new channel opens, "Buffering…" while the
            // playing stream rebuffers.
            if (initialized)
              Positioned(
                right: 12,
                top: 12,
                child: ValueListenableBuilder<bool>(
                  valueListenable: player!.bufferingNotifier,
                  builder: (context, buffering, _) {
                    if (!_connecting && !buffering) return const SizedBox.shrink();
                    return DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.62),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: accentColor,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _connecting ? 'Switching channel…' : 'Buffering…',
                              style: const TextStyle(color: Colors.white, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            // All controls disappear together after 2 seconds.
            if (_controlsVisible && !_inPip && !_looksLikePip(media.size)) ...[
              if (!tvMode)
                Positioned(
                bottom: 8,
                left: 10,
                right: 10,
                child: _glass(
                  radius: 12,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 1,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.circle,
                        size: 8,
                        color: Colors.redAccent,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          _selectedChannel?.name ?? appName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      if (!tvMode)
                        IconButton(
                          tooltip: 'Fullscreen',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 34,
                            minHeight: 34,
                          ),
                          padding: EdgeInsets.zero,
                          onPressed: () => _setFullscreen(!_fullscreen),
                          icon: Icon(
                            _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                            size: 21,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (initialized)
                Align(
                  alignment: tvMode ? Alignment.center : Alignment.bottomCenter,
                  child: Padding(
                    padding: EdgeInsets.only(bottom: tvMode ? 0 : 58),
                    child: _glass(
                    radius: 28,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Previous channel',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 36,
                          ),
                          padding: EdgeInsets.zero,
                          onPressed: () => _changeChannel(-1),
                          icon: const Icon(
                            Icons.skip_previous_rounded,
                            size: 23,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Play or pause',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 40,
                            minHeight: 40,
                          ),
                          padding: EdgeInsets.zero,
                          onPressed: _togglePlayback,
                          icon: Icon(
                            player!.value.isPlaying
                                ? Icons.pause_circle_filled
                                : Icons.play_circle_fill,
                            size: 30,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Next channel',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 36,
                          ),
                          padding: EdgeInsets.zero,
                          onPressed: () => _changeChannel(1),
                          icon: const Icon(
                            Icons.skip_next_rounded,
                            size: 23,
                          ),
                        ),
                      ],
                    ),
                    ),
                  ),
                ),
              if (tvMode && _selectedChannel != null && _channelInfoVisible)
                Positioned(
                  // Keep the live information card slightly above the bottom edge
                  // so it does not sit on top of TV overscan/system UI.
                  bottom: initialized ? 48 : 20,
                  left: 18,
                  right: 18,
                  child: IgnorePointer(
                    child: _glass(
                      radius: 22,
                      blur: kTvLiveBlur ? 16 : 0,
                      color: const Color(0xB5101020),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Row(
                        children: [
                          Container(
                            width: 76,
                            height: 76,
                            decoration: BoxDecoration(
                              color: accentColor.withOpacity(0.18),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: accentColor.withOpacity(0.45)),
                            ),
                            child: _logoImage(_selectedChannel!) != null
                                ? ClipRRect(borderRadius: BorderRadius.circular(10), child: Image(image: _logoImage(_selectedChannel!)!, fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Icon(Icons.live_tv, color: accentColor)))
                                : const Icon(Icons.live_tv, color: accentColor, size: 30),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(_selectedChannel!.name.trim(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                                const SizedBox(height: 3),
                                Text('NOW · ${_epgForChannel(_selectedChannel!)?.title ?? 'Programme info unavailable'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Color(0xFFD2C8FF), fontWeight: FontWeight.w600)),
                                const SizedBox(height: 4),
                                ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: _epgProgress(_epgForChannel(_selectedChannel!)), minHeight: 4, backgroundColor: Colors.white12, valueColor: const AlwaysStoppedAnimation<Color>(accentColor))),
                                const SizedBox(height: 3),
                                Builder(builder: (context) { final schedule = _epgScheduleForChannel(_selectedChannel!); final now = DateTime.now().toUtc(); EpgProgram? next; for (final item in schedule) { if (item.start.isAfter(now)) { next = item; break; } } return Text('NEXT · ${next?.title ?? 'Not available'}${next == null ? '' : ' · ${_formatEpgTime(next.start)}'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.white70)); }),
                                const SizedBox(height: 3),
                                Text(_selectedChannel!.group, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.white60)),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          ValueListenableBuilder<Size>(
                            valueListenable: _player?.videoSize ?? _noVideoSize,
                            builder: (_, size, __) => Padding(
                              padding: EdgeInsets.only(right: _videoQualityLabel(size) == null ? 0 : 8),
                              child: _qualityBadge(size),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(color: Colors.redAccent.withOpacity(0.18), borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.redAccent.withOpacity(0.55))),
                            child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.circle, color: Colors.redAccent, size: 7), SizedBox(width: 6), Text('LIVE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.1))]),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (_playerError != null)
                Center(
                  child: FilledButton.icon(
                    onPressed: _selectedChannel == null
                        ? null
                        : () => _playChannel(_selectedChannel!),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry stream'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------
  // CATEGORY CHIPS
  // --------------------------------------------------
  Widget _buildCategories() {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        scrollDirection: Axis.horizontal,
        itemCount: _categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final category = _categories[index];
          return GlassChip(
            label: category,
            selected: _selectedCategory == category,
            onTap: () => setState(() => _selectedCategory = category),
          );
        },
      ),
    );
  }

  // --------------------------------------------------
  // CHANNEL TILE
  // --------------------------------------------------
  Widget _buildChannelTile(Channel channel) {
    final selected = _selectedChannel?.url == channel.url;
    final favorite = _favorites.contains(channel.url);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Glass(
        radius: 20,
        blur: 0, // lists: frosted gradient without per-tile live blur
        tint: selected ? accentColor : kGlassTint,
        strength: selected ? 0.9 : 0.8,
        borderColor: selected ? Colors.white.withOpacity(0.5) : null,
        glow: selected ? accentColor.withOpacity(0.28) : null,
        child: Material(
          type: MaterialType.transparency,
          // A plain Row (not ListTile) so the logo keeps an exact square box and
          // always renders as a true circle, never stretched into an oval.
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => _playChannel(channel),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 68,
                    height: 68,
                    child: _logoCard(channel, 68, selected: selected),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          channel.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: selected ? FontWeight.bold : FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          channel.group,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white54, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: favorite ? 'Remove favorite' : 'Add favorite',
                    onPressed: () => _toggleFavorite(channel),
                    icon: FavoriteHeart(on: favorite, size: 22),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------
  // PICTURE-IN-PICTURE
  // --------------------------------------------------
  // Native side (MainActivity) reports PiP mode changes through the channel.
  // A PiP window is small. Detecting it from the window size means the very
  // first PiP frame already shows only the video on black, instead of the
  // normal page (or a blank screen) until the native callback arrives.
  bool _looksLikePip(Size size) => size.height < 300 && size.width < 600;

  String? _lastPipRect;

  // Tells Android which part of the screen is the video so the PiP animation
  // zooms straight into the picture (no white/blank window while it starts).
  void _syncPipRect() {
    if (!mounted || _inPip || !Platform.isAndroid) return;
    try {
      final ro = _playerKey.currentContext?.findRenderObject();
      if (ro is! RenderBox || !ro.attached || !ro.hasSize) return;
      final dpr = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
      final o = ro.localToGlobal(Offset.zero);
      final r = [
        (o.dx * dpr).round(),
        (o.dy * dpr).round(),
        ((o.dx + ro.size.width) * dpr).round(),
        ((o.dy + ro.size.height) * dpr).round(),
      ];
      final key = r.join(',');
      if (key == _lastPipRect) return;
      _lastPipRect = key;
      _pipChannel.invokeMethod('setPipSourceRect', {'rect': r}).catchError((Object e) {
        debugPrint('PiP rect error: $e');
        return null;
      });
    } catch (e) {
      debugPrint('PiP rect error: $e');
    }
  }

  Future<dynamic> _onPipCall(MethodCall call) async {
    if (call.method == 'pipChanged') {
      final active = call.arguments == true;
      if (!mounted || active == _inPip) return null;
      setState(() {
        _inPip = active;
        if (active) {
          _controlsVisible = false;
          _channelInfoVisible = false;
          _tvSidebarVisible = false;
          _tvEpgVisible = false;
        }
      });
      if (!active) _focusTvPlayer();
    }
    return null;
  }

  // Tell Android whether Home/Recents should auto-enter PiP (only while a
  // stream is actually playing).
  Future<void> _syncPipAutoEnter() async {
    final player = _player;
    final enabled = player != null && player.value.isInitialized && player.value.isPlaying;
    try {
      await _pipChannel.invokeMethod('setPipAutoEnter', {
        'enabled': enabled,
        'aspect': player?.value.aspectRatio ?? 16 / 9,
      });
    } catch (e) {
      debugPrint('PiP sync error: $e');
    }
  }

  // Keep the live player/controller alive while Android shows the PiP window.
  // If the app is fully hidden (PiP window dismissed, or Home without PiP),
  // pause so audio does not keep playing invisibly; resume on return.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final player = _player;
    final leaving = state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached;
    if (leaving && !_inPip) {
      // Silence everything immediately (also on TV when the app is closed):
      // cancel any channel still connecting, mute, then pause the live one.
      ++_playRequestId;
      final pending = _pendingPlayer;
      _pendingPlayer = null;
      if (pending != null) {
        unawaited(pending.dispose().catchError((Object e) { debugPrint('Pending stop error: $e'); }));
      }
      if (player != null) {
        if (!_userPaused) _pausedForBackground = true;
        unawaited(() async {
          try { await player.setVolume(0.0); } catch (_) {}
          try { await player.pause(); } catch (e) { debugPrint('Background pause error: $e'); }
        }());
      }
      if (_connecting && mounted) setState(() => _connecting = false);
    } else if (state == AppLifecycleState.resumed && mounted) {
      if (player != null) {
        unawaited(() async {
          try { await player.setVolume(1.0); } catch (_) {}
          if (_pausedForBackground) {
            _pausedForBackground = false;
            try { await player.play(); } catch (e) { debugPrint('Resume error: $e'); }
          }
        }());
      }
      setState(() {});
      _syncPipAutoEnter();
      _refreshStaleData();
    }
  }

  // Auto-update when the app comes back after a long time in the background.
  void _refreshStaleData() {
    if (_epgInitDone && !_epgLoading) {
      final age = DateTime.now().millisecondsSinceEpoch - _epgSavedAt;
      if (_epgSavedAt == 0 || age < 0 || age > const Duration(hours: 2).inMilliseconds) {
        unawaited(_loadEpg());
      }
    }
    unawaited(LocalStore.instance.syncLogos());
  }

  void _onStoreChanged() {
    _logoUrlCache.clear();
    if (_storeNotifyTimer?.isActive ?? false) return;
    _storeNotifyTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() {});
    });
  }

  // --------------------------------------------------
  // DISPOSE
  // --------------------------------------------------
  @override
  void dispose() {
    NoticeService.instance.stop();
    _pipChannel.setMethodCallHandler(null);
    unawaited(_pipChannel.invokeMethod('setPipAutoEnter', {'enabled': false}).catchError((Object e) { debugPrint('PiP cleanup error: $e'); }));
    _controlsTimer?.cancel();
    _channelInfoTimer?.cancel();
    _epgClock?.cancel();
    _epgRefreshTimer?.cancel();
    _storeNotifyTimer?.cancel();
    LocalStore.instance.revision.removeListener(_onStoreChanged);
    _playbackHealthTimer?.cancel();
    _playlistRequestId++;
    _playRequestId++;
    final pendingPlayer = _pendingPlayer;
    _pendingPlayer = null;
    if (pendingPlayer != null) { unawaited(pendingPlayer.dispose().catchError((Object e) { debugPrint('Pending player cleanup error: $e'); })); }
    _searchController.dispose();
    _tvChannelScrollController.dispose();
    _tvCategoryScrollController.dispose();
    _tvEpgScrollController.dispose();
    _tvPlayerFocusNode.dispose();
    _tvSearchFocusNode.dispose();
    for (final node in _tvChannelFocusNodes.values) { node.dispose(); }
    _tvChannelFocusNodes.clear();
    final activePlayer = _player;
    _player = null;
    if (activePlayer != null) { unawaited(activePlayer.dispose().catchError((Object e) { debugPrint('Active player cleanup error: $e'); })); }
    unawaited(WakelockPlus.disable().catchError((Object e) { debugPrint('Wakelock cleanup error: $e'); }));
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
    );
    SystemChrome.setPreferredOrientations(
      DeviceOrientation.values,
    );
    super.dispose();
  }

  // --------------------------------------------------
  // MAIN SCREEN
  // --------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final channels = _visibleChannels;
    final media = MediaQuery.of(context);
    final inPip = _inPip || _looksLikePip(media.size);
    final useTvLayout = !inPip && !_fullscreen && media.size.width >= 850 && media.size.width > media.size.height;
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPipRect());
    return Focus(
      autofocus: true,
      onKeyEvent: _handleRemoteKey,
      child: WillPopScope(
      onWillPop: _handleBack,
      child: Scaffold(
        backgroundColor: inPip ? Colors.transparent : null,
        resizeToAvoidBottomInset: !inPip,
        extendBodyBehindAppBar: !(_fullscreen || inPip || useTvLayout),
        appBar: (_fullscreen || inPip || useTvLayout)
            ? null
            : AppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                scrolledUnderElevation: 0,
                surfaceTintColor: Colors.transparent,
                flexibleSpace: ClipRect(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.white.withOpacity(0.10),
                            Colors.white.withOpacity(0.03),
                          ],
                        ),
                        border: Border(
                          bottom: BorderSide(color: Colors.white.withOpacity(0.14)),
                        ),
                      ),
                    ),
                  ),
                ),
                titleSpacing: 12,
                title: Row(
                  children: [
                    // Animated TV-streaming logo (drawn in code, no image).
                    const AnimatedTvLogo(size: 44),
                    const SizedBox(width: 10),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ShaderMask(
                          shaderCallback: (rect) => const LinearGradient(
                            colors: [Colors.white, Color(0xFFD6CCFF), Color(0xFFAA98FF)],
                          ).createShader(rect),
                          child: const Text(
                            'Ananta OTT',
                            style: TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.6,
                              height: 1.05,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const Text(
                          'LIVE TV  •  STREAMING',
                          style: TextStyle(
                            fontSize: 8.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.6,
                            color: Color(0xAAC9BEFF),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                actions: [
                  GlassIconButton(
                    tooltip: 'Favorites',
                    onPressed: () {
                      setState(() {
                        _showFavoritesOnly = !_showFavoritesOnly;
                      });
                    },
                    icon: _showFavoritesOnly
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    color: _showFavoritesOnly ? const Color(0xFFFF7BA9) : Colors.white,
                    glow: _showFavoritesOnly ? const Color(0xFFFF4F8B) : null,
                    anim: GlassIconAnim.pop,
                  ),
                  const NoticeBell(),
                  GlassIconButton(
                    tooltip: 'Refresh playlist',
                    onPressed: _loadingPlaylist ? null : _loadPlaylist,
                    icon: Icons.refresh_rounded,
                    busy: _loadingPlaylist,
                    anim: GlassIconAnim.spin,
                  ),
                  const SizedBox(width: 8),
                ],
              ),
        body: (_fullscreen || inPip)
            ? _buildPlayer(fullscreen: true)
            : useTvLayout
                ? _buildTvLayout(channels)
                : GlassBackground(
                child: Column(
                  children: [
                    SizedBox(height: media.padding.top + kToolbarHeight),
                    _buildPlayer(fullscreen: false),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        14,
                        12,
                        14,
                        8,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: _NowPlayingHeader(
                              channelName: _selectedChannel?.name.trim() ?? '',
                              active: _selectedChannel != null && !_connecting,
                            ),
                          ),
                          Text(
                            '${channels.length} channels',
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                      ),
                      child: _glass(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                        ),
                        radius: 15,
                        child: TextField(
                          controller: _searchController,
                          onChanged: (value) {
                            setState(() => _searchQuery = value);
                          },
                          decoration: InputDecoration(
                            hintText: 'Search channels...',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _searchQuery.isEmpty
                                ? null
                                : IconButton(
                                    onPressed: () {
                                      _searchController.clear();
                                      setState(
                                        () => _searchQuery = '',
                                      );
                                    },
                                    icon: const Icon(Icons.clear),
                                  ),
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _buildCategories(),
                    Expanded(
                      child: channels.isEmpty
                          ? Center(
                              child: Text(
                                _showFavoritesOnly
                                    ? 'No favorites in this category'
                                    : 'No channels found',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white60,
                                ),
                              ),
                            )
                          : MediaQuery.removePadding(
                              context: context,
                              removeTop: true,
                              child: ListView.builder(
                              key: ValueKey(
                                '$_selectedCategory-'
                                '$_showFavoritesOnly-$_searchQuery',
                              ),
                              shrinkWrap: false,
                              // No implicit status-bar padding: the player already
                              // sits below the app bar, so the default top inset
                              // left a blank band above the first channel.
                              padding: EdgeInsets.only(bottom: media.padding.bottom + 8),
                              itemCount: channels.length,
                              itemBuilder: (context, index) {
                                return _buildChannelTile(
                                  channels[index],
                                );
                              },
                            ),
                            ),
                    ),
                  ],
                ),
              ),
      ),
      ),
    );
  }
}


/// "Now playing" header: animated equalizer icon, small label and the
/// current channel name.
class _NowPlayingHeader extends StatefulWidget {
  const _NowPlayingHeader({required this.channelName, required this.active});
  final String channelName;
  final bool active;

  @override
  State<_NowPlayingHeader> createState() => _NowPlayingHeaderState();
}

class _NowPlayingHeaderState extends State<_NowPlayingHeader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400))
    ..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Just an animated live dot (pulsing ripple) shown before the channel name.
  Widget _liveIndicator(double t, double glow) {
    final color = widget.active ? const Color(0xFFFF3B4E) : Colors.white38;
    final ripple = widget.active ? t : 0.0;
    return SizedBox(
      width: 16,
      height: 16,
      child: Stack(alignment: Alignment.center, children: [
        if (widget.active)
          Container(
            width: 6 + 10 * ripple,
            height: 6 + 10 * ripple,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withOpacity(0.55 * (1 - ripple)),
            ),
          ),
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            boxShadow: widget.active
                ? [BoxShadow(color: color.withOpacity(glow + 0.2), blurRadius: 8)]
                : null,
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.channelName.isEmpty ? 'Select a channel' : widget.channelName;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _ctrl.value;
        final glow = 0.25 + 0.2 * (0.5 + 0.5 * math.sin(t * 2 * math.pi));
        return Row(children: [
          _liveIndicator(t, glow),
          const SizedBox(width: 6),
          Expanded(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, letterSpacing: 0.9, fontWeight: FontWeight.w700, color: Color(0xFFC9BEFF))),
          ),
        ]);
      },
    );
  }
}
