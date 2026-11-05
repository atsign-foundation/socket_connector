import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:socket_connector/socket_connector.dart';
import 'package:test/test.dart';

/// The bound these tests give each connector's close flush.
const Duration testCloseFlushTimeout = Duration(seconds: 1);

/// Allowance on top of [testCloseFlushTimeout] for timers and socket events.
const Duration slack = Duration(milliseconds: 500);

/// The bound these tests give a relay flush in the stalled-flush scenarios.
const Duration testStalledFlushTimeout = Duration(seconds: 1);

/// How long bytes below the high-water mark wait toward a side before the
/// connector begins a relay flush of them.
const Duration flushDelay = Duration(seconds: 1);

/// Catalogue: features/close_within_bound.feature
void main() {
  late int savedHighWaterMark;

  setUp(() => savedHighWaterMark = SocketConnector.bufferHighWaterMark);
  tearDown(() => SocketConnector.bufferHighWaterMark = savedHighWaterMark);

  test('a destroyed socket is told apart from one whose peer closed or reset',
      () async {
    Future<(Socket, Socket, Future<Object?>)> pair() async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final accepted = server.first;
      final client =
          await Socket.connect(InternetAddress.loopbackIPv4, server.port);
      final local = await accepted;
      for (final s in [client, local]) {
        _ignoreSinkErrors(s);
        addTearDown(s.destroy);
      }
      final ended = Completer<Object?>();
      local.listen((_) {}, onError: (Object e) {
        if (!ended.isCompleted) ended.complete(e);
      }, onDone: () {
        if (!ended.isCompleted) ended.complete(null);
      });
      return (client, local, ended.future);
    }

    final (_, live, _) = await pair();
    expect(_isDestroyed(live), isFalse, reason: 'a live socket');

    final (_, destroyed, _) = await pair();
    destroyed.destroy();
    expect(_isDestroyed(destroyed), isTrue, reason: 'a destroyed socket');

    final (closingPeer, peerClosed, peerClosedEnd) = await pair();
    await closingPeer.close();
    expect(await peerClosedEnd.timeout(Duration(seconds: 5)), isNull,
        reason: 'the peer\'s close reaches the local socket as end of stream');
    expect(_isDestroyed(peerClosed), isFalse,
        reason: 'a socket whose peer closed');

    final (resettingPeer, peerReset, peerResetEnd) = await pair();
    _setLingerZero(resettingPeer);
    resettingPeer.destroy();
    await Future<void>.delayed(Duration(milliseconds: 100));
    peerReset.add(Uint8List(1024 * 1024));
    expect(await peerResetEnd.timeout(Duration(seconds: 5)),
        isA<SocketException>(),
        reason: 'the peer\'s reset reaches the local socket as an error');
    expect(_isDestroyed(peerReset), isFalse,
        reason: 'a socket whose peer reset and whose write then failed');

    final (_, sinkClosed, _) = await pair();
    await sinkClosed.close();
    expect(_isDestroyed(sinkClosed), isFalse,
        reason: 'a socket whose own sink was closed');
  }, testOn: 'mac-os || linux');

  test(
      'every factory passes closeFlushTimeout to its connector, '
      'which defaults to 30 seconds', () async {
    expect(SocketConnector.defaultCloseFlushTimeout, Duration(seconds: 30));
    expect(() => SocketConnector(closeFlushTimeout: Duration(milliseconds: -1)),
        throwsArgumentError,
        reason: 'a negative closeFlushTimeout is refused');
    expect(SocketConnector.defaultStalledFlushTimeout, Duration(minutes: 2));
    for (final refused in [Duration.zero, Duration(milliseconds: -1)]) {
      expect(() => SocketConnector(stalledFlushTimeout: refused),
          throwsArgumentError,
          reason: 'a stalledFlushTimeout of $refused is refused');
    }
    final bare = SocketConnector();
    addTearDown(bare.close);
    expect(bare.closeFlushTimeout, SocketConnector.defaultCloseFlushTimeout);
    expect(
        bare.stalledFlushTimeout, SocketConnector.defaultStalledFlushTimeout);

    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((s) {
      _ignoreSinkErrors(s);
      addTearDown(s.destroy);
      s.listen((_) {}, onError: (Object _) {});
    });
    final InternetAddress loopback = InternetAddress.loopbackIPv4;
    const Duration chosen = Duration(milliseconds: 1234);
    Future<SocketConnector> build(Duration? bound, String factory) async {
      final Duration closeFlushTimeout =
          bound ?? SocketConnector.defaultCloseFlushTimeout;
      final Duration stalledFlushTimeout =
          bound ?? SocketConnector.defaultStalledFlushTimeout;
      final SocketConnector connector = switch (factory) {
        'serverToServer' => bound == null
            ? await SocketConnector.serverToServer(
                addressA: loopback, addressB: loopback)
            : await SocketConnector.serverToServer(
                addressA: loopback,
                addressB: loopback,
                closeFlushTimeout: closeFlushTimeout,
                stalledFlushTimeout: stalledFlushTimeout),
        'serverToSocket' => bound == null
            ? await SocketConnector.serverToSocket(
                addressA: loopback, addressB: loopback, portB: server.port)
            : await SocketConnector.serverToSocket(
                addressA: loopback,
                addressB: loopback,
                portB: server.port,
                closeFlushTimeout: closeFlushTimeout,
                stalledFlushTimeout: stalledFlushTimeout),
        'socketToServer' => bound == null
            ? await SocketConnector.socketToServer(
                addressA: loopback, portA: server.port, addressB: loopback)
            : await SocketConnector.socketToServer(
                addressA: loopback,
                portA: server.port,
                addressB: loopback,
                closeFlushTimeout: closeFlushTimeout,
                stalledFlushTimeout: stalledFlushTimeout),
        _ => bound == null
            ? await SocketConnector.socketToSocket(
                addressA: loopback,
                portA: server.port,
                addressB: loopback,
                portB: server.port)
            : await SocketConnector.socketToSocket(
                addressA: loopback,
                portA: server.port,
                addressB: loopback,
                portB: server.port,
                closeFlushTimeout: closeFlushTimeout,
                stalledFlushTimeout: stalledFlushTimeout),
      };
      addTearDown(connector.close);
      return connector;
    }

    for (final factory in [
      'serverToServer',
      'serverToSocket',
      'socketToServer',
      'socketToSocket'
    ]) {
      final SocketConnector defaulted = await build(null, factory);
      expect(
          defaulted.closeFlushTimeout, SocketConnector.defaultCloseFlushTimeout,
          reason: '$factory defaults closeFlushTimeout to 30 seconds');
      expect(defaulted.stalledFlushTimeout,
          SocketConnector.defaultStalledFlushTimeout,
          reason: '$factory defaults stalledFlushTimeout to 2 minutes');
      final SocketConnector given = await build(chosen, factory);
      expect(given.closeFlushTimeout, chosen,
          reason: '$factory passes closeFlushTimeout to its connector');
      expect(given.stalledFlushTimeout, chosen,
          reason: '$factory passes stalledFlushTimeout to its connector');
    }
  });

  group(
      'A connection whose peers both close is reported once, after both '
      'sides are destroyed', () {
    Future<_Relay> exchanged() async {
      final relay = await _Relay.start();
      relay.peerA.send(100000);
      relay.peerB.send(50000);
      await _waitFor(
          () =>
              relay.peerB.received == relay.peerA.sent &&
              relay.peerA.received == relay.peerB.sent,
          'each peer to receive what the other sent');
      return relay;
    }

    Future<void> expectReportedOnce(_Relay relay) async {
      await _waitFor(() => relay.ends.isNotEmpty, 'the connection\'s end',
          within: testCloseFlushTimeout + slack);
      final _End end = relay.ends.first;
      expect(end.connection, same(relay.connection),
          reason: 'connectionClosedStream emits that Connection');
      expect(end.sidesDestroyed, isTrue,
          reason: 'both of its sides are destroyed when it is emitted');
      expect(end.closedAtSet, isTrue, reason: 'each side\'s closedAt is set');
      expect(end.rcvdA, relay.peerA.sent,
          reason: 'sideA.rcvd equals the bytes peer A sent');
      expect(end.rcvdB, relay.peerB.sent,
          reason: 'sideB.rcvd equals the bytes peer B sent');
      expect(await relay.allEnds(), hasLength(1),
          reason: 'connectionClosedStream emits that Connection exactly once');
      expect(relay.endsClosed, isTrue,
          reason: 'connectionClosedStream closes once the connector is closed'
              ' and every Connection has been emitted');
    }

    test('when peer A closes its socket', () async {
      final relay = await exchanged();
      unawaited(relay.peerA.socket.close());
      await expectReportedOnce(relay);
    });

    test('when both peers close at once', () async {
      final relay = await exchanged();
      unawaited(relay.peerA.socket.close());
      unawaited(relay.peerB.socket.close());
      await expectReportedOnce(relay);
    });

    test('when close() races a side\'s close', () async {
      final relay = await exchanged();
      _setBufferSizes(relay.peerA.socket, relay.connection.sideA.socket);
      relay.peerA.stopReading();
      relay.peerB.send(2 * 1024 * 1024);
      await _waitFor(() => relay.connection.sideA.sent == relay.peerB.sent,
          'side A to be handed everything peer B sent');
      unawaited(relay.peerA.socket.close());
      await _waitFor(() => relay.connection.sideA.state == SideState.closed,
          'side A\'s close to begin');
      expect(relay.connection.sideA.closedAt, isNull,
          reason: 'side A is still flushing when close() is called');
      final sinceClose = Stopwatch()..start();
      relay.connector.close();

      await _expectDestroyedWithin([relay.connection.sideB], sinceClose, slack,
          reason: 'close() closes side B at once, while side A is still'
              ' flushing');
      await _waitFor(() => relay.ends.isNotEmpty, 'the connection\'s end',
          within: testCloseFlushTimeout + slack);
      expect(relay.ends.single.sidesDestroyed, isTrue,
          reason: 'both of its sides are destroyed when it is emitted');
      expect(await relay.allEnds(), hasLength(1),
          reason: 'connectionClosedStream emits that Connection exactly once');
    });
  });

  test('A peer that stops reading cannot keep its side open', () async {
    // Raised so the relay hands every byte to side B's socket at once, and
    // only the close's own flush is left waiting on peer B.
    SocketConnector.bufferHighWaterMark = 64 * 1024 * 1024;
    const int queued = 24 * 1024 * 1024;
    final relay = await _Relay.start();
    relay.peerB.stopReading();

    relay.peerA.socket.add(Uint8List(queued));
    await _waitFor(() => relay.connection.sideB.sent == queued,
        'side B to be handed all $queued bytes');
    expect(relay.peerB.received, lessThan(queued),
        reason: 'data is queued for peer B when peer A closes');

    final sinceClose = Stopwatch()..start();
    unawaited(relay.peerA.socket.close());

    await _expectDestroyedWithin(
        [relay.connection.sideB], sinceClose, testCloseFlushTimeout + slack,
        reason: 'side B is destroyed no later than closeFlushTimeout'
            ' after its close began');
    await _waitFor(() => relay.ends.isNotEmpty, 'the connection\'s end',
        within: slack);
    expect(relay.ends.single.connection, same(relay.connection),
        reason: 'connectionClosedStream emits the Connection');
  });

  group('close() frees a side whose flush cannot finish', () {
    test('when its peer has stopped reading', () async {
      SocketConnector.bufferHighWaterMark = 64 * 1024 * 1024;
      const int queued = 24 * 1024 * 1024;
      final relay = await _Relay.start();
      relay.peerB.stopReading();

      relay.peerA.socket.add(Uint8List(queued));
      await _waitFor(() => relay.connection.sideB.sent == queued,
          'side B to be handed all $queued bytes');

      int? endsWhenDone;
      unawaited(
          relay.connector.done.then((_) => endsWhenDone = relay.ends.length));
      final sinceClose = Stopwatch()..start();
      relay.connector.close();

      await _expectDestroyedWithin(
          [relay.connection.sideA, relay.connection.sideB],
          sinceClose,
          testCloseFlushTimeout + slack,
          reason: 'every side is destroyed no later than closeFlushTimeout'
              ' after close() began');
      await relay.connector.done.timeout(testCloseFlushTimeout + slack);
      expect(endsWhenDone, 0,
          reason: 'the connection is still open when done completes');
      expect(await relay.endsClosedWithin(slack), isTrue,
          reason: 'connectionClosedStream closes once that Connection has been'
              ' emitted, with no further close()');
      expect(relay.ends, hasLength(1),
          reason: 'connectionClosedStream emits a Connection whose sides are'
              ' destroyed after done completes');
    });

    test('when the relay\'s own flush holds its socket', () async {
      SocketConnector.bufferHighWaterMark = 64 * 1024;
      const int written = 32 * 1024 * 1024;
      final relay = await _Relay.start();
      relay.peerB.stopReading();

      relay.peerA.socket.add(Uint8List(written));
      await _waitForSteady(() => relay.connection.sideA.rcvd,
          'the relay to stop reading side A while side B flushes');
      expect(relay.connection.sideA.rcvd, lessThan(written),
          reason: 'the relay is waiting on its own flush of side B');

      final sinceClose = Stopwatch()..start();
      relay.connector.close();

      await _expectDestroyedWithin(
          [relay.connection.sideA, relay.connection.sideB],
          sinceClose,
          testCloseFlushTimeout + slack,
          reason: 'every side is destroyed no later than closeFlushTimeout'
              ' after close() began');
      await relay.connector.done.timeout(testCloseFlushTimeout + slack);
    });

    test(
        'when the relay\'s own flush holds its socket, without leaving that'
        ' flush\'s stall timer running', () async {
      SocketConnector.bufferHighWaterMark = 64 * 1024;
      const Duration stall = Duration(seconds: 7);
      final timers = <Timer>[];
      int? activeAtEnd;
      await runZoned(() async {
        final relay = await _Relay.start(stalledFlushTimeout: stall);
        relay.connector.connectionClosedStream.listen(
            (_) => activeAtEnd = timers.where((t) => t.isActive).length);
        relay.peerB.stopReading();
        relay.peerA.send(32 * 1024 * 1024);
        await _waitForSteady(() => relay.connection.sideA.rcvd,
            'the relay to stop reading side A while side B flushes');
        relay.connector.close();
        await _waitFor(() => activeAtEnd != null, 'the connection\'s end',
            within: testCloseFlushTimeout + slack);
      }, zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
        final Timer timer = parent.createTimer(zone, duration, callback);
        if (duration == stall) {
          timers.add(timer);
        }
        return timer;
      }));
      expect(timers, isNotEmpty,
          reason: 'the relay\'s flush of side B started a stall timer');
      expect(activeAtEnd, 0, reason: 'no stall timer outlives the connection');
    });

    test('when the other side\'s close has already begun', () async {
      const int queued = 2 * 1024 * 1024;
      final relay = await _Relay.start();
      _setBufferSizes(relay.peerA.socket, relay.connection.sideA.socket);
      _setBufferSizes(relay.peerB.socket, relay.connection.sideB.socket);
      relay.peerA.stopReading();
      relay.peerB.stopReading();
      relay.peerA.send(queued);
      relay.peerB.send(queued);
      await _waitFor(
          () =>
              relay.connection.sideA.sent == queued &&
              relay.connection.sideB.sent == queued,
          'each side to be handed $queued bytes');

      unawaited(relay.peerA.socket.close());
      await _waitFor(() => relay.connection.sideA.state == SideState.closed,
          'side A\'s close to begin');
      expect(relay.connection.sideA.closedAt, isNull,
          reason: 'side A is still flushing when close() is called');

      final sinceClose = Stopwatch()..start();
      relay.connector.close();

      await _expectDestroyedWithin(
          [relay.connection.sideA, relay.connection.sideB],
          sinceClose,
          testCloseFlushTimeout + slack,
          reason: 'every side is destroyed no later than closeFlushTimeout'
              ' after close() began');
    });

    test(
        'when the other peer is still sending, without leaving a flush timer'
        ' running', () async {
      const Duration closeFlushTimeout = Duration(milliseconds: 2500);
      const Duration stall = Duration(seconds: 7);
      final timers = <Timer>[];
      bool tracking = false;
      int? activeAtEnd;
      late _Relay relay;
      late int rcvdFromAAtDestroy;
      await runZoned(() async {
        relay = await _Relay.start(
            closeFlushTimeout: closeFlushTimeout, stalledFlushTimeout: stall);
        relay.connector.connectionClosedStream.listen(
            (_) => activeAtEnd = timers.where((t) => t.isActive).length);
        _setBufferSizes(relay.peerA.socket, relay.connection.sideA.socket);
        relay.peerA.stopReading();
        relay.peerB.send(2 * 1024 * 1024);
        await _waitFor(() => relay.connection.sideA.sent == relay.peerB.sent,
            'side A to be handed everything peer B sent');
        final Timer sending = Timer.periodic(
            Duration(milliseconds: 5), (_) => relay.peerA.send(1024));
        addTearDown(sending.cancel);
        await _waitFor(() => relay.connection.sideB.sent > 0,
            'side B to be handed data from peer A');

        tracking = true;
        relay.connector.close();
        await _waitFor(() => relay.connection.sideB.closedAt != null,
            'side B to be destroyed');
        rcvdFromAAtDestroy = relay.connection.sideA.rcvd;
        await _waitFor(() => activeAtEnd != null, 'the connection\'s end',
            within: closeFlushTimeout + slack);
        sending.cancel();
      }, zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
        final Timer timer = parent.createTimer(zone, duration, callback);
        if (tracking && (duration == flushDelay || duration == stall)) {
          timers.add(timer);
        }
        return timer;
      }));
      expect(relay.connection.sideA.rcvd, greaterThan(rcvdFromAAtDestroy),
          reason: 'the relay still reads peer A after side B is destroyed');
      expect(activeAtEnd, 0,
          reason: 'no flush timer outlives the connection');
    });
  });

  group('close() frees a side whose flush cannot finish', () {
    test('when it is still authenticating', () async {
      final sockets = <Socket>[];
      final started = Completer<void>();
      final connector = await SocketConnector.serverToServer(
        addressA: InternetAddress.loopbackIPv4,
        addressB: InternetAddress.loopbackIPv4,
        authTimeout: Duration(seconds: 4),
        closeFlushTimeout: testCloseFlushTimeout,
        socketAuthVerifierA: (socket) {
          sockets.add(socket);
          started.complete();
          return Completer<(bool, Stream<Uint8List>?)>().future;
        },
      );
      addTearDown(connector.close);
      final peerA = await _Peer.connect(connector.sideAPort!);
      await started.future.timeout(Duration(seconds: 5));

      final sinceClose = Stopwatch()..start();
      connector.close();
      while (!_isDestroyed(sockets.single) &&
          sinceClose.elapsed < testCloseFlushTimeout + slack) {
        await Future<void>.delayed(Duration(milliseconds: 5));
      }
      expect(_isDestroyed(sockets.single), isTrue,
          reason: 'every side is destroyed no later than closeFlushTimeout'
              ' after close() began (after ${sinceClose.elapsedMilliseconds}'
              ' ms: the authenticating side is not destroyed)');
      await peerA.ended.future.timeout(slack);
    });

    test(
        'when another write holds its socket, after five seconds even under a'
        ' longer closeFlushTimeout', () async {
      final relay = await _Relay.start(closeFlushTimeout: Duration(seconds: 8));
      addTearDown(_bindSink(relay.connection.sideB.socket).close);

      final sinceClose = Stopwatch()..start();
      relay.connector.close();

      await _expectDestroyedWithin(
          [relay.connection.sideB], sinceClose, Duration(milliseconds: 6500),
          reason: 'a side whose socket another write holds is destroyed five'
              ' seconds into its close');
    }, timeout: Timeout(Duration(seconds: 30)));
  });

  test('a side whose authentication ends after close() is closed, not paired',
      () async {
    final started = [Completer<void>(), Completer<void>()];
    final authenticated = Completer<void>();
    SocketAuthVerifier verifierFor(int i) => (Socket socket) async {
          started[i].complete();
          await authenticated.future;
          return (true, socket);
        };
    final connector = await SocketConnector.serverToServer(
      addressA: InternetAddress.loopbackIPv4,
      addressB: InternetAddress.loopbackIPv4,
      socketAuthVerifierA: verifierFor(0),
      socketAuthVerifierB: verifierFor(1),
      closeFlushTimeout: testCloseFlushTimeout,
    );
    addTearDown(connector.close);
    final peerA = await _Peer.connect(connector.sideAPort!);
    final peerB = await _Peer.connect(connector.sideBPort!);
    await Future.wait([for (final s in started) s.future])
        .timeout(Duration(seconds: 5));

    connector.close();
    // Lets every callback that close() triggers run before authentication
    // ends.
    await Future<void>.delayed(Duration(milliseconds: 200));
    authenticated.complete();
    await Future<void>.delayed(Duration(milliseconds: 200));

    expect(connector.connections, isEmpty,
        reason: 'no Connection is formed once the connector is closed');
    await Future.wait([peerA.ended.future, peerB.ended.future])
        .timeout(testCloseFlushTimeout + slack, onTimeout: () {
      fail('both sides are destroyed once their authentication ends');
    });
  });

  test('a side B that connects while close() runs is destroyed', () async {
    final destination =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(destination.close);
    final peerB = Completer<_Peer>();
    destination.listen((s) => peerB.complete(_Peer(s)));
    final joining = Completer<void>();
    final release = Completer<void>();
    final connector = await SocketConnector.serverToSocket(
      addressA: InternetAddress.loopbackIPv4,
      addressB: InternetAddress.loopbackIPv4,
      portB: destination.port,
      closeFlushTimeout: testCloseFlushTimeout,
      beforeJoining: (sideA, sideB) async {
        joining.complete();
        await release.future;
      },
    );
    addTearDown(connector.close);
    await _Peer.connect(connector.sideAPort!);
    await joining.future.timeout(Duration(seconds: 5));
    final peer = await peerB.future.timeout(Duration(seconds: 5));

    connector.close();
    release.complete();

    await peer.ended.future.timeout(testCloseFlushTimeout + slack,
        onTimeout: () => fail('side B\'s socket is destroyed once the'
            ' connector has closed'));
  });

  test('A relay flush that never completes closes its connection', () async {
    const int written = 32 * 1024 * 1024;
    final relay =
        await _Relay.start(stalledFlushTimeout: testStalledFlushTimeout);
    relay.peerB.stopReading();

    relay.peerA.send(written);
    await _waitForSteady(() => relay.connection.sideA.rcvd,
        'the relay to stop reading side A while side B flushes');
    expect(relay.connection.sideB.sent,
        greaterThanOrEqualTo(SocketConnector.bufferHighWaterMark),
        reason: 'more than bufferHighWaterMark is queued toward side B');
    expect(relay.connection.sideA.rcvd, lessThan(written),
        reason: 'the relay\'s flush toward side B has not completed');

    final sinceStall = Stopwatch()..start();
    await _expectDestroyedWithin(
        [relay.connection.sideA, relay.connection.sideB],
        sinceStall,
        testStalledFlushTimeout + testCloseFlushTimeout + slack,
        reason: 'both sides of the Connection are destroyed no later than'
            ' closeFlushTimeout after the flush passes stalledFlushTimeout');
    expect(await relay.allEnds(), hasLength(1),
        reason: 'connectionClosedStream emits the Connection once');
  });

  test('A reader that keeps draining is not cut off', () async {
    final relay =
        await _Relay.start(stalledFlushTimeout: testStalledFlushTimeout);
    relay.peerB.readInBursts();

    final carrying = Stopwatch()..start();
    while (carrying.elapsed < testStalledFlushTimeout * 3) {
      relay.peerA.send(64 * 1024);
      await Future<void>.delayed(Duration(milliseconds: 5));
    }

    expect(relay.connection.sideB.sent,
        greaterThan(2 * SocketConnector.bufferHighWaterMark),
        reason: 'relay flushes toward side B have completed while the'
            ' Connection carried data');
    expect((
      relay.connection.sideA.state,
      relay.connection.sideB.state
    ), (
      SideState.open,
      SideState.open
    ), reason: 'the Connection stays open');
  }, timeout: Timeout(Duration(seconds: 60)));

  test('A stalled flush closes only its own Connection', () async {
    const int written = 32 * 1024 * 1024;
    final connector = await SocketConnector.serverToServer(
      addressA: InternetAddress.loopbackIPv4,
      addressB: InternetAddress.loopbackIPv4,
      closeFlushTimeout: testCloseFlushTimeout,
      stalledFlushTimeout: testStalledFlushTimeout,
    );
    addTearDown(connector.close);
    final established = <Connection>[];
    connector.connectionStream.listen(established.add);
    final peers = <_Peer>[];
    for (int i = 0; i < 2; i++) {
      peers.add(await _Peer.connect(connector.sideAPort!));
      peers.add(await _Peer.connect(connector.sideBPort!));
      await _waitFor(() => established.length == i + 1, 'connection $i');
    }
    final [a1, b1, a2, b2] = peers;
    final [first, second] = established;
    expect((
      first.sideA.remotePort,
      second.sideA.remotePort
    ), (
      a1.socket.port,
      a2.socket.port
    ), reason: 'each Connection pairs the peers that connected together');

    b1.stopReading();
    a1.send(written);
    await _waitForSteady(() => first.sideA.rcvd,
        'the relay to stop reading the first side A while its side B flushes');
    expect(first.sideA.rcvd, lessThan(written),
        reason: 'the first Connection\'s flush toward side B has not'
            ' completed');

    final sinceStall = Stopwatch()..start();
    await _expectDestroyedWithin([first.sideA, first.sideB], sinceStall,
        testStalledFlushTimeout + testCloseFlushTimeout + slack,
        reason: 'the first Connection is destroyed');
    expect(
        [second.sideA, second.sideB]
            .map((s) => (s.state, _isDestroyed(s.socket))),
        everyElement((SideState.open, false)),
        reason: 'the second Connection stays open');
    a2.send(1000);
    b2.send(1000);
    await _waitFor(() => a2.received == 1000 && b2.received == 1000,
        'the second Connection to carry data both ways');
  });

  group('A reset while the relay\'s read is paused still closes both sides',
      () {
    /// Pauses the relay's read of side A behind its flush of side B, hands
    /// side A [towardsA] bytes that peer A is not reading, resets peer A, and
    /// expects both sides destroyed within the bound.
    Future<void> expectBothClosedAfterReset(int towardsA,
        {bool holdSideB = false,
        Duration stall = SocketConnector.defaultStalledFlushTimeout,
        void Function(SocketConnector connector)? watch,
        void Function()? beforeSendingTowardsA}) async {
      final int written = holdSideB ? 64 * 1024 : 32 * 1024 * 1024;
      final relay = await _Relay.start(stalledFlushTimeout: stall);
      watch?.call(relay.connector);
      _setBufferSizes(relay.peerA.socket, relay.connection.sideA.socket);
      relay.peerA.stopReading();
      relay.peerB.stopReading();
      if (holdSideB) {
        addTearDown(_bindSink(relay.connection.sideB.socket).close);
      }

      relay.peerA.socket.add(Uint8List(written));
      await _waitForSteady(() => relay.connection.sideA.rcvd,
          'the relay to stop reading side A while side B flushes');
      if (holdSideB) {
        expect(relay.connection.sideB.sent,
            lessThan(relay.connection.sideA.produced),
            reason: 'the relay still holds data for side B, and so has paused'
                ' its read of side A');
      } else {
        expect(relay.connection.sideA.rcvd, lessThan(written),
            reason: 'the relay\'s read of side A is paused by backpressure');
      }

      beforeSendingTowardsA?.call();
      relay.peerB.send(towardsA);
      await _waitForSteady(() => relay.connection.sideB.rcvd,
          'the relay to hand side A what it can');

      _setLingerZero(relay.peerA.socket);
      final sinceReset = Stopwatch()..start();
      relay.peerA.socket.destroy();

      await _expectDestroyedWithin(
          [relay.connection.sideA, relay.connection.sideB],
          sinceReset,
          testCloseFlushTimeout + slack,
          reason: 'both sides are destroyed no later than closeFlushTimeout'
              ' after the reset is seen');
      expect(await relay.allEnds(), hasLength(1),
          reason: 'connectionClosedStream emits the Connection once');
    }

    test('when a write to side A is pending', () async {
      // Below the high-water mark, so no flush of side A is in flight, but
      // far more than side A's shrunken socket buffers hold.
      await expectBothClosedAfterReset(2 * 1024 * 1024);
    });

    test('when the relay\'s flush of side A is in flight', () async {
      SocketConnector.bufferHighWaterMark = 64 * 1024;
      await expectBothClosedAfterReset(2 * 1024 * 1024);
    });

    test(
        'when the relay\'s flush of side A is in flight, without leaving that'
        ' flush\'s stall timer running', () async {
      SocketConnector.bufferHighWaterMark = 64 * 1024;
      const Duration stall = Duration(seconds: 7);
      final timers = <Timer>[];
      int? activeAtEnd;
      await runZoned(
          () => expectBothClosedAfterReset(2 * 1024 * 1024,
              stall: stall,
              watch: (connector) => connector.connectionClosedStream.listen(
                  (_) => activeAtEnd = timers.where((t) => t.isActive).length)),
          zoneSpecification: ZoneSpecification(
              createTimer: (self, parent, zone, duration, callback) {
        final Timer timer = parent.createTimer(zone, duration, callback);
        if (duration == stall) {
          timers.add(timer);
        }
        return timer;
      }));
      expect(timers, isNotEmpty,
          reason: 'the relay\'s flush of side A started a stall timer');
      expect(activeAtEnd, 0, reason: 'no stall timer outlives the connection');
    });

    test(
        'when the relay\'s flush of side A fails, without leaving that flush\'s'
        ' stall timer running past the failure', () async {
      SocketConnector.bufferHighWaterMark = 64 * 1024;
      const Duration stall = Duration(seconds: 7);
      final timers = <Timer>[];
      int sideBTimers = 0;
      int? sideAActiveAtFailure;
      final sink = _LineSink(onLine: (line) {
        if (line.contains('Failed to write to side A')) {
          sideAActiveAtFailure ??=
              timers.skip(sideBTimers).where((t) => t.isActive).length;
        }
      });
      await runZoned(
          () => expectBothClosedAfterReset(2 * 1024 * 1024,
              stall: stall,
              watch: (connector) => connector.logger = sink,
              beforeSendingTowardsA: () => sideBTimers = timers.length),
          zoneSpecification: ZoneSpecification(
              createTimer: (self, parent, zone, duration, callback) {
        final Timer timer = parent.createTimer(zone, duration, callback);
        if (duration == stall) {
          timers.add(timer);
        }
        return timer;
      }));
      expect(timers.length, greaterThan(sideBTimers),
          reason: 'the relay\'s flush of side A started a stall timer');
      expect(sideAActiveAtFailure, isNotNull,
          reason: 'the failed flush of side A is reported');
      expect(sideAActiveAtFailure, 0,
          reason: 'no stall timer of side A is running once its failed flush'
              ' is reported');
    });

    test('when the relay still holds data for side B', () async {
      await expectBothClosedAfterReset(2 * 1024 * 1024, holdSideB: true);
    });
  }, testOn: 'mac-os || linux');

  test('Fifty connections are each reported once and correctly', () async {
    const int count = 50;
    final connector = await SocketConnector.serverToServer(
      addressA: InternetAddress.loopbackIPv4,
      addressB: InternetAddress.loopbackIPv4,
      closeFlushTimeout: testCloseFlushTimeout,
    );
    addTearDown(connector.close);
    final established = <Connection>[];
    connector.connectionStream.listen(established.add);
    final ends = <_End>[];
    final endsDone = Completer<void>();
    connector.connectionClosedStream
        .listen((c) => ends.add(_End(c)), onDone: endsDone.complete);

    final peersA = await Future.wait(
        [for (int i = 0; i < count; i++) _Peer.connect(connector.sideAPort!)]);
    final peersB = await Future.wait(
        [for (int i = 0; i < count; i++) _Peer.connect(connector.sideBPort!)]);
    await _waitFor(() => established.length == count, '$count connections');
    final byPortA = {for (final p in peersA) p.socket.port: p};
    final byPortB = {for (final p in peersB) p.socket.port: p};
    (_Peer, _Peer) peersOf(Connection c) =>
        (byPortA[c.sideA.remotePort]!, byPortB[c.sideB.remotePort]!);

    for (int i = 0; i < count; i++) {
      peersA[i].send(1000 * i + 7);
      peersB[i].send(500 * i + 3);
    }
    await _waitFor(
        () => established.every((c) {
              final (a, b) = peersOf(c);
              return b.received == a.sent && a.received == b.sent;
            }),
        'every peer to receive what its partner sent');

    final random = Random(50);
    await Future.wait([
      for (final c in established.toList()..shuffle(random))
        () async {
          final (a, b) = peersOf(c);
          final bool closeA = random.nextBool();
          await Future<void>.delayed(
              Duration(milliseconds: random.nextInt(20)));
          await (closeA ? a : b).socket.close();
        }()
    ]);

    await _waitFor(() => ends.length == count, '$count ends',
        within: testCloseFlushTimeout + slack);
    connector.close();
    await endsDone.future.timeout(testCloseFlushTimeout + slack);

    expect(ends, hasLength(count),
        reason: 'connectionClosedStream emits $count events');
    expect(ends.map((e) => e.connection).toSet(), hasLength(count),
        reason: 'one per Connection, none repeated');
    for (final end in ends) {
      final (a, b) = peersOf(end.connection);
      expect(end.sidesDestroyed && end.closedAtSet, isTrue,
          reason: 'each Connection is emitted after both its sides are'
              ' destroyed');
      expect((end.rcvdA, end.rcvdB), (a.sent, b.sent),
          reason: 'each event\'s byte counts match what that Connection\'s'
              ' own peers sent');
    }
  }, timeout: Timeout(Duration(seconds: 60)));

  test('Nobody listening costs nothing', () async {
    const int batches = 20;
    const int perBatch = 50;
    final connector = await SocketConnector.serverToServer(
      addressA: InternetAddress.loopbackIPv4,
      addressB: InternetAddress.loopbackIPv4,
      closeFlushTimeout: testCloseFlushTimeout,
    );
    addTearDown(connector.close);
    final established = <Connection>[];
    connector.connectionStream.listen(established.add);

    for (int batch = 0; batch < batches; batch++) {
      final peersA = await Future.wait([
        for (int i = 0; i < perBatch; i++) _Peer.connect(connector.sideAPort!)
      ]);
      final peersB = await Future.wait([
        for (int i = 0; i < perBatch; i++) _Peer.connect(connector.sideBPort!)
      ]);
      await _waitFor(() => established.length == (batch + 1) * perBatch,
          'batch $batch to connect');
      await Future.wait([for (final p in peersA) p.socket.close()]);
      await _waitFor(
          () => established.every(
              (c) => c.sideA.closedAt != null && c.sideB.closedAt != null),
          'batch $batch to close',
          within: testCloseFlushTimeout + slack);
      for (final p in [...peersA, ...peersB]) {
        p.socket.destroy();
      }
    }
    expect(established, hasLength(batches * perBatch));

    final late = <Connection>[];
    final endsDone = Completer<void>();
    connector.connectionClosedStream
        .listen(late.add, onDone: endsDone.complete);
    connector.close();
    await endsDone.future.timeout(testCloseFlushTimeout + slack);
    expect(late, isEmpty, reason: 'no close events are retained');
  }, timeout: Timeout(Duration(seconds: 90)));

  group('A peer that is reading receives the tail before its side is destroyed',
      () {
    test('when the relay still holds the tail as side B\'s close begins',
        () async {
      // Raised so the relay reads all of peer A's data, and side B's close
      // begins with all of it still queued in the relay.
      SocketConnector.bufferHighWaterMark = 64 * 1024 * 1024;
      const int queued = 32 * 1024 * 1024;
      final relay =
          await _Relay.start(closeFlushTimeout: Duration(seconds: 10));
      relay.peerB.stopReading();

      relay.peerA.send(queued);
      unawaited(relay.peerA.socket.close());
      await _waitFor(() => relay.connection.sideA.closedAt != null,
          'side A to be destroyed');
      expect(relay.connection.sideB.state, SideState.closed,
          reason: 'side B\'s close has begun with data queued for peer B');
      expect(relay.peerB.received, lessThan(queued),
          reason: 'data is queued for peer B when side B\'s close begins');

      relay.peerB.resumeReading();
      await relay.peerB.ended.future.timeout(Duration(seconds: 30),
          onTimeout: () => fail('the relay never closed side B'));
      expect(relay.peerB.received, queued,
          reason: 'peer B receives all $queued bytes before side B is'
              ' destroyed');
      expect(_isDestroyed(relay.connection.sideB.socket), isTrue,
          reason: 'side B is destroyed once its tail is delivered');
    }, timeout: Timeout(Duration(seconds: 60)));

    test(
        'when a transformer still holds the tail as the connector closes'
        ' itself', () async {
      final (peerB, _) = await _transformerTail(sent: 1024 * 1024);
      expect(peerB.received, 1024 * 1024,
          reason: 'peer B receives all 1048576 bytes before side B is'
              ' destroyed');
    }, timeout: Timeout(Duration(seconds: 60)));

    test(
        'when a transformer still holds the tail, side B\'s deadline timer is'
        ' cancelled once side B closes', () async {
      final timers = <Timer>[];
      await runZoned(
          () => _transformerTail(
              sent: 1024 * 1024, closeFlushTimeout: Duration(seconds: 7)),
          zoneSpecification: ZoneSpecification(
              createTimer: (self, parent, zone, duration, callback) {
        final Timer timer = parent.createTimer(zone, duration, callback);
        if (duration > Duration(seconds: 6) &&
            duration <= Duration(seconds: 7)) {
          timers.add(timer);
        }
        return timer;
      }));
      expect(timers, isNotEmpty,
          reason: 'the close of side A and side B set up their deadlines');
      expect(timers.where((t) => t.isActive), isEmpty,
          reason: 'no deadline timer outlives the connection');
    }, timeout: Timeout(Duration(seconds: 60)));
  });

  test(
      'A peer that stops reading with less than bufferHighWaterMark queued is'
      ' closed', () async {
    const int queued = 3 * 1024 * 1024;
    final relay =
        await _Relay.start(stalledFlushTimeout: testStalledFlushTimeout);
    _setBufferSizes(relay.peerB.socket, relay.connection.sideB.socket);
    relay.peerB.stopReading();

    final sinceSent = Stopwatch()..start();
    relay.peerA.send(queued);
    await _expectDestroyedWithin(
        [relay.connection.sideA, relay.connection.sideB],
        sinceSent,
        flushDelay + testStalledFlushTimeout + testCloseFlushTimeout + slack,
        reason: 'both sides are destroyed no later than the flush delay plus'
            ' stalledFlushTimeout plus closeFlushTimeout after the last byte'
            ' reached side B');
    expect(relay.peerB.received, lessThan(queued),
        reason: 'peer B had stopped reading with data queued for it');
    expect(await relay.allEnds(), hasLength(1),
        reason: 'connectionClosedStream emits the Connection once');
  });

  test('A sender that trickles cannot hold queued bytes open', () async {
    const int queued = 3 * 1024 * 1024;
    final relay =
        await _Relay.start(stalledFlushTimeout: testStalledFlushTimeout);
    _setBufferSizes(relay.peerB.socket, relay.connection.sideB.socket);
    relay.peerB.stopReading();

    final sinceFirst = Stopwatch()..start();
    relay.peerA.send(queued);
    final Timer trickle =
        Timer.periodic(flushDelay ~/ 2, (_) => relay.peerA.send(1));
    addTearDown(trickle.cancel);
    await _expectDestroyedWithin(
        [relay.connection.sideA, relay.connection.sideB],
        sinceFirst,
        flushDelay + testStalledFlushTimeout + testCloseFlushTimeout + slack,
        reason: 'both sides are destroyed no later than the flush delay plus'
            ' stalledFlushTimeout plus closeFlushTimeout after the first'
            ' queued byte reached side B');
  });

  test('An idle connection with nothing queued stays open', () async {
    final timers = <Timer>[];
    bool tracking = false;
    await runZoned(() async {
      final relay =
          await _Relay.start(stalledFlushTimeout: testStalledFlushTimeout);
      tracking = true;
      relay.peerA.send(1000);
      relay.peerB.send(1000);
      await _waitFor(
          () => relay.peerA.received == 1000 && relay.peerB.received == 1000,
          'each peer to read everything sent to it');

      await Future<void>.delayed(
          flushDelay + testStalledFlushTimeout + testCloseFlushTimeout + slack);
      expect(
          [relay.connection.sideA, relay.connection.sideB]
              .map((s) => (s.state, _isDestroyed(s.socket))),
          everyElement((SideState.open, false)),
          reason: 'the Connection stays open');
      expect(timers.where((t) => t.isActive), isEmpty,
          reason: 'the connector has no timer running for it');
    }, zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
      final Timer timer = parent.createTimer(zone, duration, callback);
      if (tracking && duration >= Duration(milliseconds: 100)) {
        timers.add(timer);
      }
      return timer;
    }));
  });

  test('A slow reader below bufferHighWaterMark is not cut off', () async {
    const Duration stall = Duration(milliseconds: 1100);
    final stallTimers = <Timer>[];
    await runZoned(() async {
      final relay = await _Relay.start(stalledFlushTimeout: stall);
      relay.peerB.readInBursts();

      final carrying = Stopwatch()..start();
      while (carrying.elapsed < stall * 3) {
        relay.peerA.send(32 * 1024);
        await Future<void>.delayed(Duration(milliseconds: 50));
      }

      expect(relay.peerA.sent, lessThan(SocketConnector.bufferHighWaterMark),
          reason: 'less than bufferHighWaterMark was sent in all');
      expect(stallTimers.length, greaterThanOrEqualTo(2),
          reason: 'relay flushes toward side B began each flush delay');
      expect((
        relay.connection.sideA.state,
        relay.connection.sideB.state
      ), (
        SideState.open,
        SideState.open
      ), reason: 'the Connection stays open');
    }, zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
      final Timer timer = parent.createTimer(zone, duration, callback);
      if (duration == stall) {
        stallTimers.add(timer);
      }
      return timer;
    }));
  });

  test(
      'close() during a flush begun by the flush delay frees every side within'
      ' the bound', () async {
    const Duration stall = Duration(seconds: 7);
    final stallTimers = <Timer>[];
    final timers = <Timer>[];
    bool tracking = false;
    int? activeAtEnd;
    await runZoned(() async {
      final relay = await _Relay.start(stalledFlushTimeout: stall);
      relay.connector.connectionClosedStream
          .listen((_) => activeAtEnd = timers.where((t) => t.isActive).length);
      _setBufferSizes(relay.peerB.socket, relay.connection.sideB.socket);
      relay.peerB.stopReading();
      tracking = true;
      relay.peerA.send(3 * 1024 * 1024);
      await _waitFor(() => stallTimers.isNotEmpty,
          'a relay flush toward side B that the flush delay began');

      final sinceClose = Stopwatch()..start();
      relay.connector.close();
      await _expectDestroyedWithin(
          [relay.connection.sideA, relay.connection.sideB],
          sinceClose,
          testCloseFlushTimeout + slack,
          reason: 'every side is destroyed no later than closeFlushTimeout'
              ' after close() began');
      await _waitFor(() => activeAtEnd != null, 'the connection\'s end',
          within: slack);
    }, zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
      final Timer timer = parent.createTimer(zone, duration, callback);
      if (duration == stall) {
        stallTimers.add(timer);
      }
      if (tracking && duration >= Duration(milliseconds: 100)) {
        timers.add(timer);
      }
      return timer;
    }));
    expect(activeAtEnd, 0,
        reason: 'no timer the connector started for the Connection is active'
            ' when connectionClosedStream emits it');
  });

  test('connectionClosedStream closes only once every side\'s socket is'
      ' destroyed', () async {
    final sockets = <Socket>[];
    final started = Completer<void>();
    final connector = await SocketConnector.serverToServer(
      addressA: InternetAddress.loopbackIPv4,
      addressB: InternetAddress.loopbackIPv4,
      closeFlushTimeout: testCloseFlushTimeout,
      socketAuthVerifierA: (socket) {
        sockets.add(socket);
        _setSendBuffer(socket);
        socket.add(Uint8List(8 * 1024 * 1024));
        started.complete();
        return Completer<(bool, Stream<Uint8List>?)>().future;
      },
    );
    addTearDown(connector.close);
    bool? destroyedWhenClosed;
    final endsDone = Completer<void>();
    connector.connectionClosedStream.listen((_) {}, onDone: () {
      destroyedWhenClosed = _isDestroyed(sockets.single);
      endsDone.complete();
    });
    final peerA = await _Peer.connect(connector.sideAPort!);
    peerA.stopReading();
    await started.future.timeout(Duration(seconds: 5));

    final sinceClose = Stopwatch()..start();
    connector.close();
    await endsDone.future.timeout(testCloseFlushTimeout + slack,
        onTimeout: () => fail('connectionClosedStream closes no later than'
            ' closeFlushTimeout after close() began'));
    expect(destroyedWhenClosed, isTrue,
        reason: 'connectionClosedStream closes no earlier than that side\'s'
            ' socket is destroyed');
    expect(sinceClose.elapsed,
        greaterThan(testCloseFlushTimeout - Duration(milliseconds: 100)),
        reason: 'that side\'s pending data could not be flushed, so its close'
            ' ran to closeFlushTimeout');
  });

  test('close() logs nothing for a side it closed while authenticating',
      () async {
    final sink = _LineSink();
    final connector = SocketConnector(
        authTimeout: Duration(milliseconds: 500),
        closeFlushTimeout: testCloseFlushTimeout,
        logger: sink);
    addTearDown(connector.close);
    final (_, local) = await _socketPair();
    final started = Completer<void>();
    unawaited(connector.handleSingleConnection(
        Side(local, true, socketAuthVerifier: (socket) {
      started.complete();
      return Completer<(bool, Stream<Uint8List>?)>().future;
    })));
    await started.future.timeout(Duration(seconds: 5));
    connector.close();

    await Future<void>.delayed(Duration(milliseconds: 500) + slack);
    expect(sink.lines, isEmpty, reason: 'nothing is written to the logger');
  });

  test('An authentication that fails on an open connector is still logged',
      () async {
    final sink = _LineSink();
    final connector = SocketConnector(
        authTimeout: Duration(milliseconds: 500),
        closeFlushTimeout: testCloseFlushTimeout,
        logger: sink);
    addTearDown(connector.close);
    final (_, local) = await _socketPair();
    unawaited(connector.handleSingleConnection(Side(local, true,
        socketAuthVerifier: (socket) =>
            Completer<(bool, Stream<Uint8List>?)>().future)));

    await Future<void>.delayed(Duration(milliseconds: 500) + slack);
    expect(sink.lines.where((l) => l.contains('Authentication failed on side A')),
        hasLength(1),
        reason: '"Authentication failed on side A" is written to the logger');
  });

  test(
      'A side B connected while close() runs is destroyed without an error'
      ' line', () async {
    final sink = _LineSink();
    final destination =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(destination.close);
    final peerB = Completer<_Peer>();
    destination.listen((s) => peerB.complete(_Peer(s)));
    final joining = Completer<void>();
    final release = Completer<void>();
    final connector = await SocketConnector.serverToSocket(
      addressA: InternetAddress.loopbackIPv4,
      addressB: InternetAddress.loopbackIPv4,
      portB: destination.port,
      closeFlushTimeout: testCloseFlushTimeout,
      logger: sink,
      beforeJoining: (sideA, sideB) async {
        joining.complete();
        await release.future;
      },
    );
    addTearDown(connector.close);
    await _Peer.connect(connector.sideAPort!);
    await joining.future.timeout(Duration(seconds: 5));
    final peer = await peerB.future.timeout(Duration(seconds: 5));
    connector.close();

    release.complete();
    await peer.ended.future.timeout(testCloseFlushTimeout + slack,
        onTimeout: () => fail('side B\'s socket is destroyed'));
    await Future<void>.delayed(Duration(milliseconds: 200));
    expect(sink.lines, isEmpty, reason: 'nothing is written to the logger');
  });

  test('close() of a serverToServer connector writes nothing when verbose is'
      ' false', () async {
    final sink = _LineSink();
    final connector = await SocketConnector.serverToServer(
      addressA: InternetAddress.loopbackIPv4,
      addressB: InternetAddress.loopbackIPv4,
      logger: sink,
    );
    addTearDown(connector.close);

    connector.close();
    await Future<void>.delayed(Duration(milliseconds: 200));
    expect(sink.lines, isEmpty, reason: 'nothing is written to the logger');
  });

  test(
      'A side whose socket fails to destroy is still reported, and its far'
      ' side still closes', () async {
    final sink = _LineSink();
    final connector =
        SocketConnector(closeFlushTimeout: testCloseFlushTimeout, logger: sink);
    addTearDown(connector.close);
    final ends = <_End>[];
    final endsDone = Completer<void>();
    connector.connectionClosedStream
        .listen((c) => ends.add(_End(c)), onDone: endsDone.complete);
    final established = connector.connectionStream.first;
    final (peerA, localA) = await _socketPair();
    final (_, localB) = await _socketPair();
    unawaited(connector.handleSingleConnection(
        Side(_DestroyThrows(localA), true)));
    unawaited(connector.handleSingleConnection(Side(localB, false)));
    final Connection c = await established.timeout(Duration(seconds: 5));

    final sinceClose = Stopwatch()..start();
    unawaited(peerA.socket.close());
    await _expectDestroyedWithin(
        [c.sideB], sinceClose, testCloseFlushTimeout + slack,
        reason: 'side B is destroyed no later than closeFlushTimeout after'
            ' side A\'s close began');
    expect(c.sideA.closedAt, isNotNull, reason: 'side A\'s closedAt is set');
    connector.close();
    await endsDone.future.timeout(slack);
    expect(ends.map((e) => e.connection), [same(c)],
        reason: 'connectionClosedStream emits the Connection once');
    expect(sink.lines.where((l) => l.contains(_DestroyThrows.failure)),
        hasLength(1),
        reason: 'the failure is written to the logger');
  });
}

/// A connected pair: a [_Peer] at one end and the socket accepted for it.
Future<(_Peer, Socket)> _socketPair() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(server.close);
  final accepted = server.first;
  final peer = await _Peer.connect(server.port);
  final Socket local = await accepted;
  _ignoreSinkErrors(local);
  addTearDown(local.destroy);
  return (peer, local);
}

/// An [IOSink] that keeps every line written to it, calling [onLine] as each
/// is written.
class _LineSink implements IOSink {
  _LineSink({this.onLine});

  final void Function(String line)? onLine;
  final List<String> lines = [];

  @override
  void writeln([Object? object = '']) {
    final String line = '$object';
    lines.add(line);
    onLine?.call(line);
  }

  @override
  void write(Object? object) => writeln(object);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// A [Socket] whose [destroy] destroys the socket it wraps, then throws.
class _DestroyThrows extends StreamView<Uint8List> implements Socket {
  _DestroyThrows(this._inner) : super(_inner);

  static const String failure = 'destroy failed';

  final Socket _inner;

  @override
  void destroy() {
    _inner.destroy();
    throw StateError(failure);
  }

  @override
  void add(List<int> data) => _inner.add(data);

  @override
  Future flush() => _inner.flush();

  @override
  Future get done => _inner.done;

  @override
  void setRawOption(RawSocketOption option) => _inner.setRawOption(option);

  @override
  InternetAddress get remoteAddress => _inner.remoteAddress;

  @override
  int get remotePort => _inner.remotePort;

  @override
  int get port => _inner.port;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Relays [sent] bytes from peer A through [_slowTransform], on a [SocketConnector.serverToSocket] whose grace period has
/// passed, then closes peer A and returns peer B once its stream has ended.
Future<(_Peer, SocketConnector)> _transformerTail(
    {required int sent,
    Duration closeFlushTimeout =
        SocketConnector.defaultCloseFlushTimeout}) async {
  final destination = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(destination.close);
  final peerB = Completer<_Peer>();
  destination.listen((s) => peerB.complete(_Peer(s)));
  final connector = await SocketConnector.serverToSocket(
    addressA: InternetAddress.loopbackIPv4,
    addressB: InternetAddress.loopbackIPv4,
    portB: destination.port,
    timeout: Duration(milliseconds: 200),
    closeFlushTimeout: closeFlushTimeout,
    transformAtoB: _slowTransform,
  );
  addTearDown(connector.close);
  final peerA = await _Peer.connect(connector.sideAPort!);
  final peer = await peerB.future.timeout(Duration(seconds: 5));
  await _waitFor(() => connector.gracePeriodPassed, 'the grace period');

  peerA.send(sent);
  unawaited(peerA.socket.close());
  await peer.ended.future.timeout(Duration(seconds: 30),
      onTimeout: () => fail('the relay never closed side B'));
  return (peer, connector);
}

/// Passes each chunk on 5 ms after the one before it, forwarding pauses but
/// reading on while its output is queued.
Stream<List<int>> _slowTransform(Stream<List<int>> source) {
  late StreamSubscription<List<int>> subscription;
  late final StreamController<List<int>> output;
  Future<void> queue = Future<void>.value();
  output = StreamController<List<int>>(
    onListen: () {
      subscription = source.listen((data) {
        queue = queue.then((_) async {
          await Future<void>.delayed(Duration(milliseconds: 5));
          output.add(data);
        });
      }, onDone: () => queue.then((_) => output.close()));
    },
    onPause: () => subscription.pause(),
    onResume: () => subscription.resume(),
    onCancel: () => subscription.cancel(),
  );
  return output.stream;
}

/// A paired [Connection] on a loopback [SocketConnector.serverToServer], with
/// the two peers that connected to it.
class _Relay {
  _Relay(this.connector, this.connection, this.peerA, this.peerB, this.ends,
      this._endsDone);

  final SocketConnector connector;
  final Connection connection;
  final _Peer peerA;
  final _Peer peerB;

  /// Every end emitted on [SocketConnector.connectionClosedStream] so far.
  final List<_End> ends;
  final Future<void> _endsDone;

  static Future<_Relay> start(
      {Duration closeFlushTimeout = testCloseFlushTimeout,
      Duration stalledFlushTimeout =
          SocketConnector.defaultStalledFlushTimeout}) async {
    final connector = await SocketConnector.serverToServer(
      addressA: InternetAddress.loopbackIPv4,
      addressB: InternetAddress.loopbackIPv4,
      closeFlushTimeout: closeFlushTimeout,
      stalledFlushTimeout: stalledFlushTimeout,
    );
    addTearDown(connector.close);
    final ends = <_End>[];
    final endsDone = Completer<void>();
    connector.connectionClosedStream
        .listen((c) => ends.add(_End(c)), onDone: endsDone.complete);
    final established = connector.connectionStream.first;
    final peerA = await _Peer.connect(connector.sideAPort!);
    final peerB = await _Peer.connect(connector.sideBPort!);
    final connection = await established.timeout(Duration(seconds: 5));
    return _Relay(connector, connection, peerA, peerB, ends, endsDone.future);
  }

  /// Closes the connector and returns every end it emitted, once its
  /// [SocketConnector.connectionClosedStream] is done or the bound has passed.
  Future<List<_End>> allEnds() async {
    connector.close();
    endsClosed = await _endsDone
        .then((_) => true)
        .timeout(testCloseFlushTimeout + slack, onTimeout: () => false);
    return ends;
  }

  /// Whether [SocketConnector.connectionClosedStream] was done when
  /// [allEnds] returned.
  bool endsClosed = false;

  /// Whether [SocketConnector.connectionClosedStream] is done within [within],
  /// without closing the connector.
  Future<bool> endsClosedWithin(Duration within) =>
      _endsDone.then((_) => true).timeout(within, onTimeout: () => false);
}

/// A [Connection] as it was when [SocketConnector.connectionClosedStream]
/// emitted it.
class _End {
  _End(this.connection)
      : sidesDestroyed = _isDestroyed(connection.sideA.socket) &&
            _isDestroyed(connection.sideB.socket),
        closedAtSet = connection.sideA.closedAt != null &&
            connection.sideB.closedAt != null,
        rcvdA = connection.sideA.rcvd,
        rcvdB = connection.sideB.rcvd;

  final Connection connection;
  final bool sidesDestroyed;
  final bool closedAtSet;
  final int rcvdA;
  final int rcvdB;
}

/// One end of a TCP connection to a relay port, counting what it receives.
class _Peer {
  _Peer(this.socket) {
    _ignoreSinkErrors(socket);
    _subscription = socket.listen((data) => received += data.length,
        onError: (Object _) => _end(), onDone: _end);
    addTearDown(() {
      socket.destroy();
    });
  }

  final Socket socket;
  late final StreamSubscription<Uint8List> _subscription;

  /// Bytes this peer has read from its socket.
  int received = 0;

  /// Bytes this peer has written to its socket.
  int sent = 0;

  /// Completes when this peer's socket reports end of stream or an error.
  final Completer<void> ended = Completer<void>();

  static Future<_Peer> connect(int port) async =>
      _Peer(await Socket.connect(InternetAddress.loopbackIPv4, port));

  void _end() {
    if (!ended.isCompleted) {
      ended.complete();
    }
  }

  void stopReading() => _subscription.pause();

  void resumeReading() => _subscription.resume();

  /// Reads for half of every 6 ms until the test ends.
  void readInBursts() {
    final Timer bursts = Timer.periodic(Duration(milliseconds: 6), (_) {
      _subscription.pause();
      Timer(Duration(milliseconds: 3), _subscription.resume);
    });
    addTearDown(bursts.cancel);
  }

  /// Writes [count] zero bytes.
  void send(int count) {
    socket.add(Uint8List(count));
    sent += count;
  }
}

/// Whether [socket] has been destroyed.
///
/// `Socket.port` throws [SocketException.closed] once `destroy()` has run, and
/// only then; the first test in this file pins that against a peer's close and
/// a peer's reset.
bool _isDestroyed(Socket socket) {
  try {
    socket.port;
    return false;
  } on SocketException catch (e) {
    if (e.message == 'Socket has been closed' && e.osError == null) {
      return true;
    }
    rethrow;
  }
}

/// Fails with [reason] unless every one of [sides] has its socket destroyed
/// within [window] of [since] starting.
Future<void> _expectDestroyedWithin(
    List<Side> sides, Stopwatch since, Duration window,
    {required String reason}) async {
  bool allDestroyed() => sides.every((s) => _isDestroyed(s.socket));
  while (!allDestroyed() && since.elapsed < window) {
    await Future<void>.delayed(Duration(milliseconds: 5));
  }
  final String states = [
    for (final s in sides)
      'side ${s.name} state ${s.state.name}'
          '${_isDestroyed(s.socket) ? ', destroyed' : ', not destroyed'}'
  ].join('; ');
  expect(allDestroyed(), isTrue,
      reason: '$reason (after ${since.elapsedMilliseconds} ms: $states)');
}

/// Waits up to [within] for [condition], failing with [what] if it never
/// holds.
Future<void> _waitFor(bool Function() condition, String what,
    {Duration within = const Duration(seconds: 10)}) async {
  final deadline = Stopwatch()..start();
  while (!condition()) {
    if (deadline.elapsed > within) {
      fail('timed out waiting for $what');
    }
    await Future<void>.delayed(Duration(milliseconds: 5));
  }
}

/// Waits up to 10 s for [read] to stop changing for 300 ms.
Future<void> _waitForSteady(int Function() read, String what) async {
  final deadline = Stopwatch()..start();
  final steady = Stopwatch()..start();
  int last = read();
  while (steady.elapsed < Duration(milliseconds: 300)) {
    if (deadline.elapsed > Duration(seconds: 10)) {
      fail('timed out waiting for $what');
    }
    await Future<void>.delayed(Duration(milliseconds: 20));
    final int now = read();
    if (now != last) {
      last = now;
      steady.reset();
    }
  }
}

/// Binds [socket]'s sink until the returned controller is closed, as a flush
/// that cannot finish does.
StreamController<List<int>> _bindSink(Socket socket) {
  final holder = StreamController<List<int>>();
  unawaited(socket.addStream(holder.stream).catchError((Object e) => e));
  return holder;
}

void _ignoreSinkErrors(Socket socket) {
  unawaited(socket.done.then((_) {}, onError: (Object _) {}));
}

/// Shrinks [receiver]'s receive buffer and [sender]'s send buffer to 16 KiB.
void _setBufferSizes(Socket receiver, Socket sender) {
  final int level = Platform.isMacOS ? 0xffff : 1;
  final int receiveBuffer = Platform.isMacOS ? 0x1002 : 8;
  receiver.setRawOption(RawSocketOption.fromInt(level, receiveBuffer, 16384));
  _setSendBuffer(sender);
}

/// Shrinks [sender]'s send buffer to 16 KiB.
void _setSendBuffer(Socket sender) {
  final int level = Platform.isMacOS ? 0xffff : 1;
  final int sendBuffer = Platform.isMacOS ? 0x1001 : 7;
  sender.setRawOption(RawSocketOption.fromInt(level, sendBuffer, 16384));
}

/// Makes [socket]'s `destroy()` send a reset rather than a FIN.
void _setLingerZero(Socket socket) {
  final int level = Platform.isMacOS ? 0xffff : 1;
  final int option = Platform.isMacOS ? 0x0080 : 13;
  socket.setRawOption(RawSocketOption(
      level, option, Uint8List.fromList([1, 0, 0, 0, 0, 0, 0, 0])));
}
