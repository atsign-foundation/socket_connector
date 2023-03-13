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

    await Future.delayed(Duration(seconds: 10));
    print('Socket check');
    while (socketStream.closed() == false) {
      print('Socket Open');
      await Future.delayed(Duration(seconds: 5));
    }
    print('Socket Dead');
  }

  try {
    var l = await Isolate.run(connect);
  } on FormatException catch (e) {
    print(e.message);
  }
  //await Future.delayed(Duration(minutes: 60));
}
