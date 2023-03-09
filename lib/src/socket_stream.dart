import 'dart:io';
import 'package:tcp_rendezvous/src/handle_connection.dart';

class SocketStream {
  ServerSocket? serverSocketA;
  ServerSocket? serverSocketB;
  Socket? socketA;
  Socket? socketB;
  int connectionsA = 0;
  int connectionsB = 0;

  SocketStream(
      this.socketB, this.socketA, this.connectionsB, this.connectionsA, this.serverSocketB, this.serverSocketA);

  int? senderPort() {
    return serverSocketA?.port;
  }

  int? receierPort() {
    return serverSocketB?.port;
  }

  static Future<SocketStream> serverToServer(
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
    SocketStream socketStream = SocketStream(null, null, 0, 0, null, null);
    // bind the socket server to an address and port
    socketStream.serverSocketA = await ServerSocket.bind(senderBindAddress, serverPortA);
    // bind the socket server to an address and port
    socketStream.serverSocketB = await ServerSocket.bind(receiverBindAddress, serverPortB);

    // listen for sender connections to the server
    socketStream.serverSocketA?.listen((
      sender,
    ) {
      handleConnection(sender, true, socketStream, verbose!);
    });

    // listen for receiver connections to the server
    socketStream.serverSocketB?.listen((receiver) {
      handleConnection(receiver, false, socketStream, verbose!);
    });
    return (socketStream);
  }

  static Future<SocketStream> socketToServer(
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

    SocketStream socketStream = SocketStream(null, null, 0, 0, null, null);

    // connect socket server to an address and port
    socketStream.socketA = await Socket.connect(socketAddress, socketPort);

    // bind the socket server to an address and port
    socketStream.serverSocketB = await ServerSocket.bind(receiverBindAddress, receiverPort);

    // listen for sender connections to the server
    handleConnection(socketStream.socketA!, true, socketStream, verbose);
    // listen for receiver connections to the server
    socketStream.serverSocketB?.listen((receiver) {
      handleConnection(receiver, false, socketStream, verbose!);
    });
    return (socketStream);
  }

  static Future<SocketStream> socketToSocket(
      {required InternetAddress socketAddressA,
      required int socketPortA,
      required InternetAddress socketAddressB,
      required int socketPortB,
      bool? verbose}) async {
  
    verbose ??= false;

    SocketStream socketStream = SocketStream(null, null, 0, 0, null, null);

    // connect socket server to an address and port
    socketStream.socketA = await Socket.connect(socketAddressA, socketPortA);

    // connect socket server to an address and port
    socketStream.socketB = await Socket.connect(socketAddressB, socketPortB);

    // listen for sender connections to the server
    handleConnection(socketStream.socketA!, true, socketStream, verbose);
    // listen for receiver connections to the server
    handleConnection(socketStream.socketB!, false, socketStream, verbose);
 
    return (socketStream);
  }
}
