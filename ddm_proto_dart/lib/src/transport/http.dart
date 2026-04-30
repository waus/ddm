import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ddm_proto_dart/src/proto/_bytes.dart';
import 'package:ddm_proto_dart/src/proto/config_record.dart';
import 'package:ddm_proto_dart/src/proto/constants.dart';
import 'package:ddm_proto_dart/src/proto/message_index_node.dart';
import 'package:ddm_proto_dart/src/proto/sync_source.dart';
import 'package:ddm_proto_dart/src/sync/constants.dart';
import 'package:ddm_proto_dart/src/sync/sync.dart';
import 'package:ddm_proto_dart/src/transport/constants.dart';
import 'package:ddm_proto_dart/src/transport/errors.dart';
import 'package:ddm_proto_dart/src/transport/server.dart';

final class HttpSyncSourceClient implements SyncSource {
  HttpSyncSourceClient(
    String upstream, {
    HttpClient? client,
  })  : baseUri = normalizeHttpSyncSourceUpstream(upstream),
        _client = client ?? _defaultHttpClient() {
    id = baseUri.toString();
  }

  final Uri baseUri;
  final HttpClient _client;

  @override
  late final String id;

  @override
  SyncSourceFlags get flags => const SyncSourceFlags(
        syncSourceFlagSupportTree | syncSourceFlagWritable,
      );

  @override
  Future<List<ConfigRecord>> getConfigs() async {
    try {
      final json = await _doJson('GET', 'configs');
      final configs = _requiredList(json, 'configs');
      return configs.map((item) {
        return parseConfigRecord(
          parseHexBytes(
            _requiredStringValue(item, 'config record'),
            expectedBytes:
                _requiredStringValue(item, 'config record').length ~/ 2,
            label: 'config record',
          ),
        );
      }).toList(growable: false);
    } on FormatException catch (error) {
      throw SyncSourceException.invalidResponse(error.message, details: error);
    }
  }

  @override
  Future<MessageIndexNode?> getMessageIndexRoot() async {
    try {
      final json = await _doJson('GET', 'root');
      final root = json['root'];
      if (root == null) {
        return null;
      }
      return messageIndexNodeFromHttp(_requiredMapValue(root, 'root'));
    } on FormatException catch (error) {
      throw SyncSourceException.invalidResponse(error.message, details: error);
    }
  }

  @override
  Future<MessageIndexNode?> getMessageIndexNode(MessageIndexNodeId id) async {
    try {
      final json = await _doJson('GET', 'node/${id.toHex()}');
      final node = json['node'];
      if (node == null) {
        return null;
      }
      final parsed = messageIndexNodeFromHttp(
        _requiredMapValue(node, 'node'),
      );
      if (parsed.hash() != id) {
        throw FormatException(
          'node hash mismatch, expected ${id.toHex()} got ${parsed.hash().toHex()}',
        );
      }
      return parsed;
    } on SyncSourceException catch (error) {
      if (error.kind == SyncSourceErrorKind.requestFailed &&
          error.statusCode == HttpStatus.notFound) {
        return null;
      }
      rethrow;
    } on FormatException catch (error) {
      throw SyncSourceException.invalidResponse(error.message, details: error);
    }
  }

  @override
  Future<List<SyncBlob?>> getSyncBlobs(List<SyncBlobId> ids) async {
    if (ids.isEmpty) {
      return const <SyncBlob?>[];
    }
    final query = <String, String>{
      'ids': ids.map((id) => id.toHex()).join(','),
    };
    try {
      final json = await _doJson('GET', 'lookup', query: query);
      final results = _requiredList(json, 'results');
      if (results.length != ids.length) {
        throw FormatException(
          'lookup results count mismatch: got ${results.length}, want ${ids.length}',
        );
      }

      final out = <SyncBlob?>[];
      for (var i = 0; i < ids.length; i++) {
        final result = _requiredMapValue(results[i], 'lookup result');
        final id = SyncBlobId.parseHex(_requiredString(result, 'id'));
        if (id != ids[i]) {
          throw FormatException('lookup result id mismatch at index $i');
        }
        final payload = result['payload'];
        if (payload == null) {
          out.add(null);
          continue;
        }
        if (payload is! String) {
          throw const FormatException('lookup payload must be string or null');
        }
        out.add(
          SyncBlob(
            id: id,
            payload: parseHexBytes(
              payload,
              expectedBytes: payload.length ~/ 2,
              label: 'lookup payload',
            ),
          ),
        );
      }
      return out;
    } on FormatException catch (error) {
      throw SyncSourceException.invalidResponse(error.message, details: error);
    }
  }

  @override
  Future<void> push(
    SyncBlob blob, {
    ImportValidationContext? validationContext,
  }) async {
    final body = jsonEncode(<String, Object?>{
      'id': blob.id.toHex(),
      'payload': bytesToHex(blob.payload),
    });
    final response = await _makeRequest(
      'POST',
      'push',
      body: utf8.encode(body),
      contentType: 'application/json; charset=utf-8',
    );
    if (response.statusCode != HttpStatus.ok) {
      throw await _readHttpError(response);
    } else {
      await response.drain<void>();
    }
  }

  @override
  Future<List<String>> discoverPeers() async => const <String>[];

  @override
  void stop() {
    _client.close(force: true);
  }

  Future<Map<String, Object?>> _doJson(
    String method,
    String path, {
    Map<String, String>? query,
  }) async {
    final response = await _makeRequest(method, path, query: query);
    if (response.statusCode != HttpStatus.ok) {
      throw await _readHttpError(response);
    }
    try {
      final data = await readLimited(response, syncSourceClientMaxBodyBytes);
      final decoded = jsonDecode(utf8.decode(data));
      return _requiredMapValue(decoded, 'response body');
    } on FormatException catch (error) {
      throw SyncSourceException.invalidResponse(
        'decode response body: ${error.message}',
        details: error,
      );
    }
  }

  Future<HttpClientResponse> _makeRequest(
    String method,
    String path, {
    Map<String, String>? query,
    List<int>? body,
    String? contentType,
  }) async {
    final target = baseUri.resolve(path).replace(queryParameters: query);
    try {
      final request = await _client.openUrl(method, target);
      request.followRedirects = false;
      request.headers
          .set(HttpHeaders.acceptHeader, 'application/json; charset=utf-8');
      if (contentType != null) {
        request.headers.set(HttpHeaders.contentTypeHeader, contentType);
      }
      if (body != null) {
        request.add(body);
      }
      return request.close();
    } on SocketException catch (error) {
      throw SyncSourceException.unavailable(error.toString());
    } on HttpException catch (error) {
      throw SyncSourceException.unavailable(error.toString());
    } on TlsException catch (error) {
      throw SyncSourceException.unavailable(error.toString());
    }
  }

  Future<SyncSourceException> _readHttpError(
      HttpClientResponse response) async {
    if (response.statusCode == HttpStatus.serviceUnavailable) {
      return const SyncSourceException.unavailable();
    }
    final data = await readLimited(response, syncSourceClientMaxErrorBodyBytes);
    final body = utf8.decode(data).trim();
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, Object?>) {
        final error = decoded['error'];
        if (error is String && error.isNotEmpty) {
          return SyncSourceException.requestFailed(
            error,
            statusCode: response.statusCode,
          );
        }
      }
    } on FormatException {
      // Fall through to the raw response body.
    }
    return SyncSourceException.requestFailed(
      body.isEmpty ? response.reasonPhrase : body,
      statusCode: response.statusCode,
    );
  }
}

final class HttpSyncSourceServer implements SyncTransportServer {
  HttpSyncSourceServer({required String listenAddress})
      : _listenAddress = listenAddress.trim();

  final String _listenAddress;
  HttpServer? _server;
  SyncSource? _source;

  Uri? get boundUri {
    final server = _server;
    if (server == null) {
      return null;
    }
    return Uri(
      scheme: 'http',
      host: server.address.host,
      port: server.port,
      path: '/',
    );
  }

  @override
  String get protocolName => httpTransportProtocolName;

  @override
  ServerFlags get flags => const ServerFlags(serverFlagNone);

  @override
  Future<void> start(SyncSource source) async {
    if (_listenAddress.isEmpty) {
      throw const FormatException('http listen address must not be empty');
    }
    final separator = _listenAddress.lastIndexOf(':');
    if (separator <= 0 || separator == _listenAddress.length - 1) {
      throw FormatException('invalid http listen address "$_listenAddress"');
    }
    final host = _listenAddress.substring(0, separator);
    final port = int.parse(_listenAddress.substring(separator + 1));
    _source = source;
    final server = await HttpServer.bind(host, port);
    server.idleTimeout = syncSourceHTTPIdleTimeout;
    _server = server;
    unawaited(_serve(server));
  }

  @override
  Future<void> stop() async {
    final server = _server;
    _server = null;
    _source = null;
    if (server != null) {
      await server.close(force: true);
    }
  }

  @override
  bool peerMatch(String id) => isHttpPeerId(id);

  @override
  Future<SyncSource> createPeerSource(String id) async {
    return HttpSyncSourceClient(id);
  }

  @override
  Future<List<String>> discoverPeers() async => const <String>[];

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      await handleRequest(request);
    }
  }

  Future<void> handleRequest(HttpRequest request) async {
    final source = _source;
    if (source == null) {
      await _writeJson(
          request.response, HttpStatus.serviceUnavailable, <String, Object?>{
        'error': const SyncSourceException.unavailable().toString(),
      });
      return;
    }
    final path = request.uri.path;
    try {
      if (path == '/configs') {
        await _handleConfigs(request, source);
      } else if (path == '/lookup') {
        await _handleLookup(request, source);
      } else if (path == '/push') {
        await _handlePush(request, source);
      } else if (path == '/root') {
        await _handleRoot(request, source);
      } else if (path.startsWith('/node/')) {
        await _handleNode(request, source);
      } else if (path == '/metrics') {
        await _writeText(request.response, HttpStatus.ok,
            '# HELP ddm_sync_source_info DDM sync source\n');
      } else {
        await _writeJson(
            request.response, HttpStatus.notFound, <String, Object?>{
          'error': 'not found',
        });
      }
    } on SyncSourceException catch (error) {
      if (error.kind == SyncSourceErrorKind.unavailable) {
        await _writeJson(
            request.response, HttpStatus.serviceUnavailable, <String, Object?>{
          'error': error.toString(),
        });
        return;
      }
      await _writeJson(
          request.response, HttpStatus.internalServerError, <String, Object?>{
        'error': error.toString(),
      });
    } on FormatException catch (error) {
      await _writeJson(
          request.response, HttpStatus.badRequest, <String, Object?>{
        'error': error.message,
      });
    } catch (_) {
      await _writeJson(
          request.response, HttpStatus.internalServerError, <String, Object?>{
        'error': 'internal server error',
      });
    }
  }

  Future<void> _handleConfigs(HttpRequest request, SyncSource source) async {
    if (!await _requireMethod(request, 'GET')) {
      return;
    }
    final configs = await source.getConfigs();
    await _writeJson(request.response, HttpStatus.ok, <String, Object?>{
      'configs': configs
          .map(
            (config) => bytesToHex(config.toBytes()),
          )
          .toList(growable: false),
    });
  }

  Future<void> _handleLookup(HttpRequest request, SyncSource source) async {
    if (!await _requireMethod(request, 'GET')) {
      return;
    }
    final rawIds = _parseLookupIds(request.uri.queryParameters['ids'] ?? '');
    if (rawIds.length > maxSyncBlobLookupRequestIds) {
      await _writeJson(
          request.response, HttpStatus.badRequest, <String, Object?>{
        'error': 'too many ids, max $maxSyncBlobLookupRequestIds',
      });
      return;
    }
    final ids = rawIds.map(SyncBlobId.parseHex).toList(growable: false);
    final results = await source.getSyncBlobs(ids);
    if (results.length != ids.length) {
      await _writeText(
        request.response,
        HttpStatus.badGateway,
        'lookup response size does not match request size',
      );
      return;
    }

    var responseSize = 0;
    final items = <Map<String, Object?>>[];
    for (var i = 0; i < ids.length; i++) {
      final id = ids[i];
      final result = results[i];
      String? payload;
      if (result != null) {
        if (result.id != id) {
          await _writeText(
            request.response,
            HttpStatus.badGateway,
            'lookup response item id does not match request id',
          );
          return;
        }
        if (result.payload.length > maxSyncBlobLookupPayloadBytes) {
          await _writeText(
            request.response,
            HttpStatus.requestEntityTooLarge,
            'lookup payload exceeds maximum supported size',
          );
          return;
        }
        payload = bytesToHex(result.payload);
        responseSize += id.toHex().length + payload.length;
        if (responseSize > maxSyncBlobLookupResponseBytes) {
          await _writeText(
            request.response,
            HttpStatus.requestEntityTooLarge,
            'lookup response exceeds maximum supported size',
          );
          return;
        }
      }
      items.add(<String, Object?>{'id': id.toHex(), 'payload': payload});
    }
    await _writeJson(request.response, HttpStatus.ok, <String, Object?>{
      'results': items,
    });
  }

  Future<void> _handlePush(HttpRequest request, SyncSource source) async {
    if (!await _requireMethod(request, 'POST')) {
      return;
    }
    final data = await _readRequestBody(request, maxSyncBlobPushRequestBytes);
    Map<String, Object?> decoded;
    try {
      decoded =
          _requiredMapValue(jsonDecode(utf8.decode(data)), 'push request');
    } on FormatException {
      await _writeJson(
          request.response, HttpStatus.badRequest, <String, Object?>{
        'error': 'invalid push payload',
      });
      return;
    }
    final id = SyncBlobId.parseHex(_requiredString(decoded, 'id'));
    final rawPayload = _requiredString(decoded, 'payload');
    final payload = parseHexBytes(
      rawPayload,
      expectedBytes: rawPayload.length ~/ 2,
      label: 'push payload',
    );
    await source.push(SyncBlob(id: id, payload: payload));
    await _writeJson(request.response, HttpStatus.ok, <String, Object?>{});
  }

  Future<void> _handleRoot(HttpRequest request, SyncSource source) async {
    if (!await _requireMethod(request, 'GET')) {
      return;
    }
    final root = await source.getMessageIndexRoot();
    await _writeJson(request.response, HttpStatus.ok, <String, Object?>{
      'root': root == null ? null : messageIndexNodeToHttp(root),
    });
  }

  Future<void> _handleNode(HttpRequest request, SyncSource source) async {
    if (!await _requireMethod(request, 'GET')) {
      return;
    }
    final rawId = request.uri.path.substring('/node/'.length);
    if (rawId.isEmpty || rawId.contains('/')) {
      await _writeJson(request.response, HttpStatus.notFound, <String, Object?>{
        'error': 'message index node not found',
      });
      return;
    }
    final id = MessageIndexNodeId.parseHex(rawId);
    final node = await source.getMessageIndexNode(id);
    if (node == null) {
      await _writeJson(request.response, HttpStatus.notFound, <String, Object?>{
        'error': 'message index node not found',
      });
      return;
    }
    await _writeJson(request.response, HttpStatus.ok, <String, Object?>{
      'node': messageIndexNodeToHttp(node),
    });
  }

  Future<bool> _requireMethod(HttpRequest request, String method) async {
    if (request.method == method) {
      return true;
    }
    request.response.headers.set(HttpHeaders.allowHeader, method);
    await _writeJson(
        request.response, HttpStatus.methodNotAllowed, <String, Object?>{
      'error': 'method must be $method',
    });
    return false;
  }
}

Uri normalizeHttpSyncSourceUpstream(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('sync source upstream URL must not be empty');
  }
  final parsed = Uri.parse(trimmed);
  if (parsed.scheme.isEmpty) {
    throw const FormatException('sync source upstream URL must include scheme');
  }
  if (parsed.scheme != 'http' && parsed.scheme != 'https') {
    throw const FormatException(
      'sync source upstream URL scheme must be http or https',
    );
  }
  if (parsed.host.isEmpty) {
    throw const FormatException('sync source upstream URL must include host');
  }
  if (parsed.userInfo.isNotEmpty) {
    throw const FormatException(
      'sync source upstream URL must not include user credentials',
    );
  }
  var path = parsed.path.replaceFirst(RegExp(r'/+$'), '');
  path = path.isEmpty ? '/' : '$path/';
  return Uri(
    scheme: parsed.scheme,
    host: parsed.host,
    port: parsed.hasPort ? parsed.port : null,
    path: path,
  );
}

MessageIndexNode messageIndexNodeFromHttp(Map<String, Object?> response) {
  final hash = MessageIndexNodeId.parseHex(_requiredString(response, 'hash'));
  final leaf = response['leaf'];
  final branch = response['branch'];
  if (leaf != null && branch != null) {
    throw const FormatException('message index node has both leaf and branch');
  }
  late final MessageIndexNode node;
  if (leaf != null) {
    final leafMap = _requiredMapValue(leaf, 'leaf');
    node = MessageIndexNode.leaf(
      MessageIndexLeaf(
        syncBlobId: SyncBlobId.parseHex(
          _requiredString(leafMap, 'sync_blob_id'),
        ),
        ttl: _requireUint32(_requiredInt(leafMap, 'ttl'), 'ttl'),
      ),
    );
  } else if (branch != null) {
    final branchMap = _requiredMapValue(branch, 'branch');
    final childrenRaw = _requiredList(branchMap, 'children_ids');
    if (childrenRaw.length != messageIndexChildSlotCount) {
      throw FormatException(
        'message index branch has ${childrenRaw.length} children, want $messageIndexChildSlotCount',
      );
    }
    final children = <MessageIndexNodeId?>[];
    for (final rawChild in childrenRaw) {
      if (rawChild == null) {
        children.add(null);
      } else if (rawChild is String) {
        children.add(MessageIndexNodeId.parseHex(rawChild));
      } else {
        throw const FormatException(
            'message index branch child id must be string or null');
      }
    }
    node = MessageIndexNode.branch(
      MessageIndexBranch(
        prefix: _requiredString(branchMap, 'prefix'),
        childrenCount: _requireUint32(
          _requiredInt(branchMap, 'children_count'),
          'children_count',
        ),
        minTtl: _requireUint32(_requiredInt(branchMap, 'min_ttl'), 'min_ttl'),
        maxTtl: _requireUint32(_requiredInt(branchMap, 'max_ttl'), 'max_ttl'),
        childrenIds: children,
      ),
    );
  } else {
    throw const FormatException('message index node has no variant');
  }
  node.validate();
  final actualHash = node.hash();
  if (actualHash != hash) {
    throw FormatException(
      'message index node hash mismatch, expected ${hash.toHex()} got ${actualHash.toHex()}',
    );
  }
  return node;
}

Map<String, Object?> messageIndexNodeToHttp(MessageIndexNode node) {
  node.validate();
  final out = <String, Object?>{'hash': node.hash().toHex()};
  final leaf = node.leaf;
  if (leaf != null) {
    out['leaf'] = <String, Object?>{
      'sync_blob_id': leaf.syncBlobId.toHex(),
      'ttl': leaf.ttl,
    };
    return out;
  }
  final branch = node.branch;
  if (branch == null) {
    throw const FormatException(
        'message index node must contain exactly one variant');
  }
  out['branch'] = <String, Object?>{
    'prefix': branch.prefix,
    'children_count': branch.childrenCount,
    'min_ttl': branch.minTtl,
    'max_ttl': branch.maxTtl,
    'children_ids': branch.childrenIds
        .map((child) => child?.toHex())
        .toList(growable: false),
  };
  return out;
}

SyncTransportServer newHttpProtocolServer() {
  return ProtocolSyncTransportServer(
    protocolName: httpTransportProtocolName,
    peerMatch: isHttpPeerId,
    createPeerSource: (id) => HttpSyncSourceClient(id),
  );
}

HttpClient _defaultHttpClient() {
  final client = HttpClient();
  client.connectionTimeout = syncSourceClientTimeout;
  return client;
}

List<String> _parseLookupIds(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return const <String>[];
  }
  return trimmed
      .split(',')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
}

Future<List<int>> _readRequestBody(HttpRequest request, int maxBytes) async {
  final out = <int>[];
  await for (final chunk in request) {
    out.addAll(chunk);
    if (out.length > maxBytes) {
      throw const FormatException('request body exceeds limit');
    }
  }
  return out;
}

Future<void> _writeJson(
  HttpResponse response,
  int statusCode,
  Map<String, Object?> body,
) async {
  response.statusCode = statusCode;
  response.headers.contentType =
      ContentType('application', 'json', charset: 'utf-8');
  response.write(jsonEncode(body));
  await response.close();
}

Future<void> _writeText(
  HttpResponse response,
  int statusCode,
  String body,
) async {
  response.statusCode = statusCode;
  response.headers.contentType = ContentType.text;
  response.write(body);
  await response.close();
}

Map<String, Object?> _requiredMapValue(Object? value, String label) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  throw FormatException('$label must be object');
}

List<Object?> _requiredList(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is List<Object?>) {
    return value;
  }
  if (value is List) {
    return value.cast<Object?>();
  }
  throw FormatException('$key must be array');
}

String _requiredString(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! String) {
    throw FormatException('$key must be string');
  }
  return value;
}

String _requiredStringValue(Object? value, String label) {
  if (value is! String) {
    throw FormatException('$label must be string');
  }
  return value;
}

int _requiredInt(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! int) {
    throw FormatException('$key must be integer');
  }
  return value;
}

int _requireUint32(int value, String label) {
  if (value < 0 || value > 0xffffffff) {
    throw FormatException('$label must fit uint32, got $value');
  }
  return value;
}
