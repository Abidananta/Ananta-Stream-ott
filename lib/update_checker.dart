import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'app_updater.dart';

/// Checks a remotely hosted JSON manifest and prompts users when a newer
/// Ananta OTT APK is available.
///
/// Optional manifest field `mirrors`: list of extra APK URLs tried when
/// `downloadUrl` cannot be reached.
class AppUpdateChecker {
  AppUpdateChecker._();

  static const String manifestUrl =
      'https://raw.githubusercontent.com/Abidananta/Ananta-Stream-ott/refs/heads/main/version.json';
  static const String releaseUrl =
      'https://github.com/Abidananta/Ananta-Stream-ott/releases/latest';

  /// True while the update dialog is on screen. The player page checks this so
  /// it does not steal D-pad focus from the dialog buttons on Android TV.
  static final ValueNotifier<bool> dialogOpen = ValueNotifier<bool>(false);

  static const MethodChannel _installer =
      MethodChannel('com.ananta.ott/installer');

  static Future<void> _cleanup() async {
    if (!Platform.isAndroid) return;
    try {
      await _installer.invokeMethod<void>('cleanup');
    } catch (_) {}
  }

  static Future<void> checkForUpdate(BuildContext context) async {
    try {
      final response = await http
          .get(Uri.parse(
              '$manifestUrl?t=${DateTime.now().millisecondsSinceEpoch}'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return;

      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) return;

      final latestVersion = (data['version'] ?? '').toString().trim();
      final latestBuild = int.tryParse('${data['versionCode'] ?? 0}') ?? 0;
      final releaseNotes =
          (data['releaseNotes'] ?? 'Performance improvements and bug fixes.')
              .toString();
      final manifestDownloadUrl = (data['downloadUrl'] ?? '').toString().trim();
      final downloadUrl =
          manifestDownloadUrl.isNotEmpty ? manifestDownloadUrl : releaseUrl;
      final mirrors = (data['mirrors'] is List)
          ? (data['mirrors'] as List)
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList()
          : <String>[];
      if (latestVersion.isEmpty || !context.mounted) return;

      final packageInfo = await PackageInfo.fromPlatform();
      final installedBuild = int.tryParse(packageInfo.buildNumber) ?? 0;
      if (latestBuild <= installedBuild) {
        // Up to date: remove any APK left behind by a previous update.
        await _cleanup();
        return;
      }
      if (!context.mounted) return;

      dialogOpen.value = true;
      try {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 9, sigmaY: 9),
            child: UpdateDialog(
              version: latestVersion,
              notes: releaseNotes,
              downloadUrl: downloadUrl,
              fallbackUrl: releaseUrl,
              mirrors: mirrors,
            ),
          ),
        );
      } finally {
        dialogOpen.value = false;
      }
    } catch (e) {
      // Update checks must never prevent the app/player from starting.
      debugPrint('Update check failed: $e');
      dialogOpen.value = false;
    }
  }
}
