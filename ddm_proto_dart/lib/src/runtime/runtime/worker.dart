part of '../runtime.dart';

enum RuntimeOperation { sync, discovery, reliableDelivery, outbox, noise }

enum RuntimePhase { started, progress, completed, failed }

final class RuntimeEvent {
  const RuntimeEvent(
    this.operation,
    this.phase, {
    this.completion = 0,
    this.publishedCount = 0,
    this.externalStorageFiles = const [],
    this.error,
  });

  final RuntimeOperation operation;
  final RuntimePhase phase;
  final double completion;
  final int publishedCount;
  final List<Uri> externalStorageFiles;
  final Object? error;
}

final class RuntimeWorker {
  RuntimeWorker({
    required DdmCore core,
    required PowService pow,
    required Future<bool> Function() canGenerateNoise,
    required void Function(RuntimeEvent event) onEvent,
    required void Function(String message) log,
    UtcNow nowUtc = defaultRuntimeUtcNow,
    this.noiseInterval = defaultNoiseGeneratorInterval,
    this.noiseTTL = defaultRuntimeMessageTTL,
    this.noiseMinPayloadBytes = defaultNoiseGeneratorMinPayloadBytes,
    this.noiseMaxPayloadBytes = defaultNoiseGeneratorMaxPayloadBytes,
  })  : _core = core,
        _nowUtc = nowUtc,
        _pow = pow,
        _canGenerateNoise = canGenerateNoise,
        _onEvent = onEvent,
        _log = log;

  final DdmCore _core;
  final UtcNow _nowUtc;
  final PowService _pow;
  final Future<bool> Function() _canGenerateNoise;
  final void Function(RuntimeEvent event) _onEvent;
  final void Function(String message) _log;
  final Duration noiseInterval;
  final Duration noiseTTL;
  final int noiseMinPayloadBytes;
  final int noiseMaxPayloadBytes;
  final List<Timer> _timers = [];
  bool _started = false;
  bool _closed = false;
  bool _syncRunning = false;
  bool _deliveryRunning = false;
  bool _discoveryRunning = false;
  bool _peerExchangeRunning = false;
  bool _publicationRunning = false;
  bool _outboxRequested = false;

  void start() {
    if (_started || _closed) return;
    _started = true;
    unawaited(publishPending());
    _timers.add(Timer(reliableDeliveryRetryStartupDelay, () {
      unawaited(_retryReliableDelivery());
      _periodic(reliableDeliveryRetryInterval, _retryReliableDelivery);
    }));
    _periodic(noiseInterval, _generateNoise);
    if (_core.runtimeOptions.transports.backgroundSyncEnabled) {
      unawaited(_startSync());
    }
  }

  void close() {
    _closed = true;
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
  }

  void _periodic(Duration interval, Future<void> Function() run) {
    if (_closed) return;
    _timers.add(Timer.periodic(interval, (_) => unawaited(run())));
  }

  void _emit(RuntimeEvent event) {
    if (!_closed) _onEvent(event);
  }

  Future<void> _startSync() async {
    try {
      await _core.sync.refreshCoverage();
      if (_closed) return;
      await _core.transports.restoreRegisteredSources();
      if (_closed) return;
      unawaited(_discover());
      unawaited(_exchangePeers());
      unawaited(_sync());
      final options = _core.runtimeOptions.transports;
      _periodic(options.backgroundSyncInterval, _sync);
      unawaited(_deliverOutgoing());
      _periodic(outgoingRetryInterval, _deliverOutgoing);
      _periodic(options.discoveryInterval, _discover);
      _periodic(options.peerExchangeInterval, _exchangePeers);
    } catch (error) {
      _log('background sync startup failed error=$error');
      _emit(RuntimeEvent(RuntimeOperation.sync, RuntimePhase.failed,
          error: error));
    }
  }

  Future<void> _deliverOutgoing() async {
    if (_closed || _deliveryRunning) return;
    _deliveryRunning = true;
    try {
      await OutgoingDelivery(
              queue: _core._storage.syncBlobs,
              blobs: _core._storage.syncBlobs,
              discovery: _core.transports,
              nowUtc: _nowUtc)
          .run(isCancelled: () => _closed);
    } catch (error) {
      if (!_closed) _log('outgoing shard delivery failed error=$error');
    } finally {
      _deliveryRunning = false;
    }
  }

  Future<void> _sync() async {
    if (_closed || _syncRunning) return;
    _syncRunning = true;
    try {
      await _core.sync.refreshCoverage();
      for (final source in _core.transports.sources.getActive(10)) {
        if (!source.flags.has(syncSourceFlagSupportTree)) continue;
        try {
          await _core.sync.importFrom(
            source: source,
          );
        } catch (error) {
          if (!isSyncSourceUnavailableError(error)) {
            source.decreaseRatingMul(ratingReceivedSomethingStrange);
          }
          _log(
              'background sync source failed source=${source.id} error=$error');
        }
      }
      _core.transports.sources.saveUpdatedPeers();
      _emit(const RuntimeEvent(RuntimeOperation.sync, RuntimePhase.completed));
    } catch (error) {
      _log('background sync failed error=$error');
      _emit(RuntimeEvent(RuntimeOperation.sync, RuntimePhase.failed,
          error: error));
    } finally {
      _syncRunning = false;
    }
  }

  Future<void> _discover() async {
    if (_closed || _discoveryRunning) return;
    _discoveryRunning = true;
    try {
      final peers = await _core.transports.discoverPeers();
      final registered = _core.transports.sourceIds().toSet();
      final files = <Uri>[];
      for (final peer in peers) {
        final uri = Uri.tryParse(peer);
        if (Platform.isMacOS &&
            uri != null &&
            uri.scheme == 'file' &&
            uri.path.startsWith('/Volumes/')) {
          if (!registered.contains(peer)) files.add(uri);
          continue;
        }
        await _addDiscoveredSource(peer);
      }
      _emit(RuntimeEvent(RuntimeOperation.discovery, RuntimePhase.completed,
          externalStorageFiles: files));
    } catch (error) {
      _log('background discovery failed error=$error');
    } finally {
      _discoveryRunning = false;
    }
  }

  Future<void> _exchangePeers() async {
    if (_closed || _peerExchangeRunning) return;
    _peerExchangeRunning = true;
    try {
      for (final source in _core.transports.sources.peerExchangeSources()) {
        try {
          for (final peer in await source.discoverPeers()) {
            await _addDiscoveredSource(peer);
          }
        } catch (error) {
          _log('peer exchange failed source=${source.id} error=$error');
        }
      }
    } finally {
      _peerExchangeRunning = false;
    }
  }

  Future<void> _addDiscoveredSource(String peer) async {
    try {
      await _core.transports.addSource(peer);
    } catch (error) {
      _log('discovered source skipped source=$peer error=$error');
    }
  }

  Future<void> publishPending() async {
    if (_closed) return;
    if (_publicationRunning) {
      _outboxRequested = true;
      return;
    }
    if (_core.outbox.listPendingMessages().isEmpty) return;
    _publicationRunning = true;
    _outboxRequested = false;
    const operation = RuntimeOperation.outbox;
    _emit(const RuntimeEvent(operation, RuntimePhase.started));
    try {
      final published = await _core.outbox.publishPendingMessages(
        pow: _pow,
        onPowProgress: (progress) => _emit(RuntimeEvent(
            operation, RuntimePhase.progress,
            completion: progress.completion)),
      );
      _emit(RuntimeEvent(operation, RuntimePhase.completed,
          publishedCount: published.length));
    } catch (error) {
      _log('outbox publish failed error=$error');
      _emit(RuntimeEvent(operation, RuntimePhase.failed, error: error));
    } finally {
      _finishPublication();
    }
  }

  Future<void> _retryReliableDelivery() async {
    if (_closed || _publicationRunning) return;
    _publicationRunning = true;
    try {
      final published = await _core.outbox.retryExpiredReliableDelivery(
        now: _nowUtc(),
        pow: _pow,
      );
      if (published.isNotEmpty) {
        _emit(const RuntimeEvent(
            RuntimeOperation.reliableDelivery, RuntimePhase.completed));
      }
    } catch (error) {
      _log('reliable delivery retry failed error=$error');
    } finally {
      _finishPublication();
    }
  }

  Future<void> _generateNoise() async {
    if (_closed || _publicationRunning) return;
    _publicationRunning = true;
    const operation = RuntimeOperation.noise;
    try {
      bool allowed;
      try {
        allowed = await _canGenerateNoise();
      } catch (error) {
        _log('noise generator power check failed error=$error');
        return;
      }
      if (!allowed || _closed) return;
      _emit(const RuntimeEvent(operation, RuntimePhase.started));
      await _core.outbox.publishEphemeralRandomMessage(
        pow: _pow,
        ttl: noiseTTL,
        minPayloadBytes: noiseMinPayloadBytes,
        maxPayloadBytes: noiseMaxPayloadBytes,
        onPowProgress: (progress) => _emit(RuntimeEvent(
            operation, RuntimePhase.progress,
            completion: progress.completion)),
      );
      _emit(const RuntimeEvent(operation, RuntimePhase.completed));
    } catch (error) {
      _log('noise generation failed error=$error');
      _emit(RuntimeEvent(operation, RuntimePhase.failed, error: error));
    } finally {
      _finishPublication();
    }
  }

  void _finishPublication() {
    _publicationRunning = false;
    if (!_closed && _outboxRequested) {
      _outboxRequested = false;
      unawaited(publishPending());
    }
  }
}
