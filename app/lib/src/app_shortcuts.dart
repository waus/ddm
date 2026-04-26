import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

SingleActivator newMessageShortcutActivator() {
  final isMacOS = defaultTargetPlatform == TargetPlatform.macOS;
  return SingleActivator(
    LogicalKeyboardKey.keyN,
    control: !isMacOS,
    meta: isMacOS,
  );
}

SingleActivator submitMessageShortcutActivator() {
  final isMacOS = defaultTargetPlatform == TargetPlatform.macOS;
  return SingleActivator(
    LogicalKeyboardKey.enter,
    control: !isMacOS,
    meta: isMacOS,
  );
}

String newMessageShortcutLabel() {
  return defaultTargetPlatform == TargetPlatform.macOS ? 'Cmd+N' : 'Ctrl+N';
}

String submitMessageShortcutLabel() {
  return defaultTargetPlatform == TargetPlatform.macOS
      ? 'Cmd+Enter'
      : 'Ctrl+Enter';
}

const closeComposeShortcutActivator =
    SingleActivator(LogicalKeyboardKey.escape);

final class NewMessageIntent extends Intent {
  const NewMessageIntent();
}

final class SubmitMessageIntent extends Intent {
  const SubmitMessageIntent();
}

final class CloseComposeIntent extends Intent {
  const CloseComposeIntent();
}
