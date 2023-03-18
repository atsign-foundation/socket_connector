import 'dart:io';
import 'dart:isolate';

import 'package:socket_connector/socket_connector.dart';

void main(List<String> arguments) async {
  int portA = 8000;
  int portB = 9000;
  Future<void> connect() async {
    SocketConnector socketStream = await SocketConnector.serverToServer(
      serverAddressA: InternetAddress.anyIPv4,
      serverAddressB: InternetAddress.anyIPv4,
      serverPortA: portA,
      serverPortB: portB,
      verbose: true,
    );
    print(
        'Sender Port: ${socketStream.senderPort().toString()}  Receiver Port: ${socketStream.receiverPort().toString()}');
    print('Socket Ready');

    print('Socket check');
    bool closed = false;
    while (closed == false) {
      print('Socket Open');
      closed = await socketStream.closed();
      print(closed);
    }
    print('Socket Dead');
  }

  try {
    await Isolate.run(connect);
  } on FormatException catch (e) {
    print(e.message);
  }
}
