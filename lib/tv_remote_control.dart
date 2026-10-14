import 'package:flutter/services.dart';

/// Dedicated key map for Android TV and Xiaomi TV Box remotes.
///
/// Keep physical remote key aliases and TV-specific timing in this file.
/// The player screen uses these helpers to apply navigation behavior without
/// scattering key comparisons throughout the widget tree.
abstract final class RemoteControl {
  /// Channel information card duration after pressing Up or changing channel.
  static const Duration channelInfoDuration = Duration(seconds: 15);

  static bool isUp(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.arrowUp;

  static bool isDown(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.arrowDown;

  static bool isLeft(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.arrowLeft;

  static bool isRight(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.arrowRight;

  /// OK / Select key aliases commonly emitted by Android TV remotes.
  static bool isConfirm(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.select;

  static bool isEnter(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.enter;

  static bool isNumpadEnter(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.numpadEnter;

  static bool isGamepadConfirm(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.gameButtonA;

  static bool isEscape(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.escape;

  static bool isBack(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.browserBack;

  static bool isDirectional(LogicalKeyboardKey key) =>
      isUp(key) || isDown(key) || isLeft(key) || isRight(key);

  static bool isActivation(LogicalKeyboardKey key) =>
      isConfirm(key) || isEnter(key) || isNumpadEnter(key) || isGamepadConfirm(key);
}
