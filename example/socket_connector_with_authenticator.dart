
import 'dart:io';
import 'dart:typed_data';

import 'package:socket_connector/socket_connector.dart';

void main() async {


  // Once running use ncat to check the sockets
  SocketConnector socketStream = await SocketConnector.serverToServer(
      serverAddressA: InternetAddress.anyIPv4,
      serverAddressB: InternetAddress.anyIPv4,
      serverPortA: 9000,
      serverPortB: 8000,
      verbose: true,
      socketAuthenticatorA: GoSocketAuthenticator(),
      socketAuthenticatorB: GoSocketAuthenticator());

  print(
      'Sender Port: ${socketStream.senderPort()
          .toString()}  Receiver Port: ${socketStream.receiverPort()
          .toString()}');
}

class GoSocketAuthenticator implements SocketAuthenticator {
  @override
  (bool authenticated, Uint8List? unused) onData(Uint8List data, Socket socket) {
      final message = String.fromCharCodes(data);

      if(message.startsWith("go")) {
          return (true, null);
      }

      if(message.startsWith("dontgo")) {
        throw Exception('Dont want to go');
      }

      return (false, null);
  }
}