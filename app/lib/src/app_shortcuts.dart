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

const closeComposeShortcutActivator =
    SingleActivator(LogicalKeyboardKey.escape);
