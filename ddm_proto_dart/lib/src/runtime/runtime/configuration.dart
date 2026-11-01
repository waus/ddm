part of '../runtime.dart';

final class ConfigService {
  ConfigService({required ConfigManager configs}) : _configs = configs;

  final ConfigManager _configs;

  ConfigV1Core loadActiveConfigCore(DateTime now) {
    return _configs.configAtUnix(unixSecondsUint32(now));
  }
}
