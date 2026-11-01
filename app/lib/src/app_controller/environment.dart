import 'dart:io';

import 'package:battery_plus/battery_plus.dart';

void appDebug(String message) {
  if (_isProductBuild) {
    return;
  }
  stderr.writeln('${DateTime.now().toIso8601String()} [ddm:app] $message');
}

bool _isChargingState(BatteryState state) {
  return state == BatteryState.charging || state == BatteryState.full;
}

Future<bool> externalPowerCheckWithBatteryPlus() async {
  return _isChargingState(await Battery().batteryState);
}

const bool _isProductBuild = bool.fromEnvironment('dart.vm.product');
