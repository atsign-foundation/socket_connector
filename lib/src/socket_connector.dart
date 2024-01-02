import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:chalkdart/chalk.dart';

/// Typical usage is via the [serverToServer], [serverToSocket],
/// [socketToSocket] and [socketToServer] methods.
class SocketConnector {
  SocketConnector({required this.verbose});

  bool verbose;

  ServerSocket? _serverSocketA;
  ServerSocket? _serverSocketB;

  List<ConnectionSide> authenticatedUnpairedSenders = [];
  List<ConnectionSide> authenticatedUnpairedReceivers = [];

  List<Connection> establishedConnections = [];

  final Completer<bool> _closedCompleter = Completer();

  /// Returns the TCP port number of the sender socket
  int? senderPort() {
    return _serverSocketA?.port;
  }

  /// Returns the TCP port of the receiver socket
  int? receiverPort() {
    return _serverSocketB?.port;
  }

  /// returns true if sockets are closed/null
  /// wait 30 seconds to ensure network has a chance
  Future<bool> closed() async {
    return _closedCompleter.future;
  }

  Future<void> _handleSingleConnection(
    final ConnectionSide thisSide, {
    SocketAuthVerifier? socketAuthVerifier,
    DataTransformer? transformer,
  }) async {
    if (verbose) {
      stderr.writeln(' _handleSingleConnection :'
          ' socketAuthVerifier $socketAuthVerifier'
          ' for ${thisSide.sender ? 'SENDER' : 'RECEIVER'}');
    }

    if (socketAuthVerifier == null) {
      thisSide.authenticated = true;
    } else {
      bool authenticated;
      Stream<Uint8List>? stream;
      try {
        (authenticated, stream) =
            await socketAuthVerifier.authenticate(thisSide.socket);
        thisSide.authenticated = authenticated;
        if (thisSide.authenticated) {
          thisSide.stream = stream!;
        }
      } catch (e) {
        stderr.writeln('Error while authenticating '
            ' side ${thisSide.sender ? 'A' : 'B'}'
            ' : $e');
        thisSide.authenticated = false;
      }
    }
    if (!thisSide.authenticated) {
      stderr.writeln('Authentication failed on'
          ' side ${thisSide.sender ? 'A' : 'B'}');
      _destroySide(thisSide);
      return;
    }

    if (thisSide.sender) {
      authenticatedUnpairedSenders.add(thisSide);
    } else {
      authenticatedUnpairedReceivers.add(thisSide);
    }

    if (transformer != null) {
      StreamController<Uint8List> sc = StreamController<Uint8List>();
      thisSide.sink = sc;
      Stream<List<int>> transformed = transformer(sc.stream);
      transformed.listen(thisSide.socket.add);
    }

    if (authenticatedUnpairedSenders.isNotEmpty &&
        authenticatedUnpairedReceivers.isNotEmpty) {
      Connection c = Connection(authenticatedUnpairedSenders.removeAt(0),
          authenticatedUnpairedReceivers.removeAt(0));
      establishedConnections.add(c);

      for (final s in [thisSide, thisSide.farSide!]) {
        s.stream.listen((Uint8List data) async {
          if (verbose) {
            final message = String.fromCharCodes(data);
            if (s.sender) {
              stderr.writeln(chalk.brightGreen(
                  'A -> B : ${message.replaceAll(RegExp('[\x00-\x1F\x7F-\xFF]'), '*')}'));
            } else {
              stderr.writeln(chalk.brightRed(
                  'B -> A : ${message.replaceAll(RegExp('[\x00-\x1F\x7F-\xFF]'), '*')}'));
            }
          }
          s.farSide!.sink.add(data);
        }, onDone: () {
          if (verbose) {
            stderr.writeln('stream.onDone on side ${s.sender ? 'A' : 'B'}');
          }
          _destroySide(s);
        }, onError: (error) {
          stderr.writeln(
              'stream.onError on side ${s.sender ? 'A' : 'B'}: $error');
          _destroySide(s);
        });
      }
    }
  }

  _destroySide(final ConnectionSide side) {
    if (side.state != SideState.open) {
      return;
    }
    side.state = SideState.closing;
    try {
      if (verbose) {
        stderr.writeln(
            chalk.brightBlue('Destroying side ${side.sender ? 'A' : 'B'}'));
      }
      side.socket.destroy();
      if (verbose) {
        stderr.writeln(chalk.brightBlue('Destroying other side socket'));
      }
      side.farSide?.socket.destroy();

      Connection? connectionToRemove;
      for (final c in establishedConnections) {
        if (c.sideA == side || c.sideB == side) {
          if (verbose) {
            stderr.writeln(chalk.brightBlue('Found connection to remove'));
          }
          connectionToRemove = c;
          break;
        }
      }
      if (establishedConnections.remove(connectionToRemove)) {
        if (verbose) {
          stderr.writeln(chalk.brightBlue('Removed connection'));
        }
        if (establishedConnections.isEmpty) {
          if (verbose) {
            stderr.writeln(chalk.brightBlue('Closing connector'));
          }
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
    _serverSocketB?.close();
    _closedCompleter.complete(true);
  }

  /// Binds two Server sockets on specified Internet Addresses.
  /// Ports on which to listen can be given but if not given a spare port will be found by the OS.
  /// Finally relays data between sockets and optionally displays contents using the verbose flag
  static Future<SocketConnector> serverToServer({
    InternetAddress? serverAddressA,
    InternetAddress? serverAddressB,
    int? serverPortA,
    int? serverPortB,
    bool verbose = false,
    SocketAuthVerifier? socketAuthVerifierA,
    SocketAuthVerifier? socketAuthVerifierB,
  }) async {
    InternetAddress senderBindAddress;
    InternetAddress receiverBindAddress;
    serverPortA ??= 0;
    serverPortB ??= 0;
    serverAddressA ??= InternetAddress.anyIPv4;
    serverAddressB ??= InternetAddress.anyIPv4;

    senderBindAddress = serverAddressA;
    receiverBindAddress = serverAddressA;

    //List<SocketStream> socketStreams;
    SocketConnector connector = SocketConnector(verbose: verbose);
    // bind the socket server to an address and port
    connector._serverSocketA =
        await ServerSocket.bind(senderBindAddress, serverPortA);
    // bind the socket server to an address and port
    connector._serverSocketB =
        await ServerSocket.bind(receiverBindAddress, serverPortB);

    // listen for sender connections to the server
    connector._serverSocketA!.listen((
      senderSocket,
    ) {
      if (verbose) {
        stderr.writeln(
            'Connection on serverSocketA: ${connector._serverSocketA!.port}');
      }
      ConnectionSide senderSide = ConnectionSide(senderSocket, true);
      unawaited(connector._handleSingleConnection(senderSide,
          socketAuthVerifier: socketAuthVerifierA));
    });

    // listen for receiver connections to the server
    connector._serverSocketB!.listen((receiverSocket) {
      if (verbose) {
        stderr.writeln(
            'Connection on serverSocketB: ${connector._serverSocketB!.port}');
      }
      ConnectionSide receiverSide = ConnectionSide(receiverSocket, false);
      unawaited(connector._handleSingleConnection(receiverSide,
          socketAuthVerifier: socketAuthVerifierB));
    });

    return (connector);
  }

  /// Binds a Server socket on a specified InternetAddress
  /// Port on which to listen can be specified but if not given a spare port will be found by the OS.
  /// Then opens socket to specified Internet Address and port
  /// Finally relays data between sockets and optionally displays contents using the verbose flag
  static Future<SocketConnector> socketToServer({
    required InternetAddress socketAddress,
    required int socketPort,
    InternetAddress? serverAddress,
    int? receiverPort,
    DataTransformer? transformAtoB,
    DataTransformer? transformBtoA,
    bool verbose = false,
  }) async {
    InternetAddress receiverBindAddress;
    receiverPort ??= 0;

    serverAddress ??= InternetAddress.anyIPv4;
    receiverBindAddress = serverAddress;

    SocketConnector connector = SocketConnector(verbose: verbose);

    // Create socket to an address and port
    Socket socket = await Socket.connect(socketAddress, socketPort);
    ConnectionSide senderSide = ConnectionSide(socket, true);

    // listen for sender connections to the server
    unawaited(connector._handleSingleConnection(senderSide,
        transformer: transformAtoB));

    // bind the socket server to an address and port
    connector._serverSocketB =
        await ServerSocket.bind(receiverBindAddress, receiverPort);

    // listen for receiver connections to the server
    connector._serverSocketB?.listen((socketB) {
      ConnectionSide receiverSide = ConnectionSide(socketB, false);
      unawaited(connector._handleSingleConnection(receiverSide,
          transformer: transformBtoA));
    });
    return (connector);
  }

  /// Opens sockets specified Internet Addresses and ports
  /// Then relays data between sockets and optionally displays contents using the verbose flag
  static Future<SocketConnector> socketToSocket({
    required InternetAddress socketAddressA,
    required int socketPortA,
    required InternetAddress socketAddressB,
    required int socketPortB,
    DataTransformer? transformAtoB,
    DataTransformer? transformBtoA,
    bool? verbose,
  }) async {
    verbose ??= false;

    SocketConnector connector = SocketConnector(verbose: verbose);

    if (verbose) {
      stderr.writeln(
          'socket_connector: Connecting to $socketAddressA:$socketPortA');
    }
    Socket senderSocket = await Socket.connect(socketAddressA, socketPortA);
    ConnectionSide senderSide = ConnectionSide(senderSocket, true);
    unawaited(connector._handleSingleConnection(senderSide,
        transformer: transformAtoB));

    if (verbose) {
      stderr.writeln(
          'socket_connector: Connecting to $socketAddressB:$socketPortB');
    }
    Socket receiverSocket = await Socket.connect(socketAddressB, socketPortB);
    ConnectionSide receiverSide = ConnectionSide(receiverSocket, false);
    unawaited(connector._handleSingleConnection(receiverSide,
        transformer: transformBtoA));

    if (verbose) {
      stderr.writeln('socket_connector: started');
    }
    return (connector);
  }

  /// Binds to [serverPort] on the loopback interface (127.0.0.1)
  ///
  /// Listens for a socket connection on that
  /// port and joins it to a socket connection to [receiverSocketPort]
  /// on [receiverSocketAddress]
  ///
  /// If [serverPort] is not provided then a port is chosen by the OS.
  ///
  static Future<SocketConnector> serverToSocket({
    required InternetAddress receiverSocketAddress,
    required int receiverSocketPort,
    int localServerPort = 0,
    DataTransformer? transformAtoB,
    DataTransformer? transformBtoA,
    bool verbose = false,
  }) async {
    SocketConnector connector = SocketConnector(verbose: verbose);

    // bind to a local port to which 'senders' will connect
    connector._serverSocketA =
        await ServerSocket.bind(InternetAddress('127.0.0.1'), localServerPort);
    // listen on the local port and connect the inbound socket (the 'sender')
    connector._serverSocketA?.listen((senderSocket) {
      ConnectionSide senderSide = ConnectionSide(senderSocket, true);
      unawaited(connector._handleSingleConnection(senderSide,
          transformer: transformAtoB));
    });

    // connect to the receiver address and port
    Socket receiverSocket =
        await Socket.connect(receiverSocketAddress, receiverSocketPort);
    ConnectionSide receiverSide = ConnectionSide(receiverSocket, false);
    unawaited(connector._handleSingleConnection(receiverSide,
        transformer: transformBtoA));

    return (connector);
  }
}

typedef DataTransformer = Stream<List<int>> Function(Stream<List<int>>);

/// Authenticates a socket using some authentication mechanism.
abstract class SocketAuthVerifier {
  /// Completes with `true` or `false` once authentication is complete.
  /// - The stream must yield everything received on the socket after
  /// authentication has completed successfully.
  /// - Upon socket listen onDone, the stream must be closed
  /// - Upon socket listen onError, the error must be written to the stream
  ///
  /// Example: (see example/socket_connector_with_authenticator.dart)
  /// ```dart
  /// class GoSocketAuthenticatorVerifier implements SocketAuthVerifier {
  ///   @override
  ///   Future<(bool, Stream<Uint8List>?)> authenticate(Socket socket) async {
  ///     Completer<(bool, Stream<Uint8List>?)> completer = Completer();
  ///     bool authenticated = false;
  ///     StreamController<Uint8List> sc = StreamController();
  ///     socket.listen((Uint8List data) {
  ///       if (authenticated) {
  ///         sc.add(data);
  ///       } else {
  ///         final message = String.fromCharCodes(data);
  ///
  ///         if (message.startsWith("go")) {
  ///           authenticated = true;
  ///           completer.complete((true, sc.stream));
  ///         }
  ///
  ///         if (message.startsWith("dontgo")) {
  ///           authenticated = false;
  ///           completer.complete((false, null));
  ///         }
  ///       }
  ///     }, onError: (error) => sc.addError(error), onDone: () => sc.close());
  ///     return completer.future;
  ///   }
  /// }
  /// ```
  Future<(bool, Stream<Uint8List>?)> authenticate(Socket socket);
}

enum SideState { open, closing, closed }

class ConnectionSide {
  SideState state = SideState.open;
  bool sender;
  Socket socket;
  late Stream<Uint8List> stream;
  late StreamSink<List<int>> sink;
  bool authenticated = false;
  BytesBuilder buffer = BytesBuilder();
  ConnectionSide? farSide;

  ConnectionSide(this.socket, this.sender) {
    sink = socket;
    stream = socket;
  }
}

class Connection {
  final ConnectionSide sideA;
  final ConnectionSide sideB;

  Connection(this.sideA, this.sideB) {
    sideA.farSide = sideB;
    sideB.farSide = sideA;
  }
}
