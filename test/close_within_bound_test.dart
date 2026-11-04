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
    final bare = SocketConnector();
    addTearDown(bare.close);
    expect(bare.closeFlushTimeout, SocketConnector.defaultCloseFlushTimeout);

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
      final SocketConnector connector = switch (factory) {
        'serverToServer' => bound == null
            ? await SocketConnector.serverToServer(
                addressA: loopback, addressB: loopback)
            : await SocketConnector.serverToServer(
                addressA: loopback,
                addressB: loopback,
                closeFlushTimeout: closeFlushTimeout),
        'serverToSocket' => bound == null
            ? await SocketConnector.serverToSocket(
                addressA: loopback, addressB: loopback, portB: server.port)
            : await SocketConnector.serverToSocket(
                addressA: loopback,
                addressB: loopback,
                portB: server.port,
                closeFlushTimeout: closeFlushTimeout),
        'socketToServer' => bound == null
            ? await SocketConnector.socketToServer(
                addressA: loopback, portA: server.port, addressB: loopback)
            : await SocketConnector.socketToServer(
                addressA: loopback,
                portA: server.port,
                addressB: loopback,
                closeFlushTimeout: closeFlushTimeout),
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
                closeFlushTimeout: closeFlushTimeout),
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
      expect((await build(null, factory)).closeFlushTimeout,
          SocketConnector.defaultCloseFlushTimeout,
          reason: '$factory defaults closeFlushTimeout to 30 seconds');
      expect((await build(chosen, factory)).closeFlushTimeout, chosen,
          reason: '$factory passes closeFlushTimeout to its connector');
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
      relay.connector.close();

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

  group('A reset while the relay\'s read is paused still closes both sides',
      () {
    /// Pauses the relay's read of side A behind its flush of side B, hands
    /// side A [towardsA] bytes that peer A is not reading, resets peer A, and
    /// expects both sides destroyed within the bound.
    Future<void> expectBothClosedAfterReset(int towardsA,
        {bool holdSideB = false}) async {
      final int written = holdSideB ? 64 * 1024 : 32 * 1024 * 1024;
      final relay = await _Relay.start();
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

  test('A peer that is reading receives the tail before its side is destroyed',
      () async {
    // Raised so the relay reads all of peer A's data, and side B's close
    // begins with all of it still queued in the relay.
    SocketConnector.bufferHighWaterMark = 64 * 1024 * 1024;
    const int queued = 32 * 1024 * 1024;
    final relay = await _Relay.start(closeFlushTimeout: Duration(seconds: 10));
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
      {Duration closeFlushTimeout = testCloseFlushTimeout}) async {
    final connector = await SocketConnector.serverToServer(
      addressA: InternetAddress.loopbackIPv4,
      addressB: InternetAddress.loopbackIPv4,
      closeFlushTimeout: closeFlushTimeout,
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
  final int sendBuffer = Platform.isMacOS ? 0x1001 : 7;
  final int receiveBuffer = Platform.isMacOS ? 0x1002 : 8;
  receiver.setRawOption(RawSocketOption.fromInt(level, receiveBuffer, 16384));
  sender.setRawOption(RawSocketOption.fromInt(level, sendBuffer, 16384));
}

/// Makes [socket]'s `destroy()` send a reset rather than a FIN.
void _setLingerZero(Socket socket) {
  final int level = Platform.isMacOS ? 0xffff : 1;
  final int option = Platform.isMacOS ? 0x0080 : 13;
  socket.setRawOption(RawSocketOption(
      level, option, Uint8List.fromList([1, 0, 0, 0, 0, 0, 0, 0])));
}
