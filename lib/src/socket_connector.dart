import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:chalkdart/chalk.dart';
import 'package:mutex/mutex.dart';
import 'package:socket_connector/src/types.dart';

/// Relays data between two TCP sockets - a "side A" and a "side B".
///
/// Typical usage is via the [serverToServer], [serverToSocket],
/// [socketToSocket] and [socketToServer] factory methods, which are different
/// flavours of the same functionality - to relay information from one socket to
/// another. Each side is either a server (something connects *to* it) or a
/// client (it connects *out*); the four factories cover every combination.
///
/// - [timeout] sets a grace period that starts at construction. A one-shot
///   [Timer] fires when it elapses (see [gracePeriodPassed]): if no
///   [Connection] is established by then, [close] is called. Until the grace
///   period elapses the connector stays open even with zero [connections],
///   giving clients time to connect.
/// - Once the grace period has elapsed, [close] is called as soon as the last
///   established [Connection] closes (i.e. [connections] becomes empty).
/// - New [Connection]s are added to [connections] when both [pendingA] and
///   [pendingB] have at least one entry.
/// - Each socket is given TCP keep-alive settings as it is accepted or created,
///   per [keepAlive] (defaults to [SocketKeepAlive.defaults]).
/// - When [verbose] is true, log messages are logged to [logger].
/// - When [logTraffic] is true, socket traffic is logged to [logger].
/// - [connectionStream] emits each new [Connection]; [done] completes when the
///   connector closes; [stats] accumulates per-session counters.
/// - [connectionClosedStream] emits each [Connection] once both of its sides
///   have been destroyed. No side waits longer than [closeFlushTimeout] for
///   its pending data to be flushed before it is destroyed.
/// - A relay flush toward a side that has not completed within
///   [stalledFlushTimeout] closes its [Connection]. A relay flush begins once
///   [bufferHighWaterMark] bytes have been written toward a side since its
///   last flush, or one second after the first of them.
class SocketConnector {
  static const defaultTimeout = Duration(seconds: 30);

  /// The default for [closeFlushTimeout].
  static const defaultCloseFlushTimeout = Duration(seconds: 30);

  /// The default for [stalledFlushTimeout].
  static const defaultStalledFlushTimeout = Duration(minutes: 2);

  /// Backpressure high-water mark, in bytes, per relay direction.
  ///
  /// [Socket.add] never blocks: when the OS send buffer is full, bytes queue
  /// in process memory without limit. Once more than this many bytes have
  /// been added to a far-side socket without confirmation that the OS has
  /// accepted them, the connector stops reading from the source socket until
  /// [Socket.flush] completes. The source socket's kernel receive buffer then
  /// fills and TCP closes the window, so a fast writer is throttled to the
  /// speed of the slowest link instead of inflating this process's memory.
  static int bufferHighWaterMark = 4 * 1024 * 1024;

  bool _gracePeriodPassed = false;

  /// Whether the [timeout] grace period has elapsed. While false, the connector
  /// will not auto-close when [connections] is empty; once true, it closes as
  /// soon as [connections] becomes empty.
  bool get gracePeriodPassed => _gracePeriodPassed;

  final StreamController<Connection> _csc =
      StreamController<Connection>.broadcast();

  /// Emits each new [Connection] as it is established.
  Stream<Connection> get connectionStream => _csc.stream;

  final StreamController<Connection> _closedConnections =
      StreamController<Connection>.broadcast();

  /// Emits each established [Connection] once, after both of its sides have
  /// been destroyed.
  ///
  /// Closes once the connector is [closed] and the socket of every side it
  /// has handled has been destroyed.
  Stream<Connection> get connectionClosedStream => _closedConnections.stream;

  /// Connections removed from [connections] whose end is not yet emitted on
  /// [connectionClosedStream].
  final Set<Connection> _endingConnections = {};

  /// Every side handed to [handleSingleConnection] whose socket is not yet
  /// destroyed.
  final Set<Side> _sides = {};

  /// Measures every close deadline, unaffected by wall-clock changes.
  final Stopwatch _clock = Stopwatch()..start();

  /// Far sides whose close is due by a deadline on [_clock], each with the
  /// timer that begins its close then.
  final Map<Side, ({Duration deadline, Timer timer})> _farSideCloses = {};

  /// Sides whose authentication has not yet ended.
  final Set<Side> _authenticating = {};

  /// The gate that relay writes toward each paired side go through, by that
  /// side.
  final Map<Side, _FlushGate> _gates = {};

  Timer? _timeoutTimer;

  SocketConnector({
    this.verbose = false,
    this.logTraffic = false,
    this.timeout = defaultTimeout,
    this.authTimeout = defaultTimeout,
    this.keepAlive = SocketKeepAlive.defaults,
    this.closeFlushTimeout = defaultCloseFlushTimeout,
    this.stalledFlushTimeout = defaultStalledFlushTimeout,
    IOSink? logger,
  }) {
    if (closeFlushTimeout.isNegative) {
      throw ArgumentError.value(
          closeFlushTimeout, 'closeFlushTimeout', 'must not be negative');
    }
    if (stalledFlushTimeout <= Duration.zero) {
      throw ArgumentError.value(
          stalledFlushTimeout, 'stalledFlushTimeout', 'must be positive');
    }
    this.logger = logger ?? stderr;
    _timeoutTimer = Timer(timeout, () {
      _gracePeriodPassed = true;
      if (connections.isEmpty) {
        _close(closeEnding: false);
      }
    });
  }

  /// Where we will write anything we want to log. Defaults to stderr
  late IOSink logger;

  /// When true, log messages will be logged to [logger]
  bool verbose;

  /// When true, socket traffic will be logged to [logger]
  bool logTraffic;

  /// The grace period, starting at construction, during which the connector
  /// waits for connections without auto-closing. A one-shot [Timer] fires when
  /// it elapses and calls [close] if no [Connection] is then established;
  /// thereafter [close] is called whenever [connections] becomes empty.
  /// See [gracePeriodPassed].
  final Duration timeout;

  /// The established [Connection]s
  final List<Connection> connections = [];

  final Stats stats = Stats();

  /// A [Side]s which are available for pairing with the next B side connections
  final List<Side> pendingA = [];

  /// B [Side]s which are available for pairing with the next A side connections
  final List<Side> pendingB = [];

  /// Completes when the connector closes ([close] is called). That happens
  /// when:
  /// 1. the [timeout] grace period elapses with no established [Connection], or
  /// 2. the last established [Connection] closes after the grace period has
  ///    elapsed (see [gracePeriodPassed]), or
  /// 3. [close] is called explicitly.
  ///
  /// A side's socket can still be open when [done] completes, for up to
  /// [closeFlushTimeout] while its pending data is flushed;
  /// [connectionClosedStream] closes once every socket has been destroyed.
  Future get done => _closedCompleter.future;

  /// Whether this SocketConnector is closed or not
  bool get closed => _closedCompleter.isCompleted;

  /// Returns the TCP port number of [_serverSocketA] if any
  int? get sideAPort => _serverSocketA?.port;

  /// Returns the TCP port number of [_serverSocketB] if any
  int? get sideBPort => _serverSocketB?.port;

  /// The [ServerSocket] on side 'A', if any
  ServerSocket? _serverSocketA;

  /// The [ServerSocket] on side 'B', if any
  ServerSocket? _serverSocketB;

  final Completer _closedCompleter = Completer();

  /// How long to wait for a client to authenticate its self
  final Duration authTimeout;

  /// TCP keep-alive settings applied to every socket this connector accepts
  /// or creates. Defaults to [SocketKeepAlive.defaults].
  final SocketKeepAlive keepAlive;

  /// The longest a side waits, once its close begins, for its pending data
  /// to be flushed before its socket is destroyed regardless.
  ///
  /// A side whose far side has closed begins its own close then, even while
  /// data for it is still on its way through the relay. Zero destroys a side
  /// without waiting for its flush; a negative value is refused.
  final Duration closeFlushTimeout;

  /// The longest a relay flush toward a side may take; a flush that has not
  /// completed by then closes its [Connection].
  ///
  /// A relay flush begins once [bufferHighWaterMark] bytes have been written
  /// toward a side since its last flush, or one second after the first of
  /// them. Zero or a negative value is refused.
  final Duration stalledFlushTimeout;

  /// Brings [thisSide] under management: applies [keepAlive] to its socket,
  /// optionally authenticates it, and pairs it with a [Side] from the opposite
  /// side to form a [Connection].
  ///
  /// - [keepAlive] is applied to `thisSide.socket` first, so it takes effect
  ///   even while authentication is in progress.
  /// - If `thisSide.socketAuthVerifier` is set, the socket must authenticate
  ///   within [authTimeout] before any data is relayed; on failure the side is
  ///   closed.
  /// - Once authenticated, the side is added to [pendingA] or [pendingB]; when
  ///   both have an entry a [Connection] is formed and emitted on
  ///   [connectionStream]. Data from each side is rewritten by that side's
  ///   `transformer` (if any) before being written to the far side.
  ///
  /// Throws [StateError], after destroying [thisSide]'s socket, if the
  /// connector is already [closed]. A side whose authentication ends after
  /// the connector closes is closed, not paired.
  Future<void> handleSingleConnection(final Side thisSide) async {
    if (closed) {
      thisSide.socket.destroy();
      throw StateError('Connector is closed');
    }
    _sides.add(thisSide);
    // Apply TCP keep-alive to every socket as it is accepted or created. Every
    // Side - whether from an inbound accept or an outbound connect - funnels
    // through here, so this is the single place keep-alive needs to be set.
    keepAlive.applyTo(thisSide.socket, onError: (m) => _log(m, force: true));
    unawaited(thisSide.socket.done.then((_) => _closeSide(thisSide),
        onError: (Object _) => _closeSide(thisSide, failed: true)));
    if (thisSide.socketAuthVerifier == null) {
      thisSide.authenticated = true;
    } else {
      bool authenticated;
      Stream<Uint8List>? stream;
      _authenticating.add(thisSide);
      try {
        (authenticated, stream) = await thisSide.socketAuthVerifier!
                (thisSide.socket)
            .timeout(authTimeout);
        thisSide.authenticated = authenticated;
        if (thisSide.authenticated) {
          thisSide.stream = stream!;
          _log('Authentication succeeded on side ${thisSide.name}');
        }
      } catch (e) {
        thisSide.authenticated = false;
        _log('Error while authenticating side ${thisSide.name} : $e',
            force: !closed);
      } finally {
        _authenticating.remove(thisSide);
      }
    }
    if (!thisSide.authenticated) {
      _log('Authentication failed on side ${thisSide.name}', force: !closed);
      _closeSide(thisSide);
      return;
    }

    if (thisSide.state == SideState.closed) {
      return;
    }
    if (closed) {
      _closeSide(thisSide);
      return;
    }

    if (thisSide.isSideA) {
      pendingA.add(thisSide);
    } else {
      pendingB.add(thisSide);
    }

    if (pendingA.isNotEmpty && pendingB.isNotEmpty) {
      Connection c = Connection(pendingA.removeAt(0), pendingB.removeAt(0));
      connections.add(c);
      if (!_csc.isClosed) {
        _csc.add(c);
      }
      stats.socketsSideA.putIfAbsent(c.sideA.remoteHost, () => []);
      stats.socketsSideA[c.sideA.remoteHost]!
          .add(PortAndTimestamp(c.sideA.remotePort, c.sideA.timestamp));

      stats.socketsSideB.putIfAbsent(c.sideB.remoteHost, () => []);
      stats.socketsSideB[c.sideB.remoteHost]!
          .add(PortAndTimestamp(c.sideB.remotePort, c.sideB.timestamp));
      stats.numSocketPairs++;
      _log(chalk.brightBlue(
          'Added connection. There are now ${connections.length} connections.'));

      for (final side in [thisSide, thisSide.farSide!]) {
        // Backpressure: reading from this side is paused once more than
        // [bufferHighWaterMark] bytes are queued on the far socket, and
        // resumes when flush() reports the queue has drained. A [_FlushGate]
        // owns the write-plus-flush so no add() can ever race a flush (see
        // its doc comment for why a plain pause() is not enough).
        late final StreamSubscription<Uint8List> sourceSub;

        void onWriteError(Object e, StackTrace st) {
          _log('Failed to write to side ${side.farSide!.name} - closing',
              force: true);
          _log('(Error was $e; Stack trace follows\n$st', force: true);
          _closeSide(side.farSide!);
        }

        void onStall() {
          _log(
              'A flush toward side ${side.farSide!.name} did not complete'
              ' within $stalledFlushTimeout - closing',
              force: true);
          _closeSide(side.farSide!);
          _closeSide(side);
        }

        if (side.chunkTransformer == null && side.transformer != null) {
          // transformer is there to transform data originating FROM its side
          // transformer's output will write to the SOCKET on the far side
          //
          // A pause on the transformed stream's subscription propagates to
          // sc.stream provided the transformer forwards pauses (stream.map
          // and friends do); onPause/onResume extend it to the source socket
          // subscription, which is what makes TCP throttle the sender.
          StreamController<Uint8List> sc = StreamController<Uint8List>(
            onPause: () => sourceSub.pause(),
            onResume: () => sourceSub.resume(),
          );
          side.farSide!.sink = sc;
          Stream<List<int>> transformed = side.transformer!(sc.stream);
          late final StreamSubscription<List<int>> transformedSub;
          final _FlushGate gate = _FlushGate(
            socket: side.farSide!.socket,
            pause: () => transformedSub.pause(),
            resume: () => transformedSub.resume(),
            onError: onWriteError,
            stallTimeout: stalledFlushTimeout,
            onStall: onStall,
            write: (List<int> data) {
              side.farSide!.socket.add(data);
              if (side.isSideA) {
                stats.bytesAtoB += data.length;
              } else {
                stats.bytesBtoA += data.length;
              }
              side.farSide!.sent += data.length;
              if (side.state == SideState.closed &&
                  side.produced == side.farSide!.sent) {
                _closeSide(side.farSide!);
              }
            },
          );
          _gates[side.farSide!] = gate;
          transformedSub = transformed.listen(
            gate.add,
            onDone: () => _closeSide(side),
            onError: (error) => _closeSide(side),
          );
        }

        // On the direct (no-transformer) path the sink IS the far socket, so a
        // gate manages its backpressure. With a transformer the sink is the
        // controller above and backpressure is handled there, so no gate here.
        _FlushGate? directGate;
        if (side.farSide!.sink is Socket) {
          directGate = _FlushGate(
            socket: side.farSide!.sink as Socket,
            pause: () => sourceSub.pause(),
            resume: () => sourceSub.resume(),
            onError: onWriteError,
            stallTimeout: stalledFlushTimeout,
            onStall: onStall,
            // A ChunkTransformer may hand back a view over memory it reuses,
            // and the write below retains it past this callback.
            copyBeforeWrite: () => side.chunkTransformer != null,
            write: (List<int> data) {
              side.farSide!.sink.add(data);
              if (side.isSideA) {
                stats.bytesAtoB += data.length;
              } else {
                stats.bytesBtoA += data.length;
              }
              side.farSide!.sent += data.length;
              if (side.state == SideState.closed &&
                  side.produced == side.farSide!.sent) {
                _closeSide(side.farSide!);
              }
            },
          );
          _gates[side.farSide!] = directGate;
        }

        sourceSub = side.stream.listen((Uint8List data) {
          side.rcvd += data.length;
          if (logTraffic) {
            final message = String.fromCharCodes(data);
            if (side.isSideA) {
              _log(chalk.brightGreen(
                  'A -> B : ${message.replaceAll(RegExp('[\x00-\x1F\x7F-\xFF]'), '*')}'));
            } else {
              _log(chalk.brightRed(
                  'B -> A : ${message.replaceAll(RegExp('[\x00-\x1F\x7F-\xFF]'), '*')}'));
            }
          }
          if (directGate != null) {
            // A ChunkTransformer runs inline here, ahead of the write it
            // gates: if it throws, `data` is never written and the catch
            // below closes the far side, exactly like a failed socket write.
            try {
              final List<int> outData = side.chunkTransformer != null
                  ? side.chunkTransformer!.transform(data)
                  : data;
              side.produced += outData.length;
              directGate.add(outData);
            } catch (e, st) {
              onWriteError(e, st);
            }
          } else {
            // Sink is the transformer's controller; a plain add, since the
            // controller's onPause wiring already carries backpressure back to
            // this subscription.
            try {
              // The DataTransformer runs downstream of this add, so its
              // output length is not known here; count the input, which is
              // what the far side's `sent` matched before `produced` existed.
              side.produced += data.length;
              side.farSide!.sink.add(data);
              if (side.isSideA) {
                stats.bytesAtoB += data.length;
              } else {
                stats.bytesBtoA += data.length;
              }
            } catch (e, st) {
              onWriteError(e, st);
            }
          }
        }, onDone: () {
          _log('${side.stream.runtimeType}.onDone on side ${side.name}');
          _closeSide(side);
        }, onError: (error) {
          _log(
              '${side.stream.runtimeType}.onError on side ${side.name}: $error',
              force: true);
          _closeSide(side);
        });
      }
    }
  }

  /// The longest [_flushBeforeDestroy] waits for another flush to clear,
  /// within the close's own deadline.
  static const Duration _boundSinkWait = Duration(seconds: 5);

  /// Flushes [socket], waiting out any flush already in flight on it, and
  /// throws [TimeoutException] if that has not finished by [deadline] on
  /// [_clock].
  ///
  /// NOTE: [Socket.flush] throws synchronously while the sink is bound, so a
  /// close landing during the relay's own flush has to retry. Destroying
  /// straight away instead would drop whatever is still queued.
  Future<void> _flushBeforeDestroy(Socket socket, Duration deadline) async {
    final Duration boundDeadline = _clock.elapsed + _boundSinkWait;
    while (true) {
      final Duration remaining = deadline - _clock.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('close deadline reached before the flush');
      }
      try {
        await socket.flush().timeout(remaining);
        return;
      } on StateError catch (e) {
        if (!_isSinkBound(e) || _clock.elapsed > boundDeadline) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }
  }

  /// Closes [side]: flushes its pending data, unless its socket has [failed],
  /// destroys its socket, then closes its far side.
  ///
  /// Every step finishes by the side's close deadline: [closeFlushTimeout]
  /// from now, or the earlier one [_closeFarSide] set for it.
  // ignore: strict_top_level_inference
  _closeSide(final Side side, {bool failed = false}) async {
    if (side.state != SideState.open) {
      return;
    }
    side.state = SideState.closed;
    final farSideClose = _farSideCloses.remove(side);
    farSideClose?.timer.cancel();
    final Duration deadline =
        farSideClose?.deadline ?? _clock.elapsed + closeFlushTimeout;
    pendingA.remove(side);
    pendingB.remove(side);

    _log(chalk.brightBlue(
        '_closeSide ${side.name}: RCVD: ${side.rcvd} bytes; SENT: ${side.sent} bytes'));

    Connection? connectionToRemove;
    for (final c in connections) {
      if (c.sideA == side || c.sideB == side) {
        _log(chalk.brightBlue('Will remove established connection'));
        connectionToRemove = c;
        break;
      }
    }
    if (connectionToRemove != null) {
      connections.remove(connectionToRemove);
      _endingConnections.add(connectionToRemove);
      _log(chalk
          .brightBlue('Removed connection. ${connections.length} remaining.'));
      if (connections.isEmpty && gracePeriodPassed) {
        _log(chalk.brightBlue('No established connections remain'
            ' and grace period has passed - '
            ' will close connector'));
        _close(closeEnding: false);
      }
    }

    // NOTE: the flush gets its own try. A socket that is bound (the relay's
    // own flush still in flight), already broken, or past its deadline throws
    // here, and that must not cost this side its destroy() nor the far side
    // its close.
    if (!failed) {
      try {
        _log(chalk.brightBlue('Flushing socket on side ${side.name}'));
        await _flushBeforeDestroy(side.socket, deadline);
      } catch (err) {
        _log('Flush on side ${side.name} before close failed: $err');
      }
    }

    try {
      _log(chalk.brightBlue('Destroying socket on side ${side.name}'));
      side.socket.destroy();
      side.closedAt = DateTime.now().toUtc();
      _sides.remove(side);
      _gates.remove(side)?._stop();
      _closeFarSide(side);
    } catch (err) {
      _log('_closeSide encountered error $err');
    } finally {
      // NOTE: disposed only once the socket is destroyed, never before the
      // flush above. Nothing cancels this side's source subscription, so
      // until destroy() it can still deliver a chunk — and transform() on a
      // disposed transformer is a use-after-free for the FFI ciphers this
      // API exists for. destroy() is what actually stops delivery.
      side.chunkTransformer?.dispose();
    }
    _emitIfEnded(side);
    _closeEndedStreamIfDone();
  }

  /// Begins the close of [side]'s far side, which [side] no longer feeds.
  ///
  /// A far side that has been handed everything [side] produced closes now.
  /// Otherwise the relay write that hands it the last byte closes it, and a
  /// timer closes it at its deadline regardless.
  void _closeFarSide(Side side) {
    final Side? far = side.farSide;
    if (far == null || far.state != SideState.open) {
      return;
    }
    if (side.produced == far.sent) {
      _log(chalk.brightBlue(
          'Far side (${far.name}) has received all data - will close it'));
      _closeSide(far);
      return;
    }
    _log(chalk
        .brightBlue('Far side (${far.name}) has NOT YET received all data'));
    _farSideCloses.putIfAbsent(
        far,
        () => (
              deadline: _clock.elapsed + closeFlushTimeout,
              timer: Timer(closeFlushTimeout, () => _closeSide(far)),
            ));
  }

  /// Emits [side]'s [Connection] on [connectionClosedStream] once both of its
  /// sides are destroyed.
  void _emitIfEnded(Side side) {
    Connection? ended;
    for (final c in _endingConnections) {
      if (c.sideA == side || c.sideB == side) {
        ended = c;
        break;
      }
    }
    if (ended == null ||
        ended.sideA.closedAt == null ||
        ended.sideB.closedAt == null) {
      return;
    }
    _endingConnections.remove(ended);
    if (!_closedConnections.isClosed) {
      _closedConnections.add(ended);
    }
  }

  /// Closes [connectionClosedStream] once the connector is closed and every
  /// side's socket has been destroyed.
  void _closeEndedStreamIfDone() {
    if (closed && _sides.isEmpty) {
      _closedConnections.close();
    }
  }

  /// Closes both server sockets (if any), closes every pending,
  /// authenticating and established side, and the open side of every
  /// connection already ending, completes [done] and closes
  /// [connectionStream]. Idempotent.
  ///
  /// Returns without waiting for the sides: each side's socket is destroyed
  /// once its pending data is flushed, and within [closeFlushTimeout].
  /// [connectionClosedStream] closes once every side's socket has been
  /// destroyed.
  void close() => _close(closeEnding: true);

  /// Closes the connector as [close] does, closing the open side of a
  /// connection already ending only when [closeEnding] is set.
  ///
  /// The connector closes itself with [closeEnding] unset, so a connection
  /// whose end prompted it finishes its own close.
  void _close({required bool closeEnding}) {
    _timeoutTimer?.cancel();
    _serverSocketA?.close();
    _serverSocketA = null;

    _serverSocketB?.close();
    _serverSocketB = null;

    if (!_closedCompleter.isCompleted) {
      _closedCompleter.complete();
      _csc.close();
      _log('closed');
    }

    final pA = pendingA.toList();
    pendingA.clear();
    for (final s in pA) {
      _closeSide(s);
    }

    final pB = pendingB.toList();
    pendingB.clear();
    for (final s in pB) {
      _closeSide(s);
    }

    for (final s in _authenticating.toList()) {
      _closeSide(s);
    }

    for (final c in [
      ...connections,
      if (closeEnding) ..._endingConnections,
    ]) {
      _closeSide(c.sideA);
      _closeSide(c.sideB);
    }
    _closeEndedStreamIfDone();
  }

  void _log(String s, {bool force = false}) {
    if (verbose || force) {
      logger.writeln('${DateTime.now()} | SocketConnector | $s');
    }
  }

  /// Hands [side] to [handleSingleConnection], writing what it throws to
  /// [logSink]; that the connector has closed is written only when [verbose].
  void _join(Side side, IOSink logSink) {
    unawaited(handleSingleConnection(side).catchError((Object err) {
      if (verbose || !(closed && err is StateError)) {
        logSink.writeln(
            'ERROR $err from handleSingleConnection on side${side.name} $side');
      }
    }));
  }

  /// Binds two server sockets, one on each side, and relays data between the
  /// sockets that connect to them.
  ///
  /// - Side A listens on [addressA]:[portA], side B on [addressB]:[portB].
  ///   Each address defaults to [InternetAddress.anyIPv4]; a port of `0` (the
  ///   default) lets the OS choose a spare port - read the chosen ports back
  ///   from [sideAPort] / [sideBPort].
  /// - [socketAuthVerifierA] / [socketAuthVerifierB] optionally authenticate
  ///   the connection on each side before any data is relayed.
  /// - [keepAlive] sets TCP keep-alive on every accepted socket; defaults to
  ///   [SocketKeepAlive.defaults].
  /// - [backlog] is passed through to [ServerSocket.bind].
  /// - [timeout] is the grace period during which the connector waits for
  ///   connections before auto-closing; see [SocketConnector.timeout].
  /// - [closeFlushTimeout] bounds how long each side's close waits for its
  ///   pending data to be flushed; see [SocketConnector.closeFlushTimeout].
  /// - [stalledFlushTimeout] bounds how long a relay flush toward a side may
  ///   take before its connection is closed; see
  ///   [SocketConnector.stalledFlushTimeout].
  /// - Set [verbose] to log activity and [logTraffic] to log relayed bytes, to
  ///   [logger] (defaults to stderr).
  static Future<SocketConnector> serverToServer({
    /// Defaults to [InternetAddress.anyIPv4]
    InternetAddress? addressA,
    int portA = 0,

    /// Defaults to [InternetAddress.anyIPv4]
    InternetAddress? addressB,
    int portB = 0,
    bool verbose = false,
    bool logTraffic = false,
    SocketAuthVerifier? socketAuthVerifierA,
    SocketAuthVerifier? socketAuthVerifierB,
    Duration timeout = SocketConnector.defaultTimeout,
    Duration authTimeout = SocketConnector.defaultTimeout,
    SocketKeepAlive keepAlive = SocketKeepAlive.defaults,
    Duration closeFlushTimeout = SocketConnector.defaultCloseFlushTimeout,
    Duration stalledFlushTimeout = SocketConnector.defaultStalledFlushTimeout,
    IOSink? logger,
    int backlog = 0,
  }) async {
    IOSink logSink = logger ?? stderr;
    addressA ??= InternetAddress.anyIPv4;
    addressB ??= InternetAddress.anyIPv4;

    SocketConnector connector = SocketConnector(
      verbose: verbose,
      logTraffic: logTraffic,
      timeout: timeout,
      authTimeout: authTimeout,
      keepAlive: keepAlive,
      closeFlushTimeout: closeFlushTimeout,
      stalledFlushTimeout: stalledFlushTimeout,
      logger: logSink,
    );
    connector._serverSocketA = await ServerSocket.bind(
      addressA,
      portA,
      backlog: backlog,
    );
    connector._serverSocketB = await ServerSocket.bind(
      addressB,
      portB,
      backlog: backlog,
    );
    if (verbose) {
      logSink.writeln(
          '${DateTime.now()} | serverToServer | Bound ports A: ${connector.sideAPort}, B: ${connector.sideBPort}');
    }

    // listen for connections to the side 'A' server
    connector._serverSocketA!.listen((
      socket,
    ) {
      if (verbose) {
        logSink.writeln(
            '${DateTime.now()} | serverToServer | Connection on serverSocketA: ${connector._serverSocketA!.port}');
      }
      Side sideA = Side(socket, true, socketAuthVerifier: socketAuthVerifierA);
      connector._join(sideA, logSink);
    }, onError: (error) {
      logSink.writeln(
          '${DateTime.now()} | serverToServer | ERROR on serverSocketA: ${connector._serverSocketA?.port} : $error');
      connector._close(closeEnding: false);
    }, onDone: () {
      if (verbose || !connector.closed) {
        logSink.writeln(
            '${DateTime.now()} | serverToServer | onDone called on serverSocketA: ${connector._serverSocketA?.port}');
      }
      connector._close(closeEnding: false);
    });

    // listen for connections to the side 'B' server
    connector._serverSocketB!.listen((socket) {
      if (verbose) {
        logSink.writeln(
            '${DateTime.now()} | serverToServer | Connection on serverSocketB: ${connector._serverSocketB!.port}');
      }
      Side sideB = Side(socket, false, socketAuthVerifier: socketAuthVerifierB);
      connector._join(sideB, logSink);
    }, onError: (error) {
      logSink.writeln(
          '${DateTime.now()} | serverToServer | ERROR on serverSocketB: ${connector._serverSocketB?.port} : $error');
      connector._close(closeEnding: false);
    }, onDone: () {
      if (verbose || !connector.closed) {
        logSink.writeln(
            '${DateTime.now()} | serverToServer | onDone called on serverSocketB: ${connector._serverSocketB?.port}');
      }
      connector._close(closeEnding: false);
    });

    return (connector);
  }

  /// Connects out for side A and listens for an inbound connection on side B,
  /// then relays data between them.
  ///
  /// - Side A connects out to [addressA]:[portA].
  /// - Side B binds and listens on [addressB]:[portB], and the inbound socket
  ///   is joined to side A. If [portB] is `0` (the default) the OS chooses a
  ///   spare port; [addressB] defaults to [InternetAddress.anyIPv4].
  /// - [transformAtoB] / [transformBtoA] optionally rewrite the byte stream in
  ///   each direction.
  /// - [keepAlive] sets TCP keep-alive on every socket accepted or created;
  ///   defaults to [SocketKeepAlive.defaults].
  /// - [timeout] is the grace period during which the connector waits for
  ///   connections before auto-closing; see [SocketConnector.timeout].
  /// - [closeFlushTimeout] bounds how long each side's close waits for its
  ///   pending data to be flushed; see [SocketConnector.closeFlushTimeout].
  /// - [stalledFlushTimeout] bounds how long a relay flush toward a side may
  ///   take before its connection is closed; see
  ///   [SocketConnector.stalledFlushTimeout].
  /// - Set [verbose] to log activity and [logTraffic] to log relayed bytes, to
  ///   [logger] (defaults to stderr).
  static Future<SocketConnector> socketToServer({
    required InternetAddress addressA,
    required int portA,

    /// Defaults to [InternetAddress.anyIPv4]
    InternetAddress? addressB,
    int portB = 0,
    DataTransformer? transformAtoB,
    DataTransformer? transformBtoA,
    bool verbose = false,
    bool logTraffic = false,
    Duration timeout = SocketConnector.defaultTimeout,
    SocketKeepAlive keepAlive = SocketKeepAlive.defaults,
    Duration closeFlushTimeout = SocketConnector.defaultCloseFlushTimeout,
    Duration stalledFlushTimeout = SocketConnector.defaultStalledFlushTimeout,
    IOSink? logger,
  }) async {
    IOSink logSink = logger ?? stderr;
    addressB ??= InternetAddress.anyIPv4;

    SocketConnector connector = SocketConnector(
      verbose: verbose,
      logTraffic: logTraffic,
      timeout: timeout,
      keepAlive: keepAlive,
      closeFlushTimeout: closeFlushTimeout,
      stalledFlushTimeout: stalledFlushTimeout,
      logger: logSink,
    );

    // Create socket to an address and port
    Socket socket = await Socket.connect(addressA, portA);
    Side sideA = Side(socket, true, transformer: transformAtoB);
    connector._join(sideA, logSink);

    // bind to side 'B' port
    connector._serverSocketB = await ServerSocket.bind(addressB, portB);

    // listen for connections to the 'B' side port
    connector._serverSocketB?.listen((socketB) {
      Side sideB = Side(socketB, false, transformer: transformBtoA);
      connector._join(sideB, logSink);
    });
    return (connector);
  }

  /// Connects out on both sides and relays data between the two sockets.
  ///
  /// - Side A connects to [addressA]:[portA], side B to [addressB]:[portB].
  /// - [transformAtoB] / [transformBtoA] optionally rewrite the byte stream in
  ///   each direction.
  /// - [keepAlive] sets TCP keep-alive on both created sockets; defaults to
  ///   [SocketKeepAlive.defaults].
  /// - Pass an existing [connector] to relay through it instead of creating a
  ///   new one; when supplied, [verbose], [logTraffic], [timeout], [keepAlive],
  ///   [closeFlushTimeout], [stalledFlushTimeout] and [logger] are taken from
  ///   that connector and the values passed here are ignored.
  /// - [timeout] is the grace period during which the connector waits for
  ///   connections before auto-closing; see [SocketConnector.timeout].
  /// - [closeFlushTimeout] bounds how long each side's close waits for its
  ///   pending data to be flushed; see [SocketConnector.closeFlushTimeout].
  /// - [stalledFlushTimeout] bounds how long a relay flush toward a side may
  ///   take before its connection is closed; see
  ///   [SocketConnector.stalledFlushTimeout].
  /// - Set [verbose] to log activity and [logTraffic] to log relayed bytes, to
  ///   [logger] (defaults to stderr).
  static Future<SocketConnector> socketToSocket({
    SocketConnector? connector,
    required InternetAddress addressA,
    required int portA,
    required InternetAddress addressB,
    required int portB,
    DataTransformer? transformAtoB,
    DataTransformer? transformBtoA,
    bool verbose = false,
    bool logTraffic = false,
    Duration timeout = SocketConnector.defaultTimeout,
    SocketKeepAlive keepAlive = SocketKeepAlive.defaults,
    Duration closeFlushTimeout = SocketConnector.defaultCloseFlushTimeout,
    Duration stalledFlushTimeout = SocketConnector.defaultStalledFlushTimeout,
    IOSink? logger,
  }) async {
    IOSink logSink = logger ?? stderr;
    connector ??= SocketConnector(
      verbose: verbose,
      logTraffic: logTraffic,
      timeout: timeout,
      keepAlive: keepAlive,
      closeFlushTimeout: closeFlushTimeout,
      stalledFlushTimeout: stalledFlushTimeout,
      logger: logSink,
    );

    if (verbose) {
      logSink.writeln('socket_connector: Connecting to $addressA:$portA');
    }
    Socket sideASocket = await Socket.connect(addressA, portA);
    Side sideA = Side(sideASocket, true, transformer: transformAtoB);
    connector._join(sideA, logSink);

    if (verbose) {
      logSink.writeln('socket_connector: Connecting to $addressB:$portB');
    }
    try {
      Socket sideBSocket = await Socket.connect(addressB, portB);
      Side sideB = Side(sideBSocket, false, transformer: transformBtoA);
      connector._join(sideB, logSink);
    } catch (e) {
      sideA.socket.destroy();
      connector._closeSide(sideA);
      rethrow;
    }

    if (verbose) {
      logSink.writeln('socket_connector: started');
    }
    return (connector);
  }

  /// Listens for an inbound connection on side A and, for each one, connects
  /// out on side B, then relays data between them.
  ///
  /// - Side A binds and listens on [addressA]:[portA]. If [portA] is `0` (the
  ///   default) the OS chooses a spare port; [addressA] defaults to
  ///   [InternetAddress.anyIPv4].
  /// - For each inbound side A connection, side B connects out to
  ///   [addressB]:[portB].
  /// - [multi] controls whether more than one connection to the bound side A
  ///   port [portA] is accepted; when false the server socket is closed after
  ///   the first connection.
  /// - [transformAtoB] / [transformBtoA] optionally rewrite the byte stream in
  ///   each direction.
  /// - [keepAlive] sets TCP keep-alive on every socket accepted or created;
  ///   defaults to [SocketKeepAlive.defaults].
  /// - [backlog] is passed through to [ServerSocket.bind].
  /// - [beforeJoining] is called once side A has a new connection and the
  ///   corresponding outbound side B socket to [addressB]:[portB] has been
  ///   created, but **before** they are joined together. This lets the caller
  ///   take additional steps (such as setting new transformers rather than the
  ///   ones provided initially).
  /// - [onConnect] is the deprecated equivalent of [beforeJoining], called
  ///   **after** the two sides are joined.
  /// - [timeout] is the grace period during which the connector waits for
  ///   connections before auto-closing; see [SocketConnector.timeout].
  /// - [closeFlushTimeout] bounds how long each side's close waits for its
  ///   pending data to be flushed; see [SocketConnector.closeFlushTimeout].
  /// - [stalledFlushTimeout] bounds how long a relay flush toward a side may
  ///   take before its connection is closed; see
  ///   [SocketConnector.stalledFlushTimeout].
  /// - Set [verbose] to log activity and [logTraffic] to log relayed bytes, to
  ///   [logger] (defaults to stderr).
  static Future<SocketConnector> serverToSocket(
      {
      /// Defaults to [InternetAddress.anyIPv4]
      InternetAddress? addressA,
      int portA = 0,
      required InternetAddress addressB,
      required int portB,
      DataTransformer? transformAtoB,
      DataTransformer? transformBtoA,
      bool verbose = false,
      bool logTraffic = false,
      Duration timeout = SocketConnector.defaultTimeout,
      SocketKeepAlive keepAlive = SocketKeepAlive.defaults,
      Duration closeFlushTimeout = SocketConnector.defaultCloseFlushTimeout,
      Duration stalledFlushTimeout = SocketConnector.defaultStalledFlushTimeout,
      IOSink? logger,
      bool multi = false,
      @Deprecated("use beforeJoining instead")
      Function(Socket socketA, Socket socketB)? onConnect,
      Function(Side sideA, Side sideB)? beforeJoining,
      int backlog = 0}) async {
    IOSink logSink = logger ?? stderr;
    addressA ??= InternetAddress.anyIPv4;

    SocketConnector connector = SocketConnector(
      verbose: verbose,
      logTraffic: logTraffic,
      timeout: timeout,
      keepAlive: keepAlive,
      closeFlushTimeout: closeFlushTimeout,
      stalledFlushTimeout: stalledFlushTimeout,
      logger: logSink,
    );

    int connections = 0;
    // bind to a local port for side 'A'
    connector._serverSocketA = await ServerSocket.bind(
      addressA,
      portA,
      backlog: backlog,
    );

    StreamController<Socket> ssc = StreamController();
    Mutex m = Mutex();
    ssc.stream.listen((sideASocket) async {
      try {
        // It's important we handle these in sequence with no chance for race
        // So we're going to use a mutex
        await m.acquire();
        Side sideA = Side(sideASocket, true, transformer: transformAtoB);
        connector._join(sideA, logSink);

        if (verbose) {
          logSink.writeln('Creating socket #${++connections} to the "B" side');
        }
        // connect to the side 'B' address and port
        Socket? sideBSocket;
        try {
          sideBSocket = await Socket.connect(addressB, portB);
          if (verbose) {
            logSink.writeln('"B" side socket #$connections created');
          }
          Side sideB = Side(sideBSocket, false, transformer: transformBtoA);
          if (verbose) {
            logSink.writeln('Calling the beforeJoining callback');
          }
          await beforeJoining?.call(sideA, sideB);
          connector._join(sideB, logSink);

          onConnect?.call(sideASocket, sideBSocket);
        } catch (e) {
          logSink.writeln('ERROR connecting to side B or in beforeJoining: $e');
          // NOTE: the B socket is connected before beforeJoining and onConnect
          // run, and handleSingleConnection - which registers the close that
          // would reclaim it - runs after. A throw in between leaves it with
          // no owner, so destroy it here.
          sideBSocket?.destroy();
          sideA.socket.destroy();
          connector._closeSide(sideA);
        }
      } finally {
        m.release();
      }
    });

    // listen on the local port and connect the inbound socket
    connector._serverSocketA?.listen((sideASocket) {
      if (!multi) {
        try {
          connector._serverSocketA?.close();
        } catch (e) {
          logSink.writeln('Error while closing serverSocketA: $e');
        }
      }
      ssc.add(sideASocket);
    });

    return (connector);
  }
}

/// Whether [e] is the transient "sink is bound" [StateError] that
/// [Socket.add], [Socket.flush] and [Socket.close] all throw while a flush or
/// an `addStream` on that socket is still in flight.
///
/// NOTE: the message is the only discriminator the SDK offers; there is no
/// error code. `test/socket_connector_test.dart` pins the wording.
bool _isSinkBound(Object e) =>
    e is StateError && e.message.contains('bound to a stream');

/// The default for [_FlushGate.copyBeforeWrite]: the gated data is the source
/// socket's own buffer, which nothing reuses.
bool _neverCopy() => false;

/// How long after the first byte written toward a side since its last flush
/// a relay flush begins, if [SocketConnector.bufferHighWaterMark] has not
/// begun one sooner.
const Duration _flushDelay = Duration(seconds: 1);

/// Serialises writes to a socket against any [Socket.flush] on that socket.
///
/// `Socket.flush()` binds the sink for the duration of the flush, so any
/// `add()` that reaches the socket while a flush is in flight throws
/// `Bad state: StreamSink is bound to a stream`. Two flushes can hold the
/// socket bound:
///
/// 1. This gate's own flush, begun at the high-water mark or [_flushDelay]
///    after the first write since the last flush. Pausing the source is not
///    enough to keep an `add()` off the socket during it: a socket delivers
///    buffered data through microtask replay, and a `pause()` issued from
///    inside that replay does not reliably suppress the straggler already
///    scheduled.
/// 2. A flush from elsewhere — notably the close path's `flush()` on a socket
///    that this gate is still writing to from the far side.
///
/// So the gate routes every write through [add] and treats the bound state as
/// transient: while a flush is in flight it stashes incoming chunks and
/// replays them, in order, once the socket is writable again. No `add()` ever
/// tears the side down for a flush that is simply still running.
///
/// The stash holds only what arrives after the source has been paused, so it
/// stays small for any source that honours a pause (a socket, and any
/// transformer that forwards pauses, as `stream.map` and friends do). A
/// transformer that ignores pauses can grow it without bound, which is the
/// same caveat the backpressure itself carries.
class _FlushGate {
  _FlushGate({
    required Socket socket,
    required void Function(List<int> data) write,
    required void Function() pause,
    required void Function() resume,
    required void Function(Object error, StackTrace stackTrace) onError,
    required Duration stallTimeout,
    required void Function() onStall,
    bool Function() copyBeforeWrite = _neverCopy,
  })  : _socket = socket,
        _write = write,
        _pause = pause,
        _resume = resume,
        _onError = onError,
        _stallTimeout = stallTimeout,
        _onStall = onStall,
        _copyBeforeWrite = copyBeforeWrite;

  final Socket _socket;
  final void Function(List<int> data) _write;
  final void Function() _pause;
  final void Function() _resume;
  final void Function(Object error, StackTrace stackTrace) _onError;

  /// How long a flush may take before [_onStall] is called.
  final Duration _stallTimeout;
  final void Function() _onStall;
  Timer? _stallTimer;

  /// Begins a flush [_flushDelay] after the first write since the last one.
  Timer? _delayTimer;

  /// Whether the socket has been destroyed, after which no flush is delayed.
  bool _stopped = false;

  /// Whether [add] must copy before writing, asked on every write because a
  /// [ChunkTransformer] can be installed after this gate is built. See [add].
  final bool Function() _copyBeforeWrite;

  int _unflushed = 0;
  int _stashedBytes = 0;
  bool _flushing = false;
  bool _paused = false;
  List<List<int>> _stash = <List<int>>[];

  /// Writes [data], or stashes it if a flush is in flight or the socket is
  /// bound by someone else's flush.
  ///
  /// [ChunkTransformer.transform] is allowed to return a view over memory it
  /// reuses on its next call (see that contract's doc comment) and neither
  /// path consumes its argument before that next call can happen:
  ///
  /// - a stash holds the list across the flush it is waiting on;
  /// - `Socket.add` holds it until the bytes reach the kernel, which spans
  ///   event-loop turns whenever the socket takes a partial write. That is
  ///   the ordinary condition for a congested relay, and it is not bounded by
  ///   [SocketConnector.bufferHighWaterMark] — the mark only triggers a flush
  ///   once enough bytes have been *written*, long after the first partial
  ///   write has already retained a view.
  ///
  /// So a stash always copies, and the write path copies when
  /// [_copyBeforeWrite] returns true. The two branches are mutually
  /// exclusive, so no chunk is copied twice.
  void add(List<int> data) {
    if (_flushing) {
      _stash.add(List<int>.of(data));
      _stashedBytes += data.length;
      if (_stashedBytes >= SocketConnector.bufferHighWaterMark * 2) {
        _onError(StateError('Stash exceeded maximum limit (OOM protection)'),
            StackTrace.current);
      }
      return;
    }
    try {
      _write(_copyBeforeWrite() ? Uint8List.fromList(data) : data);
    } catch (e, st) {
      if (_isSinkBound(e)) {
        // Some other flush (e.g. the close path) holds the socket bound.
        // That is transient - stash and replay once it clears, rather than
        // closing the side on a flush that is merely still in flight.
        _stash.add(List<int>.of(data));
        _stashedBytes += data.length;
        _beginFlush();
        return;
      }
      _onError(e, st);
      return;
    }
    _unflushed += data.length;
    if (_unflushed >= SocketConnector.bufferHighWaterMark) {
      _beginFlush();
    } else if (!_stopped) {
      _delayTimer ??= Timer(_flushDelay, _beginFlush);
    }
  }

  /// Pauses the source and flushes, replaying the stash when the flush
  /// settles.
  void _beginFlush() {
    _cancelDelayTimer();
    _flushing = true;
    _pauseSource();
    _stallTimer ??= Timer(_stallTimeout, () {
      _stallTimer = null;
      _onStall();
    });
    _flushWhenWritable();
  }

  /// Stops waiting for the flush in flight to complete.
  void _cancelStallTimer() {
    _stallTimer?.cancel();
    _stallTimer = null;
  }

  void _cancelDelayTimer() {
    _delayTimer?.cancel();
    _delayTimer = null;
  }

  /// Cancels this gate's timers once its socket has been destroyed.
  void _stop() {
    _stopped = true;
    _cancelDelayTimer();
    _cancelStallTimer();
  }

  /// Flushes, retrying while some other flush holds the socket bound, and
  /// reports a failed flush to [_onError] as a failed write.
  ///
  /// NOTE: `flush()` throws the bound-sink [StateError] synchronously, so it
  /// belongs inside the guard for the same reason `add()` does.
  void _flushWhenWritable() {
    try {
      _socket.flush().then(
            (_) => _replay(),
            onError: (Object e, StackTrace st) => _fail(e, st),
          );
    } on StateError catch (e) {
      if (_isSinkBound(e)) {
        Timer(const Duration(milliseconds: 1), _flushWhenWritable);
      } else {
        _replay();
      }
    }
  }

  /// Drops the stash and reports [error]; the source stays paused.
  ///
  /// NOTE: nothing more is written to a socket whose flush has failed.
  void _fail(Object error, StackTrace stackTrace) {
    _stash = <List<int>>[];
    _stashedBytes = 0;
    _onError(error, stackTrace);
  }

  /// Writes the stash out and resumes the source, unless a replayed chunk has
  /// started another flush.
  void _replay() {
    _cancelStallTimer();
    // Every path here follows a flush that either completed, leaving nothing
    // unflushed, or failed, leaving a socket whose next write reports it.
    _unflushed = 0;
    _flushing = false;
    if (_stash.isNotEmpty) {
      final List<List<int>> pending = _stash;
      _stash = <List<int>>[];
      _stashedBytes = 0;
      for (final List<int> data in pending) {
        // A replayed chunk may cross the mark again, or hit the bound state
        // again; either way add() re-stashes the remainder into the fresh
        // _stash, in order, and re-enters the wait.
        add(data);
      }
    }
    if (!_flushing) _resumeSource();
  }

  /// NOTE: [StreamSubscription.pause] is counted, so a pause that overlaps
  /// another and never gets its own resume leaves the relay stopped for good
  /// with both sockets still open. The latch keeps the depth at one.
  void _pauseSource() {
    if (_paused) {
      return;
    }
    _paused = true;
    _pause();
  }

  void _resumeSource() {
    if (!_paused) {
      return;
    }
    _paused = false;
    _resume();
  }
}
