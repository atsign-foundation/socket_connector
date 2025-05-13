import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:chalkdart/chalk.dart';
import 'package:mutex/mutex.dart';
import 'package:socket_connector/src/types.dart';

/// Typical usage is via the [serverToServer], [serverToSocket],
/// [socketToSocket] and [socketToServer] methods which are different flavours
/// of the same functionality - to relay information from one socket to another.
///
/// - Upon creation, a [Timer] will be created for [timeout] duration. The
///   timer callback, when it executes, calls [close] if [connections]
//    is empty
/// - When an established connection is closed, [close] will be called if
///   [connections] is empty
/// - New [Connection]s are added to [connections] when both
///   [pendingA] and [pendingB] have
///   at least one entry
/// - When [verbose] is true, log messages will be logged to [logger]
/// - When [logTraffic] is true, socket traffic will be logged to [logger]
class SocketConnector {
  static const defaultTimeout = Duration(seconds: 30);

  bool gracePeriodPassed = false;

  SocketConnector({
    this.verbose = false,
    this.logTraffic = false,
    this.timeout = defaultTimeout,
    this.authTimeout = defaultTimeout,
    IOSink? logger,
  }) {
    this.logger = logger ?? stderr;
    Timer(timeout, () {
      gracePeriodPassed = true;
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

  /// - Upon creation, a [Timer] will be created for [timeout] duration. The timer
  ///   callback calls [close] if [connections] is empty
  final Duration timeout;

  /// The established [Connection]s
  final List<Connection> connections = [];

  /// A [Side]s which are available for pairing with the next B side connections
  final List<Side> pendingA = [];

  /// B [Side]s which are available for pairing with the next A side connections
  final List<Side> pendingB = [];

  /// Completes when either
  /// 1. [connections] size goes from >0 to 0, or
  /// 2. [timeout] has passed and  [connections] is empty
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

  /// Add a [Side] with optional [SocketAuthVerifier] and
  /// [DataTransformer]
  /// - If [socketAuthVerifier] provided, wait for socket to be authenticated
  /// - All data from the corresponding 'far' side will be transformed by the
  ///   [transformer] if supplied. For example: [socketToSocket] creates a
  ///   [Side]s A and B, and has parameters `transformAtoB` and
  ///   `transformBtoA`.
  Future<void> handleSingleConnection(final Side thisSide) async {
    if (closed) {
      throw StateError('Connector is closed');
    }
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
      _log(chalk.brightBlue(
          'Added connection. There are now ${connections.length} connections.'));

      for (final side in [thisSide, thisSide.farSide!]) {
        if (side.transformer != null) {
          // transformer is there to transform data originating FROM its side
          // transformer's output will write to the SOCKET on the far side
          StreamController<Uint8List> sc = StreamController<Uint8List>();
          side.farSide!.sink = sc;
          Stream<List<int>> transformed = side.transformer!(sc.stream);
          transformed.listen(
            (data) {
              try {
                side.farSide!.socket.add(data);
                side.farSide!.sent += data.length;
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
        side.stream.listen((Uint8List data) {
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
            if (side.farSide!.sink is Socket) {
              side.farSide!.sent += data.length;
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
        }, onDone: () async {
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

  _closeSide(final Side side) async {
    if (side.state != SideState.open) {
      return;
    }
    side.state = SideState.closed;

    _log(chalk.brightBlue('_closeSide ${side.name}: RCVD: ${side.rcvd} bytes; SENT: ${side.sent} bytes'));

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

  void close() {
    _serverSocketA?.close();
    _serverSocketA = null;

    _serverSocketB?.close();
    _serverSocketB = null;

    if (!_closedCompleter.isCompleted) {
      _closedCompleter.complete();
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

  /// Binds two Server sockets on specified Internet Addresses.
  /// Ports on which to listen can be given but if not given a spare port will be found by the OS.
  /// Finally relays data between sockets and optionally displays contents using the verbose flag
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

  /// - Creates socket to [portA] on [addressA]
  /// - Binds to [portB] on [addressB]
  /// - Listens for a socket connection on [portB] port and joins it to
  ///   the 'A' side
  ///
  /// - If [portB] is not provided then a port is chosen by the OS.
  /// - [addressB] defaults to [InternetAddress.anyIPv4]
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
    IOSink? logger,
  }) async {
    IOSink logSink = logger ?? stderr;
    addressB ??= InternetAddress.anyIPv4;

    SocketConnector connector = SocketConnector(
      verbose: verbose,
      logTraffic: logTraffic,
      timeout: timeout,
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

  /// - Creates socket to [portA] on [addressA]
  /// - Creates socket to [portB] on [addressB]
  /// - Relays data between the sockets
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
    IOSink? logger,
  }) async {
    IOSink logSink = logger ?? stderr;
    connector ??= SocketConnector(
      verbose: verbose,
      logTraffic: logTraffic,
      timeout: timeout,
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

  /// - Creates socket to [portB] on [addressB]
  /// - Binds to [portA] on [addressA]
  /// - Listens for a socket connection on [portA] port and joins it to
  ///   the 'B' side
  /// - If [portA] is not provided then a port is chosen by the OS.
  /// - [addressA] defaults to [InternetAddress.anyIPv4]
  /// - [multi] flag controls whether or not to allow multiple connections
  ///   to the bound server port [portA]
  /// - [onConnect] is called when [portA] has got a new connection and a
  ///   corresponding outbound socket has been created to [addressB]:[portB]
  ///   and the two have been joined together
  /// - [beforeJoining] is called when [portA] has got a new connection and a
  ///   corresponding outbound socket has been created to [addressB]:[portB]
  ///   but **before** they are joined together. This allows the code which
  ///   called [serverToSocket] to take additional steps (such as setting new
  ///   transformers rather than the ones which were provided initially)
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
