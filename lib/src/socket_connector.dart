import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:chalkdart/chalk.dart';

abstract class SocketAuthenticator {
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
  /// If returns authenticated == true, then authentication has been successful
  (bool authenticated, Uint8List? unused) onData(Uint8List data, Socket socket);
}

class SocketConnector {
  ServerSocket? _serverSocketA;
  ServerSocket? _serverSocketB;
  Socket? _socketA;
  Socket? _socketB;
  int _connectionsA = 0;
  int _connectionsB = 0;
  bool isAuthenticatedSocketA = false;
  bool isAuthenticatedSocketB = false;

  SocketConnector(this._socketB, this._socketA, this._connectionsB,
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
      _socketA?.destroy();
      _socketB?.destroy();
      // Some time for the IP stack to destroy
      await Future.delayed(Duration(seconds: 3));
    }

    if ((_socketA == null) || (_socketB == null)) {
      closed = true;
    }
    return (closed);
  }

  void close() {
    _socketA?.destroy();
    _socketB?.destroy();
  }

  /// Binds two Server sockets on specified Internet Addresses.
  /// Ports on which to listen can be given but if not given a spare port will be found by the OS.
  /// Finally relays data between sockets and optionally displays contents using the verbose flag
  static Future<SocketConnector> serverToServer({
    InternetAddress? serverAddressA,
    InternetAddress? serverAddressB,
    int? serverPortA,
    int? serverPortB,
    bool? verbose,
    SocketAuthenticator? socketAuthenticatorA,
    SocketAuthenticator? socketAuthenticatorB,
  }) async {
    InternetAddress senderBindAddress;
    InternetAddress receiverBindAddress;
    serverPortA ??= 0;
    serverPortB ??= 0;
    verbose ??= false;
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

    // listen for sender connections to the server
    socketStream._serverSocketA?.listen((
      sender,
    ) {
      _handleSingleConnection(sender, true, socketStream, verbose!,
          socketAuthenticator: socketAuthenticatorA);
    });

    // listen for receiver connections to the server
    socketStream._serverSocketB?.listen((receiver) {
      _handleSingleConnection(receiver, false, socketStream, verbose!,
          socketAuthenticator: socketAuthenticatorB);
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
    socketStream._socketA = await Socket.connect(socketAddress, socketPort);

    // bind the socket server to an address and port
    socketStream._serverSocketB =
        await ServerSocket.bind(receiverBindAddress, receiverPort);

    // listen for sender connections to the server
    _handleSingleConnection(
        socketStream._socketA!, true, socketStream, verbose);
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
    socketStream._socketA = await Socket.connect(socketAddressA, socketPortA);

    // connect socket server to an address and port
    socketStream._socketB = await Socket.connect(socketAddressB, socketPortB);

    // listen for sender connections to the server
    _handleSingleConnection(
        socketStream._socketA!, true, socketStream, verbose);
    // listen for receiver connections to the server
    _handleSingleConnection(
        socketStream._socketB!, false, socketStream, verbose);

    return (socketStream);
  }

  static Future<StreamSubscription> _handleSingleConnection(final Socket socket,
      final bool sender, final SocketConnector socketStream, final bool verbose,
      {SocketAuthenticator? socketAuthenticator}) async {
    StreamSubscription subscription;
    if (sender) {
      socketStream._connectionsA++;
      // If another connection is detected close it
      if (socketStream._connectionsA > 1) {
        socket.destroy();
      } else {
        socketStream._socketA = socket;
      }

      // Given that we have a socketAuthenticator supplied, we will set isAuthenticatedSocketA to false
      // and set it to true only when the authentication completes and the authenticator says that it is a authenticated client
      if (socketAuthenticator != null) {
        socketStream.isAuthenticatedSocketA = false;
      }
    } else {
      socketStream._connectionsB++;
      // If another connection is detected close it
      if (socketStream._connectionsB > 1) {
        socket.destroy();
      } else {
        socketStream._socketB = socket;
      }

      // Given that we have a socketAuthenticator supplied, we will set isAuthenticatedSocketA to false
      // and set it to true only when the authentication completes and the authenticator says that it is a authenticated client
      if (socketAuthenticator != null) {
        socketStream.isAuthenticatedSocketB = false;
      }
    }

    // Defulats to true.
    // Only time this can become false is when the client needs to be authenticated and it fails the authentication.
    bool isAuthenticatedClient = true;

    // false by default set to true when socketAuthenticator is supplied and it is done with authenticating the client connecting on the socket.
    // isAuthenticationComplete becomes true, irrespective of a client authenticating itself successfully or not
    bool isAuthenticationComplete = false;

    // listen for events from the client
    subscription = socket.listen(
      // handle data from the client
      (Uint8List data) async {
        // Authenticate the client when the socketAuthenticator is supplied
        // Dont authenticate again, when the authenticate is complete and the client is valid
        if (socketAuthenticator != null && !isAuthenticationComplete) {
          (isAuthenticationComplete, isAuthenticatedClient) =
              _completeAuthentication(socket, data, socketAuthenticator);

          if(isAuthenticationComplete) {
            if (sender) {
              socketStream.isAuthenticatedSocketA = isAuthenticatedClient;
            } else {
              socketStream.isAuthenticatedSocketB = isAuthenticatedClient;
            }
          }

          // If the authentication is complete and the client is not authenticated then destroy the socket
          if (!isAuthenticatedClient && isAuthenticationComplete) {
            _destroySocket(socket, sender, socketStream);
          }

          // Return to ensure that the data is not processed before or immediately after the authentication
          return;
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
            socketStream._socketB?.destroy();
            socketStream._socketB = null;
            socketStream._socketA = null;
            socketStream._serverSocketA?.close();
            socketStream._serverSocketB?.close();
          }
        } else {
          socketStream._connectionsB--;
          if (socketStream._connectionsB == 0) {
            socketStream._socketA?.destroy();
            socketStream._socketB = null;
            socketStream._socketA = null;
            socketStream._serverSocketA?.close();
            socketStream._serverSocketB?.close();
          }
        }
      },
    );
    return (subscription);
  }

  static _writeData(Uint8List data, Socket? otherSocket) {
    var buffer = BytesBuilder();

    if (otherSocket == null) {
      buffer.add(data);
    } else {
      buffer.add(data);
      data = buffer.takeBytes();
      try {
        otherSocket.add(data);
      } catch (e) {
        stderr.write('Receiver Socket error : ${e.toString()}');
      }
      buffer.clear();
    }
  }

  static _handleDataFromSender(
      Uint8List data, final SocketConnector socketStream, final bool verbose) {
    // If verbose flag set print contents that are printable
    if (verbose) {
      final message = String.fromCharCodes(data);
      print(chalk.brightGreen(
          'Sender:${message.replaceAll(RegExp('[\x00-\x1F\x7F-\xFF]'), '*')}'));
    }
    // Do not send data if other end of the socket is not authenticated as yet
    if (socketStream.isAuthenticatedSocketB == false) {
      return;
    }
    _writeData(data, socketStream._socketB);
  }

  static _handleDataFromReceiver(
      Uint8List data, final SocketConnector socketStream, final bool verbose) {
    // If verbose flag set print contents that are printable
    if (verbose) {
      final message = String.fromCharCodes(data);
      print(chalk.brightRed(
          'Receiver:${message.replaceAll(RegExp('[\x00-\x1F\x7F-\xFF]'), '*')}'));
    }
    // Do not send data if other end of the socket is not authenticated as yet
    if (socketStream.isAuthenticatedSocketA == false) {
      return;
    }
    _writeData(data, socketStream._socketA);
  }

  static _destroySocket(final Socket socket, final bool sender,
      final SocketConnector socketStream) {
    socket.destroy();
    if (sender) {
      socketStream._connectionsA--;
    } else {
      socketStream._connectionsB--;
    }
  }

  static (bool, bool) _completeAuthentication(
      Socket socket, Uint8List data, SocketAuthenticator socketAuthenticator) {
    bool authenticationComplete = false;
    Uint8List? unusedData;
    bool isAuthenticatedClient = true;

    try {
      (authenticationComplete, unusedData) =
          socketAuthenticator.onData(data, socket);

      if (unusedData != null) {
        data = unusedData;
      }

    } catch (e) {
      authenticationComplete = true;
      // When authentication fails, authenticator throws an exception.
      // This is the time to set isAuthenticatedClient to false
      isAuthenticatedClient = false;
      // authentication has failed. Destroy the socket.
      stderr.writeln('Error during socket authentication: $e');
    }

    return (authenticationComplete, isAuthenticatedClient);
  }
}
