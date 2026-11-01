import 'dart:async';

import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants.dart';
import '../update_service.dart';
import 'environment.dart';

typedef AppPowVerifier = FutureOr<bool> Function({
  required List<int> modulus,
  required List<int> input,
  required int difficulty,
  required List<int> y,
  required List<int> pi,
});

typedef ExternalPowerCheck = Future<bool> Function();
typedef AppVersionLoader = Future<AppVersion> Function();
typedef UpdateChecker = Future<UpdateCheckResult?> Function(
  AppVersion currentVersion,
);
typedef UrlOpener = Future<bool> Function(Uri url);

final class AppDependencies {
  const AppDependencies({
    this.workspacePath,
    this.verifyPow,
    this.powService = const VdfPowService(),
    this.runtimeOptions = const DdmCoreRuntimeOptions(),
    this.externalPowerCheck = externalPowerCheckWithBatteryPlus,
    this.noiseGeneratorInterval = defaultNoiseGeneratorInterval,
    this.noiseGeneratorTTL = defaultMessageTTL,
    this.noiseGeneratorMinPayloadBytes = defaultNoiseGeneratorMinPayloadBytes,
    this.noiseGeneratorMaxPayloadBytes = defaultNoiseGeneratorMaxPayloadBytes,
    this.appVersionLoader = loadCurrentAppVersion,
    this.updateChecker = checkForUpdate,
    this.urlOpener = launchUrl,
  });

  final String? workspacePath;
  final AppPowVerifier? verifyPow;
  final PowService powService;
  final DdmCoreRuntimeOptions runtimeOptions;
  final ExternalPowerCheck externalPowerCheck;
  final Duration noiseGeneratorInterval;
  final Duration noiseGeneratorTTL;
  final int noiseGeneratorMinPayloadBytes;
  final int noiseGeneratorMaxPayloadBytes;
  final AppVersionLoader appVersionLoader;
  final UpdateChecker updateChecker;
  final UrlOpener urlOpener;
}
