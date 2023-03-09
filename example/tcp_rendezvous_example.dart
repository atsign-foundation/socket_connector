import 'dart:io';

import 'package:tcp_rendezvous/tcp_rendezvous.dart';

void main() async {
  SocketStream socketStream = await SocketStream.bind(
      senderAddress: InternetAddress.anyIPv4,
      receiverAddress: InternetAddress.anyIPv4,
      senderPort: 0,
      receiverPort: 0,
      verbose: true);
  print(
      'Sender Port: ${socketStream.senderPort().toString()}  Receiver Port: ${socketStream.receierPort().toString()}');
  SocketStream socketStream1 = await SocketStream.bind(
      senderAddress: InternetAddress.anyIPv4,
      receiverAddress: InternetAddress.anyIPv4,
      receiverPort: 0,
      verbose: true);
  print(
      'Sender Port: ${socketStream1.senderPort().toString()}  Receiver Port: ${socketStream1.receierPort().toString()}');

}
