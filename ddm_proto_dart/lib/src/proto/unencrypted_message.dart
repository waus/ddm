import 'dart:typed_data';

import 'package:ddm_proto_dart/src/proto/_bytes.dart';
import 'package:ddm_proto_dart/src/proto/address.dart';
import 'package:ddm_proto_dart/src/proto/constants.dart';
import 'package:ddm_proto_dart/src/proto/cose_sign1.dart';
import 'package:ddm_proto_dart/src/proto/ddm_cbor_codec.dart';
import 'package:ddm_proto_dart/src/proto/message_types.dart';

final class UnencryptedMessage {
  UnencryptedMessage({
    required this.magic,
    required this.version,
    required Uint8List messageId,
    required this.sender,
    required this.messageType,
    required Uint8List message,
    required Uint8List signedBody,
    Uint8List? ackData,
  })  : messageId = _fixed(messageId, 16, 'message id'),
        message = copyBytes(message),
        signedBody = copyBytes(signedBody),
        ackData = copyBytes(ackData ?? Uint8List(0));

  final int magic;
  final int version;
  final Uint8List messageId;
  final Address sender;
  final MessageType messageType;
  final Uint8List message;
  final Uint8List signedBody;
  final Uint8List ackData;

  void validateShape() {
    if (magic != unencryptedMessageMagic) {
      throw FormatException(
        'unsupported unencrypted message magic: 0x${magic.toRadixString(16)}',
      );
    }
    if (version != unencryptedMessageVersionV1) {
      throw FormatException(
        'unsupported unencrypted message version: $version',
      );
    }
    if (signedBody.isEmpty) {
      throw const FormatException('message signature must not be empty');
    }
  }

  Uint8List toSignedBodyBytes() {
    return ddmCborCodec.encode(<Object?>[
      copyBytes(messageId),
      <Object?>[sender.version, sender.policy, copyBytes(sender.pubkey)],
      messageType.code,
      copyBytes(message),
      ackData.isEmpty ? null : copyBytes(ackData),
    ]);
  }

  Future<void> verifySignature() async {
    await verifyCosePayload(
      signed: signedBody,
      publicKey: sender.pubkey,
      expectedPayload: toSignedBodyBytes(),
    );
  }

  Future<void> validate() async {
    validateShape();
    try {
      await verifySignature();
    } on FormatException catch (e) {
      throw FormatException(
        'verify unencrypted message signature: ${e.message}',
      );
    }
  }

  Uint8List toBytes() {
    validateShape();
    return ddmCborCodec.encode(<Object?>[
      magic,
      version,
      copyBytes(signedBody),
    ]);
  }

  static Future<UnencryptedMessage> signed({
    required Uint8List privateKey,
    required Uint8List messageId,
    required Address sender,
    required MessageType messageType,
    required Uint8List message,
    Uint8List? ackData,
  }) async {
    final temp = UnencryptedMessage(
      magic: unencryptedMessageMagic,
      version: unencryptedMessageVersionV1,
      messageId: messageId,
      sender: sender,
      messageType: messageType,
      message: message,
      signedBody: Uint8List(0),
      ackData: ackData,
    );
    final signedBody = await signCosePayload(
      payload: temp.toSignedBodyBytes(),
      privateKey: privateKey,
    );

    return UnencryptedMessage(
      magic: temp.magic,
      version: temp.version,
      messageId: temp.messageId,
      sender: temp.sender,
      messageType: temp.messageType,
      message: temp.message,
      signedBody: signedBody,
      ackData: temp.ackData,
    );
  }

  static UnencryptedMessage fromBytes(Uint8List data) {
    if (data.length > maxSignedMessageBytes) {
      throw FormatException(
        'unencrypted message envelope exceeds limit: got ${data.length} bytes, max $maxSignedMessageBytes',
      );
    }

    final decoded = ddmCborCodec.decode(data);
    if (decoded is! List<Object?> || decoded.length != 3) {
      throw const FormatException('decode unencrypted message envelope');
    }

    final magic = decoded[0];
    final version = decoded[1];
    final signedBody = decoded[2];
    if (magic is! int || version is! int || signedBody is! Uint8List) {
      throw const FormatException('decode unencrypted message envelope');
    }
    if (signedBody.length > maxSignedMessageBytes) {
      throw FormatException(
        'unencrypted message signature exceeds limit: got ${signedBody.length} bytes, max $maxSignedMessageBytes',
      );
    }

    final payload = decodeCosePayload(signedBody);
    final signed = _parseSignedBody(payload);

    return UnencryptedMessage(
      magic: magic,
      version: version,
      messageId: signed.messageId,
      sender: signed.sender,
      messageType: signed.messageType,
      message: signed.message,
      signedBody: signedBody,
      ackData: signed.ackData,
    );
  }

  static _SignedBody _parseSignedBody(Uint8List payload) {
    final decoded = ddmCborCodec.decode(payload);
    if (decoded is! List<Object?> || decoded.length != 5) {
      throw const FormatException('decode unencrypted signed body');
    }
    final messageId = decoded[0];
    final sender = decoded[1];
    final messageType = decoded[2];
    final message = decoded[3];
    final ackData = decoded[4];

    if (messageId is! Uint8List ||
        messageType is! int ||
        message is! Uint8List ||
        (ackData != null && ackData is! Uint8List)) {
      throw const FormatException('decode unencrypted signed body');
    }
    final senderBytes = ddmCborCodec.encode(sender);

    return _SignedBody(
      messageId: _fixed(messageId, 16, 'message id'),
      sender: Address.fromBytes(senderBytes),
      messageType: MessageType.fromCode(messageType),
      message: message,
      ackData: ackData as Uint8List? ?? Uint8List(0),
    );
  }
}

final class _SignedBody {
  _SignedBody({
    required this.messageId,
    required this.sender,
    required this.messageType,
    required this.message,
    required this.ackData,
  });

  final Uint8List messageId;
  final Address sender;
  final MessageType messageType;
  final Uint8List message;
  final Uint8List ackData;
}

Uint8List _fixed(Uint8List value, int expected, String label) {
  if (value.length != expected) {
    throw FormatException(
      '$label must be $expected bytes, got ${value.length}',
    );
  }
  return copyBytes(value);
}
