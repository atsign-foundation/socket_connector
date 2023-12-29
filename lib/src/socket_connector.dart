import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:chalkdart/chalk.dart';

abstract class SocketAuthVerifier {
  /// Is passed data which has been received on the socket.
  ///
  /// - If authentication cannot complete (needs more data) then
  /// should return (false, null).
  /// - If authentication is complete then should return (true, unusedData).
  /// - If authentication fails then should throw an [Exception].
  /// May write to the [socket] as required but note that it should then return
  /// if it expects more data, since the caller is listening to the
  /// socket's data stream.
  ///
  /// If returns authenticated == true, then authentication is complete
  /// irrespective of a client of being a authenticated client or not.
  (bool authenticated, Uint8List? unused) onData(Uint8List data, Socket socket);
}

class SocketConnector {
  ServerSocket? _serverSocketA;
  ServerSocket? _serverSocketB;
  Socket? socketA;
  Socket? socketB;
  int _connectionsA = 0;
  int _connectionsB = 0;
  bool isAuthenticatedSocketA = true;
  bool isAuthenticatedSocketB = true;
  BytesBuilder bufferA = BytesBuilder();
  BytesBuilder bufferB = BytesBuilder();

  SocketConnector(this.socketB, this.socketA, this._connectionsB,
      this._connectionsA, this._serverSocketB, this._serverSocketA);

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
    bool closed = false;
    await Future.delayed(Duration(seconds: 30));
    if ((_connectionsA == 0) || (_connectionsB == 0)) {
      socketA?.destroy();
      socketB?.destroy();
      // Some time for the IP stack to destroy
      await Future.delayed(Duration(seconds: 3));
    }

    if ((socketA == null) || (socketB == null)) {
      closed = true;
    }
    return (closed);
  }

  void close() {
    socketA?.destroy();
    socketB?.destroy();
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
    SocketConnector socketStream =
        SocketConnector(null, null, 0, 0, null, null);
    // bind the socket server to an address and port
    socketStream._serverSocketA =
        await ServerSocket.bind(senderBindAddress, serverPortA);
    // bind the socket server to an address and port
    socketStream._serverSocketB =
        await ServerSocket.bind(receiverBindAddress, serverPortB);

    // If we are authenticating sockets, then the authenticated flags will be
    // set to true only when authentication completes with authenticated=true
    if (socketAuthVerifierA != null) {
      socketStream.isAuthenticatedSocketA = false;
    }
    if (socketAuthVerifierB != null) {
      socketStream.isAuthenticatedSocketB = false;
    }
    // listen for sender connections to the server
    socketStream._serverSocketA!.listen((
      senderSocket,
    ) {
      print('Connection on serverSocketA: ${socketStream._serverSocketA!.port}');
      _handleSingleConnection(senderSocket, true, socketStream, verbose,
          socketAuthVerifier: socketAuthVerifierA);
    });

    // listen for receiver connections to the server
    socketStream._serverSocketB!.listen((receiverSocket) {
      print('Connection on serverSocketB: ${socketStream._serverSocketB!.port}');
      _handleSingleConnection(receiverSocket, false, socketStream, verbose,
          socketAuthVerifier: socketAuthVerifierB);
    });

    return (socketStream);
  }

  /// Binds a Server socket on a specified InternetAddress
  /// Port on which to listen can be specified but if not given a spare port will be found by the OS.
  /// Then opens socket to specified Internet Address and port
  /// Finally relays data between sockets and optionally displays contents using the verbose flag
  static Future<SocketConnector> socketToServer(
      {required InternetAddress socketAddress,
      required int socketPort,
      InternetAddress? serverAddress,
      int? receiverPort,
      bool? verbose}) async {
    InternetAddress receiverBindAddress;
    receiverPort ??= 0;
    verbose ??= false;

    serverAddress ??= InternetAddress.anyIPv4;
    receiverBindAddress = serverAddress;

    SocketConnector socketStream =
        SocketConnector(null, null, 0, 0, null, null);

    // connect socket server to an address and port
    socketStream.socketA = await Socket.connect(socketAddress, socketPort);

    // bind the socket server to an address and port
    socketStream._serverSocketB =
        await ServerSocket.bind(receiverBindAddress, receiverPort);

    // listen for sender connections to the server
    _handleSingleConnection(
        socketStream.socketA!, true, socketStream, verbose);
    // listen for receiver connections to the server
    socketStream._serverSocketB?.listen((receiver) {
      _handleSingleConnection(receiver, false, socketStream, verbose!);
    });
    return (socketStream);
  }

  /// Opens sockets specified Internet Addresses and ports
  /// Then relays data between sockets and optionally displays contents using the verbose flag
  static Future<SocketConnector> socketToSocket(
      {required InternetAddress socketAddressA,
      required int socketPortA,
      required InternetAddress socketAddressB,
      required int socketPortB,
      bool? verbose}) async {
    verbose ??= false;

    SocketConnector socketStream =
        SocketConnector(null, null, 0, 0, null, null);

    // connect socket server to an address and port
    socketStream.socketA = await Socket.connect(socketAddressA, socketPortA);

    // connect socket server to an address and port
    socketStream.socketB = await Socket.connect(socketAddressB, socketPortB);

    // listen for sender connections to the server
    _handleSingleConnection(
        socketStream.socketA!, true, socketStream, verbose);
    // listen for receiver connections to the server
    _handleSingleConnection(
        socketStream.socketB!, false, socketStream, verbose);

    return (socketStream);
  }

  /// Binds to [serverPort] on the loopback interface (127.0.0.1)
  ///
  /// Listens for a socket connection on that
  /// port and joins it to a socket connection to [receiverSocketPort]
  /// on [receiverSocketAddress]
  ///
  /// If [serverPort] is not provided then a port is chosen by the OS.
  ///
  static Future<SocketConnector> serverToSocket(
      {required InternetAddress receiverSocketAddress,
        required int receiverSocketPort,
        int localServerPort = 0,
        bool verbose = false}) async {
    SocketConnector socketStream =
    SocketConnector(null, null, 0, 0, null, null);

    // bind to a local port to which 'senders' will connect
    socketStream._serverSocketA =
    await ServerSocket.bind(InternetAddress('127.0.0.1'), localServerPort);

    // connect to the receiver address and port
    socketStream.socketB = await Socket.connect(receiverSocketAddress, receiverSocketPort);

    // listen on the local port and connect the inbound socket (the 'sender')
    socketStream._serverSocketA?.listen((sender) {
      _handleSingleConnection(sender, true, socketStream, verbose);
    });

    // connect the outbound socket (the receiver)
    _handleSingleConnection(
        socketStream.socketB!, false, socketStream, verbose);

    return (socketStream);
  }

  static Future<StreamSubscription> _handleSingleConnection(final Socket socket,
      final bool sender, final SocketConnector socketStream, final bool verbose,
      {SocketAuthVerifier? socketAuthVerifier}) async {
    print (' ***** _handleSingleConnection: socketAuthVerifier $socketAuthVerifier for ${sender ? 'SENDER' : 'RECEIVER'}');
    StreamSubscription subscription;
    if (sender) {
      // TODO This should be incremented ONLY once the socket has authenticated
      // TODO (or if there is no SocketAuthVerifier)
      socketStream._connectionsA++;
      // If another connection is detected close it
      if (socketStream._connectionsA > 1) {
        print(chalk.brightBlue('Closing this socket'));
        // TODO need to decrement connectionsA here. Call _destroySocket instead
        socket.destroy();
      } else {
        // TODO This should be set ONLY once the socket has authenticated
        // TODO (or if there is no SocketAuthVerifier)
        socketStream.socketA = socket;
      }
    } else {
      socketStream._connectionsB++;
      // If another connection is detected close it
      if (socketStream._connectionsB > 1) {
        print(chalk.brightBlue('Closing this socket'));
        // TODO need to decrement connectionsB here. Call _destroySocket instead
        socket.destroy();
      } else {
        socketStream.socketB = socket;
      }
    }

    // Defaults to true.
    // Only time this can become false is when the client needs to be authenticated and it fails the authentication.
    bool isAuthenticatedClient = true;

    // false by default set to true when socketAuthenticator is supplied and it is done with authenticating the client connecting on the socket.
    // isAuthenticationComplete becomes true, irrespective of a client authenticating itself successfully or not
    bool isAuthenticationComplete = false;

    // listen for events from the client
    subscription = socket.listen(
      // handle data from the client
      (Uint8List data) async {
        stderr.writeln(chalk.brightBlue('Received data (${data.length} bytes) from ${sender ? 'SENDER' : 'RECEIVER'}'));
        Uint8List? unusedData;
        // Authenticate the client when the socketAuthenticator is supplied
        // Dont authenticate again, when the authenticate is complete and the client is valid
        if (socketAuthVerifier != null && !isAuthenticationComplete) {
          print('\n\n*** Calling _completeAuthentication ***\n\n');
          (isAuthenticationComplete, isAuthenticatedClient, unusedData) =
              _completeAuthentication(socket, data, socketAuthVerifier);

          if(isAuthenticationComplete) {
            if (sender) {
              socketStream.isAuthenticatedSocketA = isAuthenticatedClient;
              if (isAuthenticatedClient) {
                // Process any data which has been buffered up for this socket
                stderr.writeln(chalk.brightBlue('Clearing buffered data from receiver (${socketStream.bufferA.length}) bytes)'));
                _writeData(sender, Uint8List(0), socketStream.socketA!, socketStream.isAuthenticatedSocketA, socketStream.bufferA);
              }
            } else {
              socketStream.isAuthenticatedSocketB = isAuthenticatedClient;
              if (isAuthenticatedClient) {
                // Process any data which has been buffered up for this socket
                stderr.writeln(chalk.brightBlue('Clearing buffered data from sender (${socketStream.bufferB.length}) bytes)'));
                _writeData(sender, Uint8List(0), socketStream.socketB!, socketStream.isAuthenticatedSocketB, socketStream.bufferB);
              }
            }
          }

          // If the authentication is complete and the client has not
          // been authenticated, then destroy the socket
          if (!isAuthenticatedClient && isAuthenticationComplete) {
            _destroySocket(socket, sender, socketStream);
            return;
          }

          if (unusedData == null) {
            return; // nothing more to do
          } else {
            data = unusedData; // any unusedData should be processed as normal
          }
        }


        if (sender) {
          _handleDataFromSender(data, socketStream, verbose);
        } else {
          _handleDataFromReceiver(data, socketStream, verbose);
        }
      },

      // handle errors
      onError: (error) {
        stderr.writeln('Error: $error');
        _destroySocket(socket, sender, socketStream);
      },

      // handle the client closing the connection
      onDone: () {
        if (sender) {
          socketStream._connectionsA--;
          if (socketStream._connectionsA == 0) {
            socketStream.socketB?.destroy();
            socketStream.socketB = null;
            socketStream.socketA = null;
            socketStream._serverSocketA?.close();
            socketStream._serverSocketB?.close();
          }
        } else {
          socketStream._connectionsB--;
          if (socketStream._connectionsB == 0) {
            socketStream.socketA?.destroy();
            socketStream.socketB = null;
            socketStream.socketA = null;
            socketStream._serverSocketA?.close();
            socketStream._serverSocketB?.close();
          }
        }
      },
    );
    return (subscription);
  }

  static _writeData(bool sender, Uint8List data, Socket? otherSocket, bool otherSocketIsAuthenticated, BytesBuilder buffer) {
    stderr.write('Writing data ');
    if (sender) {
      stderr.writeln('From Sender (A) to Receiver (B)');
    } else {
      stderr.writeln('From Receiver (B) to Sender (A)');
    }
    if (otherSocket == null || !otherSocketIsAuthenticated) {
      buffer.add(data);
    } else {
      buffer.add(data);
      data = buffer.takeBytes();
      try {
        otherSocket.add(data);
      } catch (e) {
        stderr.write('Socket error : ${e.toString()}');
      }
      buffer.clear();
    }
  }

  static _handleDataFromSender(
      Uint8List data, final SocketConnector socketStream, final bool verbose) {
    // If verbose flag set print contents that are printable
    if (verbose) {
      final message = String.fromCharCodes(data);
      final receiverAuthenticated = socketStream.isAuthenticatedSocketB ? 'authenticated' : 'NOT YET authenticated';
      print(chalk.brightGreen(
          'Sender:(receiver is $receiverAuthenticated):${message.replaceAll(RegExp('[\x00-\x1F\x7F-\xFF]'), '*')}'));
    }

    _writeData(true, data, socketStream.socketB, socketStream.isAuthenticatedSocketB, socketStream.bufferB);
  }

  static _handleDataFromReceiver(
      Uint8List data, final SocketConnector socketStream, final bool verbose) {
    // If verbose flag set print contents that are printable
    if (verbose) {
      final message = String.fromCharCodes(data);
      final senderAuthenticated = socketStream.isAuthenticatedSocketA ? 'authenticated' : 'NOT YET authenticated';
      print(chalk.brightRed(
          'Receiver:(sender is $senderAuthenticated):${message.replaceAll(RegExp('[\x00-\x1F\x7F-\xFF]'), '*')}'));
    }

    _writeData(false, data, socketStream.socketA, socketStream.isAuthenticatedSocketA, socketStream.bufferA);
  }

  static _destroySocket(final Socket socket, final bool sender,
      final SocketConnector socketStream) {
    socket.destroy();
    if (sender) {
      print(chalk.brightBlue('Closing sender socket'));
      socketStream._connectionsA--;
    } else {
      print(chalk.brightBlue('Closing receiver socket'));
      socketStream._connectionsB--;
    }
  }

  static (bool, bool, Uint8List?) _completeAuthentication(
      Socket socket, Uint8List data, SocketAuthVerifier socketAuthVerifier) {
    bool authenticationComplete = false;
    Uint8List? unusedData;
    bool isAuthenticatedClient = true;

    try {
      (authenticationComplete, unusedData) =
          socketAuthVerifier.onData(data, socket);
    } catch (e) {
      authenticationComplete = true;
      // When authentication fails, authenticator throws an exception.
      // This is the time to set isAuthenticatedClient to false
      isAuthenticatedClient = false;
      // authentication has failed. Destroy the socket.
      stderr.writeln('Error during socket authentication: $e');
    }

    return (authenticationComplete, isAuthenticatedClient, unusedData);
  }
}
