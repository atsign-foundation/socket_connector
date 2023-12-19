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

bothSidesAuthenticated() async{
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

onlySenderAuthenticated() async{
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

onlyReceiverAuthenticated() async{
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
  (bool authenticated, Uint8List? unused) onData(
      Uint8List data, Socket socket) {
    final message = String.fromCharCodes(data);

    if (message.startsWith("go")) {
      return (true, null);
    }

    if (message.startsWith("dontgo")) {
      throw Exception('Dont want to go');
    }

    return (false, null);
  }
}
