import 'dart:async';
import 'dart:io';
import 'package:chalkdart/chalk.dart';

class SocketConnector {
  ServerSocket? _serverSocketA;
  ServerSocket? _serverSocketB;
  Socket? _socketA;
  Socket? _socketB;
  int _connectionsA = 0;
  int _connectionsB = 0;

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
    if ((_connectionsA ==0) || (_connectionsB == 0)){
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

  /// Binds two Server sockets on specified Internet Addresses.
  /// Ports on which to listen can be given but if not given a spare port will be found by the OS.
  /// Finally relays data between sockets and optionaly displays contents using the verbose flag
  static Future<SocketConnector> serverToServer(
      {InternetAddress? serverAddressA,
      InternetAddress? serverAddressB,
      int? serverPortA,
      int? serverPortB,
      bool? verbose}) async {
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
      _handleSingleConnection(sender, true, socketStream, verbose!);
    });

    // listen for receiver connections to the server
    socketStream._serverSocketB?.listen((receiver) {
      _handleSingleConnection(receiver, false, socketStream, verbose!);
    });

    return (socketStream);
  }

  /// Binds a Server socket on a specified InternetAddress
  /// Port on which to listen can be specified but if not given a spare port will be found by the OS.
  /// Then opens socket to specified Internet Address and port
  /// Finally relays data between sockets and optionaly displays contents using the verbose flag
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
  /// Then relays data between sockets and optionaly displays contents using the verbose flag
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
      final bool sender, final SocketConnector socketStream, final bool verbose) async {
    List<int> buffer = [];
    StreamSubscription subscription;
    if (sender) {
      socketStream._connectionsA++;
      // If another connection is detected close it
      if (socketStream._connectionsA > 1) {
        socket.destroy();
      } else {
        socketStream._socketA = socket;
      }
    } else {
      socketStream._connectionsB++;
      // If another connection is detected close it
      if (socketStream._connectionsB > 1) {
        socket.destroy();
      } else {
        socketStream._socketB = socket;
      }
    }

    // listen for events from the client
    subscription = socket.listen(
      // handle data from the client
      (List<int> data) async {
        if (sender) {
          // If verbose flag set print contents that are printable
        //   if (verbose) {
        // final message = String.fromCharCodes(data);
        //     print(chalk.brightGreen(
        //         'Sender:${message.replaceAll(RegExp('[\x00-\x1F\x7F-\xFF]'), '*')}'));
        //   }
          if (socketStream._socketB == null) {
            buffer = (buffer + data);
          } else {
            data = (buffer + data);
            try {
              socketStream._socketB?.add(data);
            } catch (e) {
              stderr.write('Receiver Socket error : ${e.toString()}');
            }
            buffer.clear();
          }
        } else {
          // If verbose flag set print contents that are printable
          // if (verbose) {
          //   final message = String.fromCharCodes(data);
          //   print(chalk.brightRed(
          //       'Receiver:${message.replaceAll(RegExp('[\x00-\x1F\x7F-\xFF]'), '*')}'));
          // }
          if (socketStream._socketA == null) {
            buffer = (buffer + data);
          } else {
            data = (buffer + data);
            try {
              socketStream._socketA?.add(data);
            } catch (e) {
              stderr.write('Receiver Socket error : ${e.toString()}');
            }
            buffer.clear();
          }
        }
      },

      // handle errors
      onError: (error) {
        stderr.writeln('Error: $error');
        socket.destroy();
        if (sender) {
          socketStream._connectionsA--;
        } else {
          socket.destroy();
          socketStream._connectionsB--;
        }
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
}
