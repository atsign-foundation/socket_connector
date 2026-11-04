import 'dart:async';
import 'dart:io';
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
  });

  test('A reset while the relay\'s read is paused still closes both sides',
      () async {
    const int written = 32 * 1024 * 1024;
    // Below the high-water mark, so no flush of side A is in flight, but far
    // more than side A's shrunken socket buffers hold, so a write to it is.
    const int towardsA = 2 * 1024 * 1024;
    final relay = await _Relay.start();
    _setBufferSizes(relay.peerA.socket, relay.connection.sideA.socket);
    relay.peerA.stopReading();
    relay.peerB.stopReading();

    relay.peerA.socket.add(Uint8List(written));
    await _waitForSteady(() => relay.connection.sideA.rcvd,
        'the relay to stop reading side A while side B flushes');
    expect(relay.connection.sideA.rcvd, lessThan(written),
        reason: 'the relay\'s read of side A is paused by backpressure');

    relay.peerB.socket.add(Uint8List(towardsA));
    await _waitFor(() => relay.connection.sideA.sent == towardsA,
        'side A to be handed all $towardsA bytes');

    _setLingerZero(relay.peerA.socket);
    final sinceReset = Stopwatch()..start();
    relay.peerA.socket.destroy();

    await _expectDestroyedWithin(
        [relay.connection.sideA, relay.connection.sideB],
        sinceReset,
        testCloseFlushTimeout + slack,
        reason: 'both sides are destroyed no later than closeFlushTimeout'
            ' after the reset is seen');
  }, testOn: 'mac-os || linux');

  test('A peer that is reading receives the tail before its side is destroyed',
      () async {
    const int queued = 32 * 1024 * 1024;
    final relay = await _Relay.start();
    relay.peerB.readInBursts();

    relay.peerA.socket.add(Uint8List(queued));
    unawaited(relay.peerA.socket.close());

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
  _Relay(this.connector, this.connection, this.peerA, this.peerB);

  final SocketConnector connector;
  final Connection connection;
  final _Peer peerA;
  final _Peer peerB;

  static Future<_Relay> start() async {
    final connector = await SocketConnector.serverToServer(
      addressA: InternetAddress.loopbackIPv4,
      addressB: InternetAddress.loopbackIPv4,
    );
    addTearDown(connector.close);
    final established = connector.connectionStream.first;
    final peerA = await _Peer.connect(connector.sideAPort!);
    final peerB = await _Peer.connect(connector.sideBPort!);
    final connection = await established.timeout(Duration(seconds: 5));
    return _Relay(connector, connection, peerA, peerB);
  }
}

/// One end of a TCP connection to a relay port, counting what it receives.
class _Peer {
  _Peer(this.socket) {
    _ignoreSinkErrors(socket);
    _subscription = socket.listen((data) => received += data.length,
        onError: (Object _) => _end(), onDone: _end);
    addTearDown(() {
      _bursts?.cancel();
      socket.destroy();
    });
  }

  final Socket socket;
  late final StreamSubscription<Uint8List> _subscription;
  Timer? _bursts;

  /// Bytes this peer has read from its socket.
  int received = 0;

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

  /// Reads for half of every 6 ms, so the relay keeps data queued for it.
  void readInBursts() {
    _bursts = Timer.periodic(Duration(milliseconds: 6), (_) {
      _subscription.pause();
      Timer(Duration(milliseconds: 3), _subscription.resume);
    });
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

/// Waits up to 10 s for [condition], failing with [what] if it never holds.
Future<void> _waitFor(bool Function() condition, String what) async {
  final deadline = Stopwatch()..start();
  while (!condition()) {
    if (deadline.elapsed > Duration(seconds: 10)) {
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
