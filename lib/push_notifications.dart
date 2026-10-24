import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'firebase_config.dart';

/// Lets the app show an in-app banner when a push arrives in the foreground.
final GlobalKey<ScaffoldMessengerState> pushMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

bool get _configured =>
    kFirebaseApiKey.isNotEmpty &&
    kFirebaseAppId.isNotEmpty &&
    kFirebaseSenderId.isNotEmpty &&
    kFirebaseProjectId.isNotEmpty;

const FirebaseOptions _options = FirebaseOptions(
  apiKey: kFirebaseApiKey,
  appId: kFirebaseAppId,
  messagingSenderId: kFirebaseSenderId,
  projectId: kFirebaseProjectId,
);

/// Runs in its own isolate when a data message arrives while the app is closed.
/// (Notification messages are shown by Android automatically.)
@pragma('vm:entry-point')
Future<void> pushBackgroundHandler(RemoteMessage message) async {
  try {
    if (_configured && Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options: _options);
    }
  } catch (_) {}
}

class PushNotifications {
  PushNotifications._();

  /// Safe to call at startup: never throws, never blocks the UI, and does
  /// nothing until the Firebase values in firebase_config.dart are filled in.
  static Future<void> init() async {
    if (!_configured || kIsWeb) return;
    try {
      await Firebase.initializeApp(options: _options);
      final messaging = FirebaseMessaging.instance;
      FirebaseMessaging.onBackgroundMessage(pushBackgroundHandler);
      // Android 13+ asks the user for notification permission here.
      await messaging.requestPermission(alert: true, badge: true, sound: true);
      await messaging.subscribeToTopic(kPushTopic);
      FirebaseMessaging.onMessage.listen(_showForeground);
      final token = await messaging.getToken();
      debugPrint('FCM token: $token');
    } catch (error) {
      debugPrint('Push notifications unavailable: $error');
    }
  }

  static void _showForeground(RemoteMessage message) {
    final n = message.notification;
    final title = n?.title ?? message.data['title']?.toString();
    final body = n?.body ?? message.data['body']?.toString();
    if ((title ?? '').isEmpty && (body ?? '').isEmpty) return;
    final messenger = pushMessengerKey.currentState;
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
        backgroundColor: const Color(0xFF2A2250),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if ((title ?? '').isNotEmpty)
              Text(title!, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
            if ((body ?? '').isNotEmpty)
              Text(body!, style: const TextStyle(color: Colors.white70)),
          ],
        ),
      ));
  }
}
