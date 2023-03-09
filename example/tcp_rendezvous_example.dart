import 'dart:io';

import 'package:tcp_rendezvous/tcp_rendezvous.dart';

void main() async {
  SocketStream socketStream = await SocketStream.serverToServer(
      serverAddressA: InternetAddress.anyIPv4,
      serverAddressB: InternetAddress.anyIPv4,
      serverPortA: 9000,
      serverPortB: 8000,
      verbose: true);
  print(
      'Sender Port: ${socketStream.senderPort().toString()}  Receiver Port: ${socketStream.receierPort().toString()}');

  InternetAddress? server = InternetAddress.tryParse('192.168.1.149');

  SocketStream socketStream1 = await SocketStream.socketToServer(
      socketAddress: server!,
      socketPort: 22,
      serverAddress: InternetAddress.anyIPv4,
      receiverPort: 2000,
      verbose: true);
  print(
      'Sender Port: ${socketStream1.senderPort().toString()}  Receiver Port: ${socketStream1.receierPort().toString()}');
}
