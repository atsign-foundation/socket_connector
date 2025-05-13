import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:socket_connector/socket_connector.dart';

void main() async {
  Duration demoConnectorTimeout = Duration(seconds: 30);

  stdout.writeln("Select test scenario");
  stdout.writeln("1.No side authenticated        0----0");
  stdout.writeln("2.Both sides authenticated     0#----#0");
  stdout.writeln("3.Only sender authenticated    0#----0");
  stdout.writeln("4.Only receiver authenticated  0----#0");
  stdout.write("> ");

  String? option = stdin.readLineSync();
  switch (option) {
    case "1":
      SocketConnector connector = await SocketConnector.serverToServer(
        verbose: true,
        timeout: demoConnectorTimeout,
      );

      stdout.writeln('You may now telnet to'
          ' Sender Port: ${connector.sideAPort}'
          ' Receiver Port: ${connector.sideBPort}');
      stdout.writeln('There is no authentication on either side');

      await connector.done;
      break;

    case "2":
      SocketConnector connector = await SocketConnector.serverToServer(
        verbose: true,
        timeout: demoConnectorTimeout,
        socketAuthVerifierA: goAuthVerifier,
        socketAuthVerifierB: goAuthVerifier,
      );

      stdout.writeln('You may now telnet to'
          ' Sender Port: ${connector.sideAPort}'
          ' Receiver Port: ${connector.sideBPort}');
      stdout.writeln('Both sides require authentication - to authenticate,'
          ' type \'go\' ');
      await connector.done;
      break;

    case "3":
      SocketConnector connector = await SocketConnector.serverToServer(
        verbose: true,
        timeout: demoConnectorTimeout,
        socketAuthVerifierA: goAuthVerifier,
      );

      stdout.writeln('You may now telnet to'
          ' Sender Port: ${connector.sideAPort}'
          ' Receiver Port: ${connector.sideBPort}');
      stdout.writeln(
          '${connector.sideAPort} requires authentication - to authenticate,'
          ' type \'go\' ');

      await connector.done;
      break;

    case "4":
      SocketConnector connector = await SocketConnector.serverToServer(
        verbose: true,
        timeout: demoConnectorTimeout,
        socketAuthVerifierB: goAuthVerifier,
      );

      stdout.writeln('You may now telnet to'
          ' Sender Port: ${connector.sideAPort}'
          ' Receiver Port: ${connector.sideBPort}');
      stdout.writeln(
          '${connector.sideBPort} requires authentication - to authenticate,'
          ' type \'go\' ');
      await connector.done;
      break;

    default:
      stderr.writeln("Enter 1, 2, 3 or 4");
      exit(1);
  }
  exit(0);
}

Future<(bool, Stream<Uint8List>?)> goAuthVerifier(Socket socket) async {
  Completer<(bool, Stream<Uint8List>?)> completer = Completer();
  bool authenticated = false;
  StreamController<Uint8List> sc = StreamController();
  socket.listen((Uint8List data) {
    if (authenticated) {
      sc.add(data);
    } else {
      final message = String.fromCharCodes(data);

      if (message.startsWith("go")) {
        authenticated = true;
        completer.complete((true, sc.stream));
      }

      if (message.startsWith("dontgo")) {
        authenticated = false;
        completer.complete((false, null));
      }
    }
  }, onError: (error) => sc.addError(error), onDone: () => sc.close());
  return completer.future;
}
