import 'package:ddm_proto_dart/src/storage/constants.dart';

const int ttlJitterDivisor = 10;
const int expiresJitterDivisor = 20;

const String mailboxInboxName = 'inbox';
const String mailboxOutboxName = 'outbox';

const String runtimeMessageStateReceived = messageStateReceived;
const String runtimeMessageStateCreated = messageStateCreated;
const String runtimeMessageStatePowSynced = messageStatePowSynced;
const String runtimeMessageStateDelivered = messageStateDelivered;
