import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const String appName = 'Ananta OTT';
const String playlistUrl =
    'https://raw.githubusercontent.com/anantaabid24/Ananta-Ott/refs/heads/main/channels.m3u';
const String ptvStreamUrl =
    'http://103.185.24.134:3001/ptv/index.m3u8';

const Color accentColor = Color(0xFF9B87FF);
const Color backgroundColor = Color(0xFF090914);
const Color glassColor = Color(0xFF211F35);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AnantaOttApp());
}

class Channel {
  final String name;
  final String url;
  final String group;
  final String logo;
  const Channel({
    required this.name,
    required this.url,
    this.group = 'Live TV',
    this.logo = '',
  });
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
      ),
      home: const AnantaHomePage(),
    );
  }
}

class AnantaHomePage extends StatefulWidget {
  const AnantaHomePage({super.key});
  @override
  State<AnantaHomePage> createState() => _AnantaHomePageState();
}

class _AnantaHomePageState extends State<AnantaHomePage> {
  final TextEditingController _searchController = TextEditingController();
  List<Channel> _channels = [ptvChannel];
  Set<String> _favorites = {};
  VideoPlayerController? _player;
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
  bool _tvSidebarVisible = true;
  bool _tvShowingCategories = false;
  int _tvFocusedChannelIndex = 0;
  int _tvFocusedCategoryIndex = 0;
  final ScrollController _tvChannelScrollController = ScrollController();
  final FocusNode _tvPlayerFocusNode = FocusNode(debugLabel: 'tv-player');
  final FocusNode _tvSearchFocusNode = FocusNode(debugLabel: 'tv-channel-search');
  final Map<String, FocusNode> _tvChannelFocusNodes = {};
  int _playlistRequestId = 0;
  int _playRequestId = 0;

  @override
  void initState() {
    super.initState();
    _loadFavorites();
    _loadPlaylist();
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
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_tvChannelScrollController.hasClients) return;
      // Scroll first so ListView builds the destination row before requesting
      // its FocusNode. Requesting focus before this point fails for off-screen
      // rows and makes UP/DOWN appear to stop working on Android TV.
      final target = (safeIndex * 80.0).clamp(
        0.0,
        _tvChannelScrollController.position.maxScrollExtent,
      ).toDouble();
      await _tvChannelScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOutCubic,
      );
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !requestFocus) return;
      final node = _tvChannelFocusNodes[channels[safeIndex].url];
      if (node != null && node.canRequestFocus) node.requestFocus();
    });
  }

  void _focusTvPlayer() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tvPlayerFocusNode.canRequestFocus) return;
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
    _focusTvPlayer();
  }

  void _showTvChannels({int? index}) {
    final channels = _visibleChannels;
    setState(() {
      _tvShowingCategories = false;
      _tvSidebarVisible = true;
      if (index != null && channels.isNotEmpty) {
        _tvFocusedChannelIndex = index.clamp(0, channels.length - 1).toInt();
      }
    });
    FocusManager.instance.primaryFocus?.unfocus();
    _focusTvChannel(_tvFocusedChannelIndex);
  }

  KeyEventResult _handleRemoteKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final primaryContext = FocusManager.instance.primaryFocus?.context;
    final key = event.logicalKey;
    final channels = _visibleChannels;
    final categories = _categories;
    final editingSearch = primaryContext?.widget is EditableText;

    // Search remains usable with the TV keyboard. D-pad UP opens categories;
    // DOWN moves into results, avoiding a focus trap inside the text field.
    if (editingSearch) {
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

    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
      final delta = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      if (_tvShowingCategories) {
        if (categories.isNotEmpty) {
          setState(() => _tvFocusedCategoryIndex = (_tvFocusedCategoryIndex + delta).clamp(0, categories.length - 1).toInt());
        }
        return KeyEventResult.handled;
      }
      if (channels.isEmpty) return KeyEventResult.handled;
      if (!_tvSidebarVisible) {
        final current = channels.indexWhere((c) => c.url == _selectedChannel?.url);
        _focusTvChannel((current >= 0 ? current : _tvFocusedChannelIndex));
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
        _focusTvCategory(_categories.indexOf(_selectedCategory).clamp(0, categories.length - 1).toInt());
      } else if (_tvShowingCategories) {
        _showTvChannels(index: _tvFocusedChannelIndex);
      } else {
        if (channels.isNotEmpty) _changeChannel(-1);
        setState(() => _tvSidebarVisible = false);
        _focusTvPlayer();
        _showPlayerControls();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowRight) {
      if (_tvShowingCategories) {
        _showTvChannels(index: _tvFocusedChannelIndex);
      } else if (_tvSidebarVisible) {
        if (channels.isNotEmpty) _changeChannel(1);
        setState(() => _tvSidebarVisible = false);
        _focusTvPlayer();
        _showPlayerControls();
      } else {
        if (channels.isNotEmpty) _changeChannel(1);
        _showPlayerControls();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.browserBack) {
      if (_tvShowingCategories) {
        _showTvChannels(index: _tvFocusedChannelIndex);
        return KeyEventResult.handled;
      }
      if (_tvSidebarVisible) {
        setState(() => _tvSidebarVisible = false);
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
    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
      final delta = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      if (key == LogicalKeyboardKey.arrowUp && index == 0) {
        _tvSearchFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      _focusTvChannel((index + delta).clamp(0, channels.length - 1).toInt());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.gameButtonA) {
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
          child: Focus(
            focusNode: _tvPlayerFocusNode,
            onKeyEvent: _handleRemoteKey,
            child: _buildPlayer(fullscreen: true),
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
              child: ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xB5101020),
                      border: Border(
                        right: BorderSide(color: Colors.white.withOpacity(0.12)),
                      ),
                    ),
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
                                  icon: Icon(_showFavoritesOnly ? Icons.favorite : Icons.favorite_border,
                                    color: _showFavoritesOnly ? Colors.pinkAccent : Colors.white70, size: 19),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: _tvShowingCategories
                                ? ListView.builder(
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
                                            color: focused ? accentColor.withOpacity(0.34) : Colors.white.withOpacity(0.045),
                                            borderRadius: BorderRadius.circular(12),
                                            border: Border.all(color: focused ? accentColor : (selected ? accentColor.withOpacity(0.55) : Colors.white.withOpacity(0.08)), width: focused ? 2 : 1),
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
                                        itemExtent: 80,
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
              color: focused
                  ? accentColor.withOpacity(0.34)
                  : selected ? Colors.white.withOpacity(0.13) : Colors.white.withOpacity(0.035),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: focused ? accentColor : (selected ? accentColor.withOpacity(0.6) : Colors.white.withOpacity(0.07)),
                width: focused ? 2 : 1,
              ),
            ),
            child: ListTile(
              focusColor: accentColor.withOpacity(0.22),
              hoverColor: accentColor.withOpacity(0.16),
              dense: false,
              minVerticalPadding: 5,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              leading: CircleAvatar(
                radius: 18,
                backgroundColor: accentColor.withOpacity(0.16),
                backgroundImage: channel.logo.isNotEmpty ? NetworkImage(channel.logo) : null,
                child: channel.logo.isEmpty ? const Icon(Icons.live_tv, color: accentColor, size: 18) : null,
              ),
              title: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, fontWeight: selected ? FontWeight.bold : FontWeight.w500)),
              subtitle: Text(channel.group, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 10)),
              trailing: Icon(favorite ? Icons.favorite : Icons.chevron_right,
                color: favorite ? Colors.pinkAccent : Colors.white38, size: 18),
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
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: color.withOpacity(0.78),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: Colors.white.withOpacity(0.10),
            ),
          ),
          child: child,
        ),
      ),
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
            ),
          );
        }
        name = null;
        group = 'Live TV';
        logo = '';
      }
    }
    return result;
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
      final baseUri = Uri.parse(playlistUrl);
      final query = Map<String, String>.from(
        baseUri.queryParameters,
      );
      query['_refresh'] =
          DateTime.now().millisecondsSinceEpoch.toString();
      final uri = baseUri.replace(queryParameters: query);
      final response = await http
          .get(
            uri,
            headers: const {
              'User-Agent': 'AnantaOTT/1.0',
              'Accept': '*/*',
              'Cache-Control': 'no-cache',
              'Pragma': 'no-cache',
            },
          )
          .timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) {
        throw Exception(
          'Playlist server returned HTTP ${response.statusCode}',
        );
      }
      final parsed = _parseM3u(response.body);
      if (parsed.isEmpty) {
        throw Exception('No valid channels found in the M3U file.');
      }
      final updated = <Channel>[ptvChannel];
      final seen = <String>{ptvChannel.url};
      for (final channel in parsed) {
        if (seen.add(channel.url)) {
          updated.add(channel);
        }
      }
      if (!mounted || requestId != _playlistRequestId) return;
      final groups = updated.map((c) => c.group).toSet();
      setState(() {
        _channels = updated;
        if (_selectedCategory != 'All' &&
            !groups.contains(_selectedCategory)) {
          _selectedCategory = 'All';
        }
        _status = '${updated.length} channels loaded';
      });
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
  Future<void> _playChannel(Channel channel) async {
    if (_connecting) return;
    final requestId = ++_playRequestId;
    final oldPlayer = _player;
    final oldChannel = _selectedChannel;
    _controlsTimer?.cancel();
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(channel.url),
      httpHeaders: const {
        'User-Agent': 'VLC/3.0.20 LibVLC/3.0.20',
        'Accept': '*/*',
        'Connection': 'keep-alive',
      },
    );
    setState(() {
      // Keep the currently playing controller visible while the next stream
      // initializes. This avoids a black screen on every channel change.
      _selectedChannel = channel;
      _playerError = null;
      _connecting = true;
      _controlsVisible = true;
      _tvSidebarVisible = false;
      _status = 'Connecting to ${channel.name}...';
    });
    _focusTvPlayer();
    try {
      await controller.initialize().timeout(
        const Duration(seconds: 35),
      );
      if (!mounted || requestId != _playRequestId) {
        await controller.dispose();
        return;
      }
      if (controller.value.hasError) {
        throw Exception(
          controller.value.errorDescription ?? 'Player error',
        );
      }

      // Switch only after the new stream is ready. Pause the old stream at
      // the handoff, then replace/dispose it once the new player starts.
      await oldPlayer?.pause();
      await controller.play();
      if (!mounted || requestId != _playRequestId) {
        await controller.dispose();
        return;
      }
      setState(() {
        _player = controller;
        _status = 'Playing ${channel.name}';
        _connecting = false;
      });
      await oldPlayer?.dispose();
      await WakelockPlus.enable();
      _scheduleControlsHide();
    } on TimeoutException {
      await controller.dispose();
      if (!mounted || requestId != _playRequestId) return;
      if (oldPlayer != null && oldPlayer.value.isInitialized && !oldPlayer.value.isPlaying) {
        try { await oldPlayer.play(); } catch (_) {}
      }
      if (oldPlayer == null || !oldPlayer.value.isPlaying) {
        await WakelockPlus.disable();
      }
      setState(() {
        _player = oldPlayer;
        _selectedChannel = oldChannel;
        _playerError = oldPlayer == null ? 'Connection timed out. Please retry.' : null;
        _status = 'Connection timed out';
        _connecting = false;
      });
    } catch (e) {
      debugPrint('Playback error for ${channel.url}: $e');
      await controller.dispose();
      if (!mounted || requestId != _playRequestId) return;
      if (oldPlayer != null && oldPlayer.value.isInitialized && !oldPlayer.value.isPlaying) {
        try { await oldPlayer.play(); } catch (_) {}
      }
      if (oldPlayer == null || !oldPlayer.value.isPlaying) {
        await WakelockPlus.disable();
      }
      setState(() {
        _player = oldPlayer;
        _selectedChannel = oldChannel;
        _playerError = oldPlayer == null ? e.toString() : null;
        _status = 'Playback failed';
        _connecting = false;
      });
    }
  }

  Future<void> _togglePlayback() async {
    final player = _player;
    if (player == null || !player.value.isInitialized) return;
    try {
      if (player.value.isPlaying) {
        await player.pause();
        await WakelockPlus.disable();
      } else {
        await player.play();
        await WakelockPlus.enable();
      }
      if (!mounted) return;
      setState(() {});
      _showPlayerControls();
    } catch (e) {
      debugPrint('Playback control error: $e');
    }
  }

  Future<void> _changeChannel(int direction) async {
    final list = _visibleChannels;
    if (list.isEmpty || _connecting) return;
    final currentIndex = list.indexWhere(
      (channel) => channel.url == _selectedChannel?.url,
    );
    final nextIndex = currentIndex == -1
        ? (direction > 0 ? 0 : list.length - 1)
        : (currentIndex + direction + list.length) % list.length;
    await _playChannel(list[nextIndex]);
  }

  // --------------------------------------------------
  // FULLSCREEN - FIXED: Horizontal only when entering, vertical only when exiting
  // --------------------------------------------------
  Future<void> _setFullscreen(bool value) async {
    if (value) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      // Restore sensor/system orientation rather than locking every phone to portrait.
      // Android TV devices can remain in their normal landscape orientation.
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    if (!mounted) return;
    setState(() {
      _fullscreen = value;
      _controlsVisible = true;
    });
    _scheduleControlsHide();
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
      setState(() => _tvSidebarVisible = false);
      FocusManager.instance.primaryFocus?.unfocus();
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
  Widget _buildPlayer({required bool fullscreen}) {
    final media = MediaQuery.of(context);
    final tvMode = media.size.width >= 850 && media.size.width > media.size.height;
    final player = _player;
    final initialized = player?.value.isInitialized == true;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: initialized ? _togglePlayerControls : null,
      child: Container(
        width: double.infinity,
        height: fullscreen ? double.infinity : 220,
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (initialized)
              Center(
                child: AspectRatio(
                  aspectRatio: player!.value.aspectRatio > 0
                      ? player.value.aspectRatio
                      : 16 / 9,
                  child: VideoPlayer(player),
                ),
              )
            else
              Center(
                child: _connecting
                    ? const CircularProgressIndicator(
                        color: accentColor,
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
            // All controls disappear together after 2 seconds.
            if (_controlsVisible) ...[
              Positioned(
                top: 8,
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
                Center(
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
              if (tvMode && _selectedChannel != null)
                Positioned(
                  bottom: initialized ? 56 : 12,
                  left: 18,
                  right: 18,
                  child: IgnorePointer(
                    child: _glass(
                      radius: 14,
                      color: const Color(0xB5101020),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: accentColor.withOpacity(0.18),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: accentColor.withOpacity(0.45)),
                            ),
                            child: _selectedChannel!.logo.isNotEmpty
                                ? ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.network(_selectedChannel!.logo, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.live_tv, color: accentColor)))
                                : const Icon(Icons.live_tv, color: accentColor, size: 23),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(_selectedChannel!.name.trim(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                                const SizedBox(height: 3),
                                Text(_selectedChannel!.group, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.white70)),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
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
              if (initialized)
                Positioned(
                  bottom: 8,
                  left: 10,
                  right: 10,
                  child: _glass(
                    radius: 10,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 7,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: VideoProgressIndicator(
                            player!,
                            allowScrubbing: true,
                            padding: EdgeInsets.zero,
                            colors: const VideoProgressColors(
                              playedColor: accentColor,
                              bufferedColor: Colors.white38,
                              backgroundColor: Colors.white24,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        IconButton(
                          tooltip: 'Favorite',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 30,
                            minHeight: 30,
                          ),
                          padding: EdgeInsets.zero,
                          onPressed: _selectedChannel == null
                              ? null
                              : () => _toggleFavorite(
                                    _selectedChannel!,
                                  ),
                          icon: Icon(
                            _selectedChannel != null &&
                                    _favorites.contains(
                                      _selectedChannel!.url,
                                    )
                                ? Icons.favorite
                                : Icons.favorite_border,
                            size: 19,
                            color: Colors.pinkAccent,
                          ),
                        ),
                      ],
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
      height: 46,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        scrollDirection: Axis.horizontal,
        itemCount: _categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final category = _categories[index];
          final selected = _selectedCategory == category;
          return ChoiceChip(
            label: Text(category),
            selected: selected,
            showCheckmark: false,
            backgroundColor: glassColor,
            selectedColor: accentColor,
            labelStyle: TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight:
                  selected ? FontWeight.bold : FontWeight.normal,
            ),
            onSelected: (_) {
              setState(() => _selectedCategory = category);
            },
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
      child: _glass(
        radius: 15,
        padding: EdgeInsets.zero,
        color: selected ? const Color(0xFF373052) : glassColor,
        child: ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          leading: CircleAvatar(
            radius: 21,
            backgroundColor: accentColor.withOpacity(0.17),
            backgroundImage: channel.logo.isNotEmpty ? NetworkImage(channel.logo) : null,
            child: channel.logo.isEmpty
                ? const Icon(Icons.live_tv, color: accentColor, size: 21)
                : null,
          ),
          title: Text(
            channel.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.bold : FontWeight.w500,
            ),
          ),
          subtitle: Text(
            channel.group,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
          trailing: IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: favorite ? 'Remove favorite' : 'Add favorite',
            onPressed: () => _toggleFavorite(channel),
            icon: Icon(
              favorite ? Icons.favorite : Icons.favorite_border,
              color: favorite ? Colors.pinkAccent : Colors.white54,
              size: 20,
            ),
          ),
          onTap: () => _playChannel(channel),
        ),
      ),
    );
  }

  // --------------------------------------------------
  // DISPOSE
  // --------------------------------------------------
  @override
  void dispose() {
    _controlsTimer?.cancel();
    _playlistRequestId++;
    _playRequestId++;
    _searchController.dispose();
    _tvChannelScrollController.dispose();
    _tvPlayerFocusNode.dispose();
    _tvSearchFocusNode.dispose();
    for (final node in _tvChannelFocusNodes.values) { node.dispose(); }
    _tvChannelFocusNodes.clear();
    _player?.dispose();
    WakelockPlus.disable();
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
    final useTvLayout = !_fullscreen && media.size.width >= 850 && media.size.width > media.size.height;
    return Focus(
      autofocus: true,
      onKeyEvent: _handleRemoteKey,
      child: WillPopScope(
      onWillPop: _handleBack,
      child: Scaffold(
        appBar: (_fullscreen || useTvLayout)
            ? null
            : AppBar(
                backgroundColor: backgroundColor,
                title: const Row(
                  children: [
                    Icon(
                      Icons.blur_on,
                      color: accentColor,
                      size: 29,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Ananta OTT',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
                actions: [
                  IconButton(
                    tooltip: 'Favorites',
                    onPressed: () {
                      setState(() {
                        _showFavoritesOnly = !_showFavoritesOnly;
                      });
                    },
                    icon: Icon(
                      _showFavoritesOnly
                          ? Icons.favorite
                          : Icons.favorite_border,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh playlist',
                    onPressed:
                        _loadingPlaylist ? null : _loadPlaylist,
                    icon: _loadingPlaylist
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: accentColor,
                            ),
                          )
                        : const Icon(Icons.refresh),
                  ),
                ],
              ),
        body: _fullscreen
            ? _buildPlayer(fullscreen: true)
            : useTvLayout
                ? _buildTvLayout(channels)
                : Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF19152B),
                      backgroundColor,
                      Color(0xFF101020),
                    ],
                  ),
                ),
                child: Column(
                  children: [
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
                          const Expanded(
                            child: Text(
                              'Explore channels',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                              ),
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
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        16,
                        8,
                        16,
                        4,
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
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
                          : ListView.builder(
                              key: ValueKey(
                                '$_selectedCategory-'
                                '$_showFavoritesOnly-$_searchQuery',
                              ),
                              itemCount: channels.length,
                              itemBuilder: (context, index) {
                                return _buildChannelTile(
                                  channels[index],
                                );
                              },
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
