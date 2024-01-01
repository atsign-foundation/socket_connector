import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:socket_connector/socket_connector.dart';

void main() async {
  print("Select test scenario");
  print("1.No side authenticated        0----0");
  print("2.Both sides authenticated     0#----#0");
  print("3.Only sender authenticated    0#----0");
  print("4.Only receiver authenticated  0----#0");
  print(">");

  String? option = stdin.readLineSync();
  switch (option) {
    case "1":
      await noSideAuthenticated();
      break;

    case "2":
      await bothSidesAuthenticated();
      break;

    case "3":
      await onlySenderAuthenticated();
      break;

    case "4":
      await onlyReceiverAuthenticated();
      break;

    default:
      print("Bad option selected");
  }
}

noSideAuthenticated() async {
  SocketConnector socketStream = await SocketConnector.serverToServer(
      serverAddressA: InternetAddress.anyIPv4,
      serverAddressB: InternetAddress.anyIPv4,
      serverPortA: 9001,
      serverPortB: 8001,
      verbose: true);

  print(
      'Sender Port: ${socketStream.senderPort().toString()}  Receiver Port: ${socketStream.receiverPort().toString()}');
}

bothSidesAuthenticated() async {
  SocketConnector socketStream = await SocketConnector.serverToServer(
      serverAddressA: InternetAddress.anyIPv4,
      serverAddressB: InternetAddress.anyIPv4,
      serverPortA: 9000,
      serverPortB: 8000,
      verbose: true,
      socketAuthVerifierA: GoSocketAuthenticatorVerifier(),
      socketAuthVerifierB: GoSocketAuthenticatorVerifier());

  print(
      'Sender Port: ${socketStream.senderPort().toString()}  Receiver Port: ${socketStream.receiverPort().toString()}');
}

onlySenderAuthenticated() async {
  SocketConnector socketStream = await SocketConnector.serverToServer(
      serverAddressA: InternetAddress.anyIPv4,
      serverAddressB: InternetAddress.anyIPv4,
      serverPortA: 9000,
      serverPortB: 8000,
      verbose: true,
      socketAuthVerifierA: GoSocketAuthenticatorVerifier());

  print(
      'Sender Port: ${socketStream.senderPort().toString()}  Receiver Port: ${socketStream.receiverPort().toString()}');
}

onlyReceiverAuthenticated() async {
  SocketConnector socketStream = await SocketConnector.serverToServer(
      serverAddressA: InternetAddress.anyIPv4,
      serverAddressB: InternetAddress.anyIPv4,
      serverPortA: 9000,
      serverPortB: 8000,
      verbose: true,
      socketAuthVerifierB: GoSocketAuthenticatorVerifier());

  print(
      'Sender Port: ${socketStream.senderPort().toString()}  Receiver Port: ${socketStream.receiverPort().toString()}');
}

class GoSocketAuthenticatorVerifier implements SocketAuthVerifier {
  @override
  Future<(bool, Stream<Uint8List>?)> authenticate(Socket socket) async {
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
    });
    return completer.future;
  }
}
