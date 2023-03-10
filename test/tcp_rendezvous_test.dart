import 'dart:io';

import 'package:tcp_rendezvous/tcp_rendezvous.dart';
import 'package:test/test.dart';

void main() {
  group('A group of tests', () {
    int? senderPort;
    int? receiverPort;
    late SocketStream socketStream;
    late ServerSocket serverSocketTest;

    late SocketStream socketStreamServerToServer;
    setUp(() async {
      //Set up for serverToServer
      socketStream = await SocketStream.serverToServer(serverPortA: 0, serverPortB: 0);
      senderPort = socketStream.senderPort();
      receiverPort = socketStream.receierPort();

      //Setup for socketToServer
      serverSocketTest = await ServerSocket.bind('127.0.0.1', 0);
      socketStreamServerToServer = await SocketStream.socketToServer(
          socketAddress: InternetAddress('127.0.0.1'), socketPort: serverSocketTest.port);
    });

    test('Test Sender Port bound', () {
      expect((senderPort! > 1024) & (senderPort! < 65535), isTrue);
    });

    test('Test Receiver Port bound', () {
      expect((receiverPort! > 1024) & (receiverPort! < 65535), isTrue);
    });

    test('Test ServerToServer', () async {
      String senderBuffer = "sender";
      String receiverBuffer = "receiver";
      Socket? socketSender = await Socket.connect('localhost', socketStream.senderPort()!);
      Socket? socketReceiver = await Socket.connect('localhost', socketStream.receierPort()!);

      socketSender.listen((List<int> data) {
        senderBuffer = String.fromCharCodes(data);
      });

      socketReceiver.listen((List<int> data) {
        receiverBuffer = String.fromCharCodes(data);
      });

      socketSender.write('hello world to receiver');
      socketReceiver.write('hello world to sender');
      // We need to wait for the sockets to send and receive data
      await Future.delayed(Duration(seconds: 1));
      expect((senderBuffer == "hello world to sender") & (receiverBuffer == "hello world to receiver"), isTrue);
    });

    test('Test socketToServer', () async {
      String senderBuffer = "sender";
      String receiverBuffer = "receiver";

      late Socket receiverSocket;
      Socket? senderSocket = await Socket.connect('localhost', socketStreamServerToServer.receierPort()!);

      senderSocket.listen((List<int> data) {
        senderBuffer = String.fromCharCodes(data);
      });

      handleSocket(socket) async {
        receiverSocket = socket;
        receiverSocket.listen((List<int> data) {
          receiverBuffer = String.fromCharCodes(data);
        });
      }

      serverSocketTest.listen((socket) {
        handleSocket(socket);
      });

      senderSocket.write('hello world to receiver');
      // We need to wait for the sockets to send and receive data
      await Future.delayed(Duration(seconds: 1));
      receiverSocket.write('hello world to sender');
      // We need to wait for the sockets to send and receive data
      await Future.delayed(Duration(seconds: 1));

      expect((senderBuffer == "hello world to sender") & (receiverBuffer == "hello world to receiver"), isTrue);
    });
  });
}
