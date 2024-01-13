import 'dart:io';
import 'dart:isolate';

import 'package:socket_connector/socket_connector.dart';

void main(List<String> arguments) async {
  int portA = 8000;
  int portB = 9000;
  Future<void> connect() async {
    SocketConnector connector = await SocketConnector.serverToServer(
      addressA: InternetAddress.anyIPv4,
      addressB: InternetAddress.anyIPv4,
      portA: portA,
      portB: portB,
      verbose: true,
      timeout: Duration(milliseconds: 500),
    );
    print('${DateTime.now()} | SocketConnector ready:'
        ' senderPort: ${connector.sideAPort}'
        ' receiverPort: ${connector.sideBPort}');
    await connector.done;
    print('${DateTime.now()} | SocketConnector done');
  }

  try {
    await Isolate.run(connect);
  } on FormatException catch (e) {
    print(e.message);
  }
}
