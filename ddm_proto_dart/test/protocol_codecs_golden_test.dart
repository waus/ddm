import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:ddm_proto_dart/src/proto/_bytes.dart';
import 'package:test/test.dart';

void main() {
  final fixturesRoot = Directory('test/fixtures/go_v1');

  test('address fixture parity and stream id', () {
    final bytes = _readBinary(fixturesRoot, 'address.cbor');
    final address = Address.fromBytes(bytes);

    expect(address.toBytes(), bytes);
    expect(
      address.toText(),
      'waaxtnkwf2h6mvhzib4lcexivgf2pea7qu5onfn627qoheilvucjmzaj',
    );
    expect(address.streamId().toHex(), 'ec17bfd2');
  });

  test('config payload fixture parity and signature verification', () async {
    final fixture = _readJson(fixturesRoot, 'config_record.json');
    final payloadHex = fixture['payload_hex'] as String;
    final payload = parseHexBytes(
      payloadHex,
      expectedBytes: payloadHex.length ~/ 2,
      label: 'config payload',
    );
    final adminPublic = parseHexBytes(
      fixture['admin_public_key_hex'] as String,
      expectedBytes: 32,
      label: 'admin pubkey',
    );

    final parsed = ConfigV1Payload.fromBytes(payload);

    expect(parsed.toBytes(), payload);
    expect(parsed.core.seqNo, fixture['seq_no']);
    expect(parsed.core.activeFromUnix, fixture['active_from_unix']);
    expect(parsed.core.powBaseTarget, fixture['pow_base_target']);
    expect(parsed.core.powScaleDivisor, fixture['pow_scale_divisor']);
    expect(bytesToHex(parsed.core.powModulus), fixture['pow_modulus_hex']);

    await parsed.verifySignature(adminPublic);
  });

  test('unencrypted plaintext message fixture parity and signature', () async {
    final bytes = _readBinary(fixturesRoot, 'plaintext_message.cbor');
    final message = UnencryptedMessage.fromBytes(bytes);

    await message.validate();
    expect(message.toBytes(), bytes);
    expect(message.magic, unencryptedMessageMagic);
    expect(message.version, unencryptedMessageVersionV1);
    expect(message.messageType, MessageType.plain);
    expect(utf8.decode(message.message), isNotEmpty);
    expect(
      message.sender.toText(),
      'waaxtnkwf2h6mvhzib4lcexivgf2pea7qu5onfn627qoheilvucjmzaj',
    );
  });

  test('encrypted and pow envelope fixture parity', () {
    final encryptedBytes = _readBinary(fixturesRoot, 'encrypted_message.cbor');
    final encrypted = EncryptedMessage.fromBytes(encryptedBytes);
    expect(encrypted.toBytes(), encryptedBytes);

    final powBytes = _readBinary(fixturesRoot, 'pow_envelope.cbor');
    final envelope = PowEnvelope.fromBytes(powBytes);
    expect(envelope.toBytes(), powBytes);
    expect(envelope.version, powEnvelopeVersionV1);
    expect(envelope.algorithm, PowAlgorithm.vdfRsa);
    expect(envelope.object, encryptedBytes);
  });

  test('sync blob fixture parity and id derivation', () {
    final fixture = _readJson(fixturesRoot, 'sync_blob.json');
    final payloadHex = fixture['payload_hex'] as String;
    final payload = parseHexBytes(
      payloadHex,
      expectedBytes: payloadHex.length ~/ 2,
      label: 'sync blob payload',
    );
    final expectedId = fixture['id_hex'] as String;

    final envelope = PowEnvelope.fromBytes(payload);
    final encrypted = EncryptedMessage.fromBytes(envelope.object);
    final id = deriveSyncBlobId(
      streamId: encrypted.streamNumber,
      blobPayload: payload,
    );

    expect(bytesToHex(payload), fixture['payload_hex']);
    expect(id.toHex(), expectedId);
    expect(encrypted.streamNumber.toHex(), fixture['stream_id_hex']);
    expect(encrypted.ttl, fixture['ttl_seconds']);
    expect(encrypted.expiresTime, fixture['expires_time_unix']);
  });

  test('message-index fixtures parity and hash ids', () {
    final ids = _readJson(fixturesRoot, 'message_index_ids.json');

    final leafBytes = _readBinary(fixturesRoot, 'message_index_leaf.cbor');
    final leaf = MessageIndexNode.fromBytes(leafBytes);
    expect(leaf.toBytes(), leafBytes);
    expect(leaf.hash().toHex(), ids['leaf_id_hex']);

    final branchBytes = _readBinary(fixturesRoot, 'message_index_branch.cbor');
    final branch = MessageIndexNode.fromBytes(branchBytes);
    expect(branch.toBytes(), branchBytes);
    expect(branch.hash().toHex(), ids['branch_id_hex']);
  });

  test('p2p rpc frame fixtures parity', () {
    for (final file in const <String>[
      'p2p_get_node_request.frame',
      'p2p_get_sync_blobs_request.frame',
      'p2p_get_node_response.frame',
      'p2p_get_sync_blobs_response.frame',
    ]) {
      final frame = _readBinary(fixturesRoot, file);
      final payload = decodeRpcFrame(frame, maxBytes: 10 * 1024 * 1024);
      final encoded = encodeRpcFrame(payload, maxBytes: 10 * 1024 * 1024);

      expect(encoded, frame, reason: file);

      if (file.contains('request')) {
        final request = RpcRequest.fromBytes(payload);
        expect(request.toBytes(), payload, reason: '$file payload roundtrip');
      } else {
        final response = RpcResponse.fromBytes(payload);
        expect(response.toBytes(), payload, reason: '$file payload roundtrip');
      }
    }
  });

  test('p2p rpc push request supports current five-field wire shape', () {
    final blobId = Uint8List.fromList(List<int>.generate(36, (i) => i));
    final blob = Uint8List.fromList(<int>[1, 2, 3, 4]);
    final request = RpcRequest(
      method: rpcMethodPushBlob,
      syncBlobIds: null,
      nodeId: null,
      blobId: blobId,
      blob: blob,
    );

    final parsed = RpcRequest.fromBytes(request.toBytes());
    expect(parsed.method, rpcMethodPushBlob);
    expect(parsed.blobId, blobId);
    expect(parsed.blob, blob);
  });
}

Map<String, Object?> _readJson(Directory root, String name) {
  final file = File('${root.path}/$name');
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

Uint8List _readBinary(Directory root, String name) {
  final file = File('${root.path}/$name');
  return file.readAsBytesSync();
}
