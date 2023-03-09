import 'dart:io';

import 'package:tcp_rendezvous/tcp_rendezvous.dart';
import 'package:test/test.dart';

void main() {
  group('A group of tests', () {
    int? senderPort;
    int? receiverPort;
    late SocketStream socketStream;
    String senderBuffer = "sender";
    String receiverBuffer = "receiver";
    setUp(() async {
      socketStream = await SocketStream.bind(senderPort: 0, receiverPort: 0);
      senderPort = socketStream.senderPort();
      receiverPort = socketStream.receierPort();
    });

    test('Test Sender Port bound', () {
      expect((senderPort! > 1024) & (senderPort! < 65535), isTrue);
    });

    test('Test Receiver Port bound', () {
      expect((receiverPort! > 1024) & (receiverPort! < 65535), isTrue);
    });

    test('Test connection works', () async {
      Socket? socketSender = await Socket.connect('localhost', socketStream.senderServer!.port);
      Socket? socketReceiver = await Socket.connect('localhost', socketStream.receiverServer!.port);

      socketSender.listen((List<int> data) {
        senderBuffer = String.fromCharCodes(data);
      });

      socketReceiver.listen((List<int> data) {
        receiverBuffer = String.fromCharCodes(data);
      });

      socketSender.write('hello world');
      socketReceiver.write('hello world');
      // We need to wait for the sockets to send and receive data
      await Future.delayed(Duration(seconds: 1));
      expect((senderBuffer == "hello world") & (receiverBuffer == "hello world"), isTrue);
    });
  });
}
