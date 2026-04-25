import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('ddm/file_picker');

Future<String?> pickMacOSSyncFile(String initialFileUrl) async {
  if (!Platform.isMacOS) {
    return null;
  }
  return _channel.invokeMethod<String>(
    'pickExternalStorageSyncFile',
    <String, Object?>{'initialUrl': initialFileUrl},
  );
}
