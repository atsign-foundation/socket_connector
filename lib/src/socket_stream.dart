import 'dart:io';
import 'package:tcp_rendezvous/src/handle_connection.dart';

class SocketStream {
  ServerSocket? senderServer;
  ServerSocket? receiverServer;
  Socket? senderSocket;
  Socket? receiverSocket;
  int senderCount = 0;
  int receiverCount = 0;

  SocketStream(this.receiverSocket, this.senderSocket, this.receiverCount,
      this.senderCount, this.receiverServer, this.senderServer);

  int? senderPort() {
    return senderServer?.port;
  }

  int? receierPort() {
   return receiverServer?.port;
  }

 static Future<SocketStream> bind(
    {InternetAddress? senderAddress,
    InternetAddress? receiverAddress,
    int? senderPort,
    int? receiverPort,
    bool? verbose}) async {
  InternetAddress senderBindAddress;
  InternetAddress receiverBindAddress;
  senderPort ??= 0;
  receiverPort ??= 0;
  verbose ??= false;
  senderAddress ??= InternetAddress.anyIPv4;
  receiverAddress ??= InternetAddress.anyIPv4;

  senderBindAddress = senderAddress;
  receiverBindAddress = senderAddress;

  //List<SocketStream> socketStreams;
  SocketStream socketStream = SocketStream(null, null, 0, 0, null, null);
  // bind the socket server to an address and port
  socketStream.senderServer = await ServerSocket.bind(senderBindAddress, senderPort);
  // bind the socket server to an address and port
  socketStream.receiverServer = await ServerSocket.bind(receiverBindAddress, receiverPort);

  // listen for sender connections to the server
  socketStream.senderServer?.listen((
    sender,
  ) {
    handleConnection(sender, true, socketStream, verbose!);
  });

  // listen for receiver connections to the server
  socketStream.receiverServer?.listen((receiver) {
    handleConnection(receiver, false, socketStream, verbose!);
  });
  return (socketStream);
}

}
