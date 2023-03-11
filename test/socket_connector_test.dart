import 'dart:io';

import 'package:socket_connector/socket_connector.dart';
import 'package:test/test.dart';

void main() {
  group('A group of tests', () {
    int? senderPort;
    int? receiverPort;
    late SocketConnector serverToServerSocketConnector;
    late ServerSocket serverSocketTest;
    late ServerSocket socketSocketTestA;
    late ServerSocket socketSocketTestB;

    late SocketConnector socketToServerSocketConnector;
    // ignore: unused_local_variable
    late SocketConnector socketToSocketConnector;
    setUp(() async {
      //Set up for serverToServer
      serverToServerSocketConnector =
          await SocketConnector.serverToServer(serverPortA: 0, serverPortB: 0, verbose: true);
      senderPort = serverToServerSocketConnector.senderPort();
      receiverPort = serverToServerSocketConnector.receiverPort();

      //Setup for socketToServer
      serverSocketTest = await ServerSocket.bind('127.0.0.1', 0);
      socketToServerSocketConnector = await SocketConnector.socketToServer(
          socketAddress: InternetAddress('127.0.0.1'), socketPort: serverSocketTest.port, verbose: true);

      //SetUp for socketToSocket
      socketSocketTestA = await ServerSocket.bind('127.0.0.1', 0);
      socketSocketTestB = await ServerSocket.bind('127.0.0.1', 0);
      socketToSocketConnector = await SocketConnector.socketToSocket(
          socketAddressA: InternetAddress('127.0.0.1'),
          socketPortA: socketSocketTestA.port,
          socketAddressB: InternetAddress('127.0.0.1'),
          socketPortB: socketSocketTestB.port,
          verbose: true);
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
      Socket? socketReceiver = await Socket.connect('localhost', serverToServerSocketConnector.senderPort()!);
      Socket? socketSender = await Socket.connect('localhost', serverToServerSocketConnector.receiverPort()!);

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
      Socket? senderSocket = await Socket.connect('localhost', socketToServerSocketConnector.receiverPort()!);

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

    test('Test socketToSocket', () async {
      String senderBuffer = "sender";
      String receiverBuffer = "receiver";
      late Socket receiverSocketA;
      late Socket receiverSocketB;
   await Future.delayed(Duration(seconds: 1));
      socketSocketTestA.listen((socket) {
        receiverSocketA = socket;
        receiverSocketA.listen((List<int> data) {
          receiverBuffer = String.fromCharCodes(data);
        });
      });

      socketSocketTestB.listen((socket) {
        receiverSocketB = socket;
        receiverSocketB.listen((List<int> data) {
          senderBuffer = String.fromCharCodes(data);
        });
      });

   await Future.delayed(Duration(seconds: 1));
      receiverSocketA.write("hello world to sender");
      receiverSocketB.write('hello world to receiver');
      await Future.delayed(Duration(seconds: 1));



      expect((senderBuffer == "hello world to sender") & (receiverBuffer == "hello world to receiver"), isTrue);
    });
  });
}
