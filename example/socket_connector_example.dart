import 'dart:io';

import 'package:socket_connector/socket_connector.dart';

void main() async {
  // Once running use ncat to check the sockets
  SocketConnector socketStream = await SocketConnector.serverToServer(
      serverAddressA: InternetAddress.anyIPv4,
      serverAddressB: InternetAddress.anyIPv4,
      serverPortA: 9000,
      serverPortB: 8000,
      verbose: true);
  print(
      'Sender Port: ${socketStream.senderPort().toString()}  Receiver Port: ${socketStream.receiverPort().toString()}');

// Connects to ssh on port 22 on 192.168.1.149 to port 2000 on localhost
// 'ssh -p localhost' will transport you to 192.168.1.149's sshd server
  InternetAddress? server = InternetAddress.tryParse('192.168.1.149');
  SocketConnector socketStream1 = await SocketConnector.socketToServer(
      socketAddress: server!,
      socketPort: 22,
      serverAddress: InternetAddress.anyIPv4,
      receiverPort: 2000,
      verbose: true);
  print(
      'Sender Port: ${socketStream1.senderPort().toString()}  Receiver Port: ${socketStream1.receiverPort().toString()}');
}
