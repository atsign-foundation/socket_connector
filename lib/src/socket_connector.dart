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
class SocketConnector {
  static const defaultTimeout = Duration(seconds: 30);

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

  SocketConnector({
    this.verbose = false,
    this.logTraffic = false,
    this.timeout = defaultTimeout,
    this.authTimeout = defaultTimeout,
    this.keepAlive = SocketKeepAlive.defaults,
    IOSink? logger,
  }) {
    this.logger = logger ?? stderr;
    Timer(timeout, () {
      _gracePeriodPassed = true;
      if (connections.isEmpty) {
        close();
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
  /// Throws [StateError] if the connector is already [closed].
  Future<void> handleSingleConnection(final Side thisSide) async {
    if (closed) {
      throw StateError('Connector is closed');
    }
    // Apply TCP keep-alive to every socket as it is accepted or created. Every
    // Side - whether from an inbound accept or an outbound connect - funnels
    // through here, so this is the single place keep-alive needs to be set.
    keepAlive.applyTo(thisSide.socket, onError: (m) => _log(m, force: true));
    unawaited(thisSide.socket.done
        .then((v) => _closeSide(thisSide))
        .catchError((err) => _closeSide(thisSide)));
    if (thisSide.socketAuthVerifier == null) {
      thisSide.authenticated = true;
    } else {
      bool authenticated;
      Stream<Uint8List>? stream;
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
            force: true);
      }
    }
    if (!thisSide.authenticated) {
      _log('Authentication failed on side ${thisSide.name}', force: true);
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
        // resumes when flush() reports the queue has drained.
        late final StreamSubscription<Uint8List> sourceSub;

        if (side.transformer != null) {
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
          int unflushed = 0;
          late final StreamSubscription<List<int>> transformedSub;
          transformedSub = transformed.listen(
            (data) {
              try {
                side.farSide!.socket.add(data);
                if (side.isSideA) {
                  stats.bytesAtoB += data.length;
                } else {
                  stats.bytesBtoA += data.length;
                }
                side.farSide!.sent += data.length;
                unflushed += data.length;
                if (unflushed >= bufferHighWaterMark) {
                  transformedSub.pause();
                  side.farSide!.socket.flush().then((_) {
                    unflushed = 0;
                    transformedSub.resume();
                  }, onError: (Object e) {
                    // Broken socket: resume so the next add() lands on the
                    // existing write-error path below and closes the side.
                    unflushed = 0;
                    transformedSub.resume();
                  });
                }
                if (side.state == SideState.closed &&
                    side.rcvd == side.farSide!.sent) {
                  _closeSide(side.farSide!);
                }
              } catch (e, st) {
                _log('Failed to write to side ${side.farSide!.name} - closing',
                    force: true);
                _log('(Error was $e; Stack trace follows\n$st', force: true);
                _closeSide(side.farSide!);
              }
            },
            onDone: () => _closeSide(side),
            onError: (error) => _closeSide(side),
          );
        }
        int unflushedDirect = 0;
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
          try {
            side.farSide!.sink.add(data);
            if (side.isSideA) {
              stats.bytesAtoB += data.length;
            } else {
              stats.bytesBtoA += data.length;
            }
            if (side.farSide!.sink is Socket) {
              side.farSide!.sent += data.length;
              unflushedDirect += data.length;
              if (unflushedDirect >= bufferHighWaterMark) {
                sourceSub.pause();
                (side.farSide!.sink as Socket).flush().then((_) {
                  unflushedDirect = 0;
                  sourceSub.resume();
                }, onError: (Object e) {
                  // Broken socket: resume so the next add() lands on the
                  // existing write-error path below and closes the side.
                  unflushedDirect = 0;
                  sourceSub.resume();
                });
              }
              if (side.state == SideState.closed &&
                  side.rcvd == side.farSide!.sent) {
                _closeSide(side.farSide!);
              }
            }
          } catch (e, st) {
            _log('Failed to write to side ${side.farSide!.name} - closing',
                force: true);
            _log('(Error was $e; Stack trace follows\n$st', force: true);
            _closeSide(side.farSide!);
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

  // ignore: strict_top_level_inference
  _closeSide(final Side side) async {
    if (side.state != SideState.open) {
      return;
    }
    side.state = SideState.closed;

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
      _log(chalk
          .brightBlue('Removed connection. ${connections.length} remaining.'));
      if (connections.isEmpty && gracePeriodPassed) {
        _log(chalk.brightBlue('No established connections remain'
            ' and grace period has passed - '
            ' will close connector'));
        close();
      }
    }

    try {
      _log(chalk.brightBlue('Destroying socket on side ${side.name}'));
      await side.socket.flush();
      side.socket.destroy();
      if (side.farSide != null && side.farSide!.state != SideState.closed) {
        if (side.rcvd == side.farSide!.sent) {
          _log(chalk.brightBlue(
              'Far side (${side.farSide?.name}) has received all data - will close it'));
          _closeSide(side.farSide!);
        } else {
          _log(chalk.brightBlue(
              'Far side (${side.farSide?.name}) has NOT YET received all data'));
        }
      }
    } catch (err) {
      _log('_closeSide encountered error $err');
    }
  }

  /// Closes both server sockets (if any), closes every pending and established
  /// side, completes [done] and closes [connectionStream]. Idempotent.
  void close() {
    _serverSocketA?.close();
    _serverSocketA = null;

    _serverSocketB?.close();
    _serverSocketB = null;

    if (!_closedCompleter.isCompleted) {
      _closedCompleter.complete();
      _csc.close();
      _log('closed');
    }
    for (final s in pendingA) {
      _closeSide(s);
    }
    pendingA.clear();
    for (final s in pendingB) {
      _closeSide(s);
    }
    pendingB.clear();
  }

  void _log(String s, {bool force = false}) {
    if (verbose || force) {
      logger.writeln('${DateTime.now()} | SocketConnector | $s');
    }
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
      unawaited(connector.handleSingleConnection(sideA).catchError((err) {
        logSink
            .writeln('ERROR $err from handleSingleConnection on sideA $sideA');
      }));
    }, onError: (error) {
      logSink.writeln(
          '${DateTime.now()} | serverToServer | ERROR on serverSocketA: ${connector._serverSocketA?.port} : $error');
      connector.close();
    }, onDone: () {
      logSink.writeln(
          '${DateTime.now()} | serverToServer | onDone called on serverSocketA: ${connector._serverSocketA?.port}');
      connector.close();
    });

    // listen for connections to the side 'B' server
    connector._serverSocketB!.listen((socket) {
      if (verbose) {
        logSink.writeln(
            '${DateTime.now()} | serverToServer | Connection on serverSocketB: ${connector._serverSocketB!.port}');
      }
      Side sideB = Side(socket, false, socketAuthVerifier: socketAuthVerifierB);
      unawaited(connector.handleSingleConnection(sideB).catchError((err) {
        logSink
            .writeln('ERROR $err from handleSingleConnection on sideB $sideB');
      }));
    }, onError: (error) {
      logSink.writeln(
          '${DateTime.now()} | serverToServer | ERROR on serverSocketB: ${connector._serverSocketB?.port} : $error');
      connector.close();
    }, onDone: () {
      logSink.writeln(
          '${DateTime.now()} | serverToServer | onDone called on serverSocketB: ${connector._serverSocketB?.port}');
      connector.close();
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
    IOSink? logger,
  }) async {
    IOSink logSink = logger ?? stderr;
    addressB ??= InternetAddress.anyIPv4;

    SocketConnector connector = SocketConnector(
      verbose: verbose,
      logTraffic: logTraffic,
      timeout: timeout,
      keepAlive: keepAlive,
      logger: logSink,
    );

    // Create socket to an address and port
    Socket socket = await Socket.connect(addressA, portA);
    Side sideA = Side(socket, true, transformer: transformAtoB);
    unawaited(connector.handleSingleConnection(sideA).catchError((err) {
      logSink.writeln('ERROR $err from handleSingleConnection on sideA $sideA');
    }));

    // bind to side 'B' port
    connector._serverSocketB = await ServerSocket.bind(addressB, portB);

    // listen for connections to the 'B' side port
    connector._serverSocketB?.listen((socketB) {
      Side sideB = Side(socketB, false, transformer: transformBtoA);
      unawaited(connector.handleSingleConnection(sideB).catchError((err) {
        logSink
            .writeln('ERROR $err from handleSingleConnection on sideB $sideB');
      }));
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
  ///   new one; when supplied, [verbose], [logTraffic], [timeout], [keepAlive]
  ///   and [logger] are taken from that connector and the values passed here
  ///   are ignored.
  /// - [timeout] is the grace period during which the connector waits for
  ///   connections before auto-closing; see [SocketConnector.timeout].
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
    IOSink? logger,
  }) async {
    IOSink logSink = logger ?? stderr;
    connector ??= SocketConnector(
      verbose: verbose,
      logTraffic: logTraffic,
      timeout: timeout,
      keepAlive: keepAlive,
      logger: logSink,
    );

    if (verbose) {
      logSink.writeln('socket_connector: Connecting to $addressA:$portA');
    }
    Socket sideASocket = await Socket.connect(addressA, portA);
    Side sideA = Side(sideASocket, true, transformer: transformAtoB);
    unawaited(connector.handleSingleConnection(sideA).catchError((err) {
      logSink.writeln('ERROR $err from handleSingleConnection on sideA $sideA');
    }));

    if (verbose) {
      logSink.writeln('socket_connector: Connecting to $addressB:$portB');
    }
    Socket sideBSocket = await Socket.connect(addressB, portB);
    Side sideB = Side(sideBSocket, false, transformer: transformBtoA);
    unawaited(connector.handleSingleConnection(sideB).catchError((err) {
      logSink.writeln('ERROR $err from handleSingleConnection on sideB $sideB');
    }));

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
        unawaited(connector.handleSingleConnection(sideA).catchError((err) {
          logSink.writeln(
              'ERROR $err from handleSingleConnection on sideA $sideA');
        }));

        if (verbose) {
          logSink.writeln('Creating socket #${++connections} to the "B" side');
        }
        // connect to the side 'B' address and port
        Socket sideBSocket = await Socket.connect(addressB, portB);
        if (verbose) {
          logSink.writeln('"B" side socket #$connections created');
        }
        Side sideB = Side(sideBSocket, false, transformer: transformBtoA);
        if (verbose) {
          logSink.writeln('Calling the beforeJoining callback');
        }
        await beforeJoining?.call(sideA, sideB);
        unawaited(connector.handleSingleConnection(sideB).catchError((err) {
          logSink.writeln(
              'ERROR $err from handleSingleConnection on sideB $sideB');
        }));

        onConnect?.call(sideASocket, sideBSocket);
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
