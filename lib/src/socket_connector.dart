import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:chalkdart/chalk.dart';
import 'package:meta/meta.dart';
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

  SocketConnector({
    this.verbose = false,
    this.logTraffic = false,
    this.timeout = defaultTimeout,
    IOSink? logger,
  }) {
    this.logger = logger ?? stderr;
    Timer(timeout, () {
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
  @visibleForTesting
  final List<Side> pendingA = [];

  /// B [Side]s which are available for pairing with the next A side connections
  @visibleForTesting
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
    if (thisSide.socketAuthVerifier == null) {
      thisSide.authenticated = true;
    } else {
      bool authenticated;
      Stream<Uint8List>? stream;
      try {
        (authenticated, stream) = await thisSide.socketAuthVerifier!
                (thisSide.socket)
            .timeout(Duration(seconds: 5));
        thisSide.authenticated = authenticated;
        if (thisSide.authenticated) {
          thisSide.stream = stream!;
          _log('Authentication succeeded on side ${thisSide.name}');
        }
      } catch (e) {
        thisSide.authenticated = false;
        _log('Error while authenticating side ${thisSide.name} : $e');
      }
    }
    if (!thisSide.authenticated) {
      _log('Authentication failed on side ${thisSide.name}');
      _destroySide(thisSide);
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

      for (final side in [thisSide, thisSide.farSide!]) {
        if (side.transformer != null) {
          // transformer is there to transform data originating FROM its side
          StreamController<Uint8List> sc = StreamController<Uint8List>();
          side.farSide!.sink = sc;
          Stream<List<int>> transformed = side.transformer!(sc.stream);
          transformed.listen(side.farSide!.socket.add);
        }
        side.stream.listen((Uint8List data) async {
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
          side.farSide!.sink.add(data);
        }, onDone: () {
          _log('stream.onDone on side ${side.name}');
          _destroySide(side);
        }, onError: (error) {
          _log('stream.onError on side ${side.name}: $error');
          _destroySide(side);
        });
      }
    }
  }

  _destroySide(final Side side) {
    if (side.state != SideState.open) {
      return;
    }
    side.state = SideState.closing;
    try {
      _log(chalk.brightBlue('Destroying socket on side ${side.name}'));
      side.socket.destroy();
      if (side.farSide != null) {
        _log(chalk.brightBlue(
            'Destroying socket on far side (${side.farSide?.name})'));
        side.farSide?.socket.destroy();
      }

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
        _log(chalk.brightBlue('Removed connection'));
        if (connections.isEmpty) {
          _log(chalk.brightBlue('No established connections remain - '
              ' will close connector'));
          close();
        }
      }
    } catch (_) {
    } finally {
      side.state = SideState.closed;
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
      _destroySide(s);
    }
    pendingA.clear();
    for (final s in pendingB) {
      _destroySide(s);
    }
    pendingB.clear();
  }

  void _log(String s) {
    if (verbose) {
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
    IOSink? logger,
  }) async {
    IOSink logSink = logger ?? stderr;
    addressA ??= InternetAddress.anyIPv4;
    addressB ??= InternetAddress.anyIPv4;

    SocketConnector connector = SocketConnector(
      verbose: verbose,
      logTraffic: logTraffic,
      timeout: timeout,
      logger: logSink,
    );
    connector._serverSocketA = await ServerSocket.bind(addressA, portA);
    connector._serverSocketB = await ServerSocket.bind(addressB, portB);
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
      unawaited(connector.handleSingleConnection(sideA));
    });

    // listen for connections to the side 'B' server
    connector._serverSocketB!.listen((socket) {
      if (verbose) {
        logSink.writeln(
            '${DateTime.now()} | serverToServer | Connection on serverSocketB: ${connector._serverSocketB!.port}');
      }
      Side sideB = Side(socket, false, socketAuthVerifier: socketAuthVerifierB);
      unawaited(connector.handleSingleConnection(sideB));
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
    unawaited(connector.handleSingleConnection(sideA));

    // bind to side 'B' port
    connector._serverSocketB = await ServerSocket.bind(addressB, portB);

    // listen for connections to the 'B' side port
    connector._serverSocketB?.listen((socketB) {
      Side sideB = Side(socketB, false, transformer: transformBtoA);
      unawaited(connector.handleSingleConnection(sideB));
    });
    return (connector);
  }

  /// - Creates socket to [portA] on [addressA]
  /// - Creates socket to [portB] on [addressB]
  /// - Relays data between the sockets
  static Future<SocketConnector> socketToSocket({
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
    SocketConnector connector = SocketConnector(
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
    unawaited(connector.handleSingleConnection(sideA));

    if (verbose) {
      logSink.writeln('socket_connector: Connecting to $addressB:$portB');
    }
    Socket sideBSocket = await Socket.connect(addressB, portB);
    Side sideB = Side(sideBSocket, false, transformer: transformBtoA);
    unawaited(connector.handleSingleConnection(sideB));

    if (verbose) {
      logSink.writeln('socket_connector: started');
    }
    return (connector);
  }

  /// - Creates socket to [portB] on [addressB]
  /// - Binds to [portA] on [addressA]
  /// - Listens for a socket connection on [portA] port and joins it to
  ///   the 'B' side
  ///
  /// - If [portA] is not provided then a port is chosen by the OS.
  /// - [addressA] defaults to [InternetAddress.anyIPv4]
  static Future<SocketConnector> serverToSocket({
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
  }) async {
    IOSink logSink = logger ?? stderr;
    addressA ??= InternetAddress.anyIPv4;

    SocketConnector connector = SocketConnector(
      verbose: verbose,
      logTraffic: logTraffic,
      timeout: timeout,
      logger: logSink,
    );

    // bind to a local port for side 'A'
    connector._serverSocketA = await ServerSocket.bind(addressA, portA);
    // listen on the local port and connect the inbound socket
    connector._serverSocketA?.listen((socket) {
      Side sideA = Side(socket, true, transformer: transformAtoB);
      unawaited(connector.handleSingleConnection(sideA));
    });

    // connect to the side 'B' address and port
    Socket sideBSocket = await Socket.connect(addressB, portB);
    Side sideB = Side(sideBSocket, false, transformer: transformBtoA);
    unawaited(connector.handleSingleConnection(sideB));

    return (connector);
  }
}
