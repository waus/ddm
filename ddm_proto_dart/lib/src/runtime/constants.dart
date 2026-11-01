import 'package:ddm_proto_dart/src/storage/constants.dart';

const int ttlJitterDivisor = 10;
const Duration reliableDeliveryRetryStartupDelay = Duration(minutes: 1);
const Duration reliableDeliveryRetryInterval = Duration(minutes: 10);

const String mailboxInboxName = 'inbox';
const String mailboxOutboxName = 'outbox';

const String runtimeMessageStateReceived = messageStateReceived;
const String runtimeMessageStateCreated = messageStateCreated;
const String runtimeMessageStatePowSynced = messageStatePowSynced;
const String runtimeMessageStateDelivered = messageStateDelivered;

const Duration defaultRuntimeMessageTTL = Duration(hours: 48);
const Duration defaultNoiseGeneratorInterval = Duration(minutes: 20);
const int defaultNoiseGeneratorMinPayloadBytes = 1;
const int defaultNoiseGeneratorMaxPayloadBytes = 16 * 1024;
