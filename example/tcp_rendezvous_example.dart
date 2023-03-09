import 'dart:io';

import 'package:tcp_rendezvous/tcp_rendezvous.dart';

void main() async {
  SocketStream socketStream = await bindSocketStream(
      senderAddress: InternetAddress('127.0.0.1'),
      receiverAddress: InternetAddress('127.0.0.1'),
      senderPort: 0,
      receiverPort: 0,
      verbose: true);
  print(
      'Sender Port: ${socketStream.senderPort().toString()}  Receiver Port: ${socketStream.receierPort().toString()}');
}
