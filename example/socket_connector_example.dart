import 'dart:io';

import 'package:socket_connector/socket_connector.dart';

void main() async {
  // Once running use ncat to check the sockets
  SocketConnector socketConnector = await SocketConnector.serverToServer(
    addressA: InternetAddress.anyIPv4,
    addressB: InternetAddress.anyIPv4,
    portA: 9000,
    portB: 8000,
    verbose: true,
    logTraffic: true,
  );
  print('Sender Port: ${socketConnector.sideAPort}'
      ' Receiver Port: ${socketConnector.sideBPort}');

// Connects to ssh on port 22 on 192.168.1.149 to port 2000 on localhost
// 'ssh -p localhost' will transport you to 192.168.1.149's sshd server
  InternetAddress? server = InternetAddress.tryParse('192.168.1.149');
  SocketConnector connector1 = await SocketConnector.socketToServer(
      addressA: server!,
      portA: 22,
      addressB: InternetAddress.anyIPv4,
      portB: 2000,
      verbose: true);
  print('Sender Port: ${connector1.sideAPort}'
      ' Receiver Port: ${connector1.sideBPort}');
}
