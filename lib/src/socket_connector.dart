import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:chalkdart/chalk.dart';

typedef DataTransformer = Stream<List<int>> Function(Stream<List<int>>);

/// Authenticates a socket using some authentication mechanism.
abstract class SocketAuthVerifier {
  /// Completes with `true` or `false` once authentication is complete.
  ///
  /// The stream should yield everything received on the socket after
  /// authentication has completed successfully.
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

class SocketConnector {
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
    SocketConnector connector = SocketConnector();
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
      print('Connection on serverSocketA: ${connector._serverSocketA!.port}');
      ConnectionSide senderSide = ConnectionSide(senderSocket, true);
      unawaited(connector._handleSingleConnection(senderSide, verbose,
          socketAuthVerifier: socketAuthVerifierA));
    });

    // listen for receiver connections to the server
    connector._serverSocketB!.listen((receiverSocket) {
      print('Connection on serverSocketB: ${connector._serverSocketB!.port}');
      ConnectionSide receiverSide = ConnectionSide(receiverSocket, false);
      unawaited(connector._handleSingleConnection(receiverSide, verbose,
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

    SocketConnector connector = SocketConnector();

    // Create socket to an address and port
    Socket socket = await Socket.connect(socketAddress, socketPort);
    ConnectionSide senderSide = ConnectionSide(socket, true);

    // listen for sender connections to the server
    unawaited(connector._handleSingleConnection(senderSide, verbose,
        transformer: transformAtoB));

    // bind the socket server to an address and port
    connector._serverSocketB =
        await ServerSocket.bind(receiverBindAddress, receiverPort);

    // listen for receiver connections to the server
    connector._serverSocketB?.listen((socketB) {
      ConnectionSide receiverSide = ConnectionSide(socketB, false);
      unawaited(connector._handleSingleConnection(receiverSide, verbose,
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

    SocketConnector connector = SocketConnector();

    stderr.writeln(
        'socket_connector: Connecting to $socketAddressA:$socketPortA');
    Socket senderSocket = await Socket.connect(socketAddressA, socketPortA);
    ConnectionSide senderSide = ConnectionSide(senderSocket, true);
    unawaited(connector._handleSingleConnection(senderSide, verbose,
        transformer: transformAtoB));

    stderr.writeln(
        'socket_connector: Connecting to $socketAddressB:$socketPortB');
    Socket receiverSocket = await Socket.connect(socketAddressB, socketPortB);
    ConnectionSide receiverSide = ConnectionSide(receiverSocket, false);
    unawaited(connector._handleSingleConnection(receiverSide, verbose,
        transformer: transformBtoA));

    stderr.writeln('socket_connector: started');
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
    SocketConnector connector = SocketConnector();

    // bind to a local port to which 'senders' will connect
    connector._serverSocketA =
        await ServerSocket.bind(InternetAddress('127.0.0.1'), localServerPort);
    // listen on the local port and connect the inbound socket (the 'sender')
    connector._serverSocketA?.listen((senderSocket) {
      ConnectionSide senderSide = ConnectionSide(senderSocket, true);
      unawaited(connector._handleSingleConnection(senderSide, verbose,
          transformer: transformAtoB));
    });

    // connect to the receiver address and port
    Socket receiverSocket =
        await Socket.connect(receiverSocketAddress, receiverSocketPort);
    ConnectionSide receiverSide = ConnectionSide(receiverSocket, false);
    unawaited(connector._handleSingleConnection(receiverSide, verbose,
        transformer: transformBtoA));

    return (connector);
  }

  SocketConnector();

  ServerSocket? _serverSocketA;
  ServerSocket? _serverSocketB;

  List<ConnectionSide> authenticatedUnpairedSenders = [];
  List<ConnectionSide> authenticatedUnpairedReceivers = [];

  List<Connection> establishedConnections = [];

  Completer<bool> closedCompleter = Completer();

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
    return closedCompleter.future;
  }

  Future<void> _handleSingleConnection(final ConnectionSide thisSide, final bool verbose,
      {SocketAuthVerifier? socketAuthVerifier,
      DataTransformer? transformer}) async {
    stderr.writeln(
        ' _handleSingleConnection :'
            ' socketAuthVerifier $socketAuthVerifier'
            ' for ${thisSide.sender ? 'SENDER' : 'RECEIVER'}');

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
        stderr.writeln('Error while authenticating: $e');
        thisSide.authenticated = false;
      }
    }
    if (!thisSide.authenticated) {
      stderr
          .writeln('Authentication failed on side ${thisSide.sender ? 'A' : 'B'}');
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
      Connection c = Connection(
          authenticatedUnpairedSenders.removeAt(0),
          authenticatedUnpairedReceivers.removeAt(0));
      establishedConnections.add(c);

      for (final s in [thisSide, thisSide.farSide!]) {
        s.stream.listen((Uint8List data) async {
          if (verbose) {
            final message = String.fromCharCodes(data);
            if (s.sender) {
              print(chalk.brightGreen(
                  'A -> B : ${message.replaceAll(RegExp('[\x00-\x1F\x7F-\xFF]'), '*')}'));
            } else {
              print(chalk.brightRed(
                  'B -> A : ${message.replaceAll(RegExp('[\x00-\x1F\x7F-\xFF]'), '*')}'));
            }
          }
          s.farSide!.sink.add(data);
        }, onDone: () {
          stderr.writeln(
              'stream.onDone on side ${s.sender ? 'A' : 'B'}');
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
      print(chalk.brightBlue('Destroying side ${side.sender ? 'A' : 'B'}'));
      side.socket.destroy();
      print(chalk.brightBlue('Destroying other side socket'));
      side.farSide?.socket.destroy();

      Connection? connectionToRemove;
      for (final c in establishedConnections) {
        if (c.sideA == side || c.sideB == side) {
          print(chalk.brightBlue('Found connection to remove'));
          connectionToRemove = c;
          break;
        }
      }
      if (establishedConnections.remove(connectionToRemove)) {
        print(chalk.brightBlue('Removed connection'));
        if (establishedConnections.isEmpty) {
          print(chalk.brightBlue('Closing connector'));
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
    closedCompleter.complete(true);
  }
}
