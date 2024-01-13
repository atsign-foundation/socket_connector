import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:socket_connector/socket_connector.dart';
import 'package:test/test.dart';

void main() {
  group('Just socket tests', () {
    test('Test Side A Port bound', () async {
      SocketConnector connector = await SocketConnector.serverToServer(
        portA: 0,
        portB: 0,
        verbose: true,
      );
      int? portA = connector.sideAPort;

      expect(portA, isNotNull);
      expect(portA! > 1024 && portA < 65535, true);

      connector.close();
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });

    test('Test Side B Port bound', () async {
      SocketConnector connector = await SocketConnector.serverToServer(
        portA: 0,
        portB: 0,
        verbose: true,
      );
      expect(connector.sideBPort, isNotNull);
      expect(connector.sideBPort! > 1024 && connector.sideBPort! < 65535, true);

      connector.close();
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });

    test('Test timeout has passed', () async {
      SocketConnector connector = await SocketConnector.serverToServer(
        portA: 0,
        portB: 0,
        timeout: Duration(milliseconds: 5),
        verbose: true,
      );

      await Future.delayed(Duration(milliseconds: 6));
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });

    test('Test timeout has not passed', () async {
      SocketConnector connector = await SocketConnector.serverToServer(
        portA: 0,
        portB: 0,
        timeout: Duration(milliseconds: 5),
        verbose: true,
      );

      expect(connector.closed, false);

      await (Future.delayed(Duration(milliseconds: 6)));
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });

    test('Test ServerToServer', () async {
      Duration timeout = Duration(milliseconds: 200);
      SocketConnector connector = await SocketConnector.serverToServer(
        portA: 0,
        portB: 0,
        timeout: timeout,
        verbose: true,
      );
      expect(connector.connections.isEmpty, true);

      String rcvdA = '';
      String rcvdB = '';
      Socket socketA = await Socket.connect(
        'localhost',
        connector.sideAPort!,
      );
      // Wait for SocketConnector to handle the events
      await (Future.delayed(Duration(milliseconds: 10)));
      expect(connector.connections.isEmpty, true);
      expect(connector.pendingA.length, 1);
      expect(connector.pendingB.length, 0);

      Socket socketB = await Socket.connect(
        'localhost',
        connector.sideBPort!,
      );
      // Wait for SocketConnector to handle the events
      await (Future.delayed(Duration(milliseconds: 10)));
      expect(connector.connections.length, 1);
      expect(connector.pendingA.length, 0);
      expect(connector.pendingB.length, 0);

      socketB.listen((List<int> data) {
        rcvdB = String.fromCharCodes(data);
      });

      socketA.listen((List<int> data) {
        rcvdA = String.fromCharCodes(data);
      });

      socketA.write('hello world from side A');
      socketB.write('hello world from side B');
      // Wait for the sockets to send and receive data
      await Future.delayed(Duration(milliseconds: 10));

      expect(
          (rcvdA == "hello world from side B") &&
              (rcvdB == "hello world from side A"),
          isTrue);

      socketB.destroy();
      // Wait for SocketConnector to handle the events
      await (Future.delayed(Duration(milliseconds: 10)));
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });

    test('Test socketToServer', () async {
      // Bind to a port that SocketConnector.socketToServer can connect to
      ServerSocket testExternalServer = await ServerSocket.bind('127.0.0.1', 0);

      SocketConnector connector = await SocketConnector.socketToServer(
        addressA: testExternalServer.address,
        portA: testExternalServer.port,
        verbose: true,
        timeout: Duration(milliseconds: 100),
      );
      expect(connector.connections.isEmpty, true);

      String rcvdA = '';
      String rcvdB = '';

      late Socket socketA;
      Completer readyA = Completer();
      testExternalServer.listen((socket) {
        socketA = socket;
        socketA.listen((List<int> data) {
          rcvdA = String.fromCharCodes(data);
        });
        readyA.complete();
      });

      await readyA.future;
      expect(connector.connections.isEmpty, true);

      Socket socketB = await Socket.connect(
        'localhost',
        connector.sideBPort!,
      );
      // Wait for SocketConnector to handle the events
      await (Future.delayed(Duration(milliseconds: 10)));
      expect(connector.connections.isEmpty, false);

      socketB.listen((List<int> data) {
        rcvdB = String.fromCharCodes(data);
      });

      socketA.write('hello world from side A');
      socketB.write('hello world from side B');
      // Wait for the sockets to send and receive data
      await Future.delayed(Duration(milliseconds: 10));

      print('buffer A: [$rcvdA], buffer B: [$rcvdB]');
      expect(
          (rcvdA == "hello world from side B") &&
              (rcvdB == "hello world from side A"),
          isTrue);

      socketB.destroy();
      // Wait for SocketConnector to handle the events
      await (Future.delayed(Duration(milliseconds: 10)));
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });

    test('Test socketToSocket', () async {
      // Bind two ports that SocketConnector.socketToSocket can connect to
      ServerSocket testExternalServerA =
          await ServerSocket.bind('127.0.0.1', 0);
      ServerSocket testExternalServerB =
          await ServerSocket.bind('127.0.0.1', 0);

      SocketConnector connector = await SocketConnector.socketToSocket(
        addressA: testExternalServerA.address,
        portA: testExternalServerA.port,
        addressB: testExternalServerB.address,
        portB: testExternalServerB.port,
        verbose: true,
      );

      String rcvdA = '';
      String rcvdB = '';

      late Socket socketA;
      Completer readyA = Completer();
      testExternalServerA.listen((socket) {
        socketA = socket;
        readyA.complete();

        socketA.listen((List<int> data) {
          rcvdA = String.fromCharCodes(data);
        });
      });

      late Socket socketB;
      Completer readyB = Completer();
      testExternalServerB.listen((socket) {
        socketB = socket;
        readyB.complete();

        socketB.listen((List<int> data) {
          rcvdB = String.fromCharCodes(data);
        });
      });

      await readyA.future;
      await readyB.future;

      socketA.write("hello world from side A");
      socketB.write('hello world from side B');
      await Future.delayed(Duration(milliseconds: 10));

      expect(
          (rcvdA == "hello world from side B") &&
              (rcvdB == "hello world from side A"),
          isTrue);

      socketA.destroy();
      // Wait for SocketConnector to handle the events
      await (Future.delayed(Duration(milliseconds: 10)));
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });

    test('Test serverToSocket', () async {
      // Bind to a port that SocketConnector.serverToSocket can connect to
      ServerSocket testExternalServer = await ServerSocket.bind('127.0.0.1', 0);

      SocketConnector connector = await SocketConnector.serverToSocket(
        addressB: testExternalServer.address,
        portB: testExternalServer.port,
        verbose: true,
        timeout: Duration(milliseconds: 100),
      );
      expect(connector.connections.isEmpty, true);

      String rcvdA = '';
      String rcvdB = '';

      late Socket socketB;
      Completer readyB = Completer();
      testExternalServer.listen((socket) {
        socketB = socket;
        readyB.complete();
        socketB.listen((List<int> data) {
          rcvdB = String.fromCharCodes(data);
        });
      });

      await readyB.future;
      expect(connector.connections.isEmpty, true);

      Socket socketA = await Socket.connect(
        'localhost',
        connector.sideAPort!,
      );
      // Wait for SocketConnector to handle the events
      await (Future.delayed(Duration(milliseconds: 10)));
      expect(connector.connections.isEmpty, false);

      socketA.listen((List<int> data) {
        rcvdA = String.fromCharCodes(data);
      });

      socketA.write('hello world from side A');
      socketB.write('hello world from side B');
      // Wait for the sockets to send and receive data
      await Future.delayed(Duration(milliseconds: 10));

      expect(
          (rcvdA == "hello world from side B") &&
              (rcvdB == "hello world from side A"),
          isTrue);

      socketA.destroy();
      // Wait for SocketConnector to handle the events
      await (Future.delayed(Duration(milliseconds: 10)));
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });
  });
  group('Authenticator tests', () {
    Future<(bool, Stream<Uint8List>?)> goAuthVerifier(Socket socket) async {
      Completer<(bool, Stream<Uint8List>?)> completer = Completer();
      bool authenticated = false;
      StreamController<Uint8List> sc = StreamController();
      socket.listen((Uint8List data) {
        if (authenticated) {
          sc.add(data);
        } else {
          final message = String.fromCharCodes(data);

          if (message == 'go') {
            authenticated = true;
            completer.complete((true, sc.stream));
          } else {
            authenticated = false;
            completer.complete((false, null));
          }
        }
      }, onError: (error) => sc.addError(error), onDone: () => sc.close());
      return completer.future;
    }

    test('Test auth verification success', () async {
      Duration timeout = Duration(milliseconds: 200);
      SocketConnector connector = await SocketConnector.serverToServer(
        socketAuthVerifierA: goAuthVerifier,
        socketAuthVerifierB: goAuthVerifier,
        timeout: timeout,
        verbose: true,
      );
      expect(connector.connections.isEmpty, true);

      String rcvdA = '';
      String rcvdB = '';
      Socket socketA = await Socket.connect(
        'localhost',
        connector.sideAPort!,
      );
      // Wait for SocketConnector to handle the events
      await (Future.delayed(Duration(milliseconds: 10)));
      expect(connector.connections.isEmpty, true);
      expect(connector.pendingA.length, 0); // not yet authenticated
      expect(connector.pendingB.length, 0);

      socketA.write('go');
      // Wait for SocketConnector to handle the events
      await (Future.delayed(Duration(milliseconds: 10)));
      expect(connector.connections.isEmpty, true);
      expect(connector.pendingA.length, 1); // now authenticated
      expect(connector.pendingB.length, 0);

      Socket socketB = await Socket.connect(
        'localhost',
        connector.sideBPort!,
      );
      // Wait for SocketConnector to handle the events
      await (Future.delayed(Duration(milliseconds: 10)));
      expect(connector.connections.length, 0);
      expect(connector.pendingA.length, 1);
      expect(connector.pendingB.length, 0); // not yet authenticated

      socketB.write('go');
      // Wait for SocketConnector to handle the events
      await (Future.delayed(Duration(milliseconds: 10)));
      expect(connector.connections.length, 1);
      expect(connector.pendingA.length, 0);
      expect(connector.pendingB.length, 0);

      socketB.listen((List<int> data) {
        rcvdB = String.fromCharCodes(data);
      });

      socketA.listen((List<int> data) {
        rcvdA = String.fromCharCodes(data);
      });

      socketA.write('hello world from side A');
      socketB.write('hello world from side B');
      // Wait for the sockets to send and receive data
      await Future.delayed(Duration(milliseconds: 10));

      expect(
          (rcvdA == "hello world from side B") &&
              (rcvdB == "hello world from side A"),
          isTrue);

      socketB.destroy();
      // Wait for SocketConnector to handle the events
      await (Future.delayed(Duration(milliseconds: 10)));
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });

    test('Test auth verification failure first then success', () async {
      Duration timeout = Duration(milliseconds: 200);
      SocketConnector connector = await SocketConnector.serverToServer(
        socketAuthVerifierA: goAuthVerifier,
        socketAuthVerifierB: goAuthVerifier,
        timeout: timeout,
        verbose: true,
      );
      expect(connector.connections.isEmpty, true);

      // Make an authenticated connection to side A
      Socket socketA = await Socket.connect(
        'localhost',
        connector.sideAPort!,
      );
      socketA.write('go');
      await (Future.delayed(Duration(milliseconds: 10)));
      expect(connector.connections.length, 0);
      expect(connector.pendingA.length, 1);
      expect(connector.pendingB.length, 0);

      // Make a few unauthenticated connections to side A
      for (int i = 0; i < 3; i++) {
        Socket nopeSocketA = await Socket.connect(
          'localhost',
          connector.sideAPort!,
        );
        nopeSocketA.write('nope');
      }
      await (Future.delayed(Duration(milliseconds: 10)));
      // nothing should have changed
      expect(connector.connections.length, 0);
      expect(connector.pendingA.length, 1);
      expect(connector.pendingB.length, 0);

      // Make a few unauthenticated connections to side B
      for (int i = 0; i < 3; i++) {
        Socket nopeSocketB = await Socket.connect(
          'localhost',
          connector.sideBPort!,
        );
        nopeSocketB.write('nope');
      }
      await (Future.delayed(Duration(milliseconds: 10)));
      // nothing should have changed
      expect(connector.connections.length, 0);
      expect(connector.pendingA.length, 1);
      expect(connector.pendingB.length, 0);

      Socket socketB = await Socket.connect(
        'localhost',
        connector.sideBPort!,
      );
      socketB.write('go');
      await (Future.delayed(Duration(milliseconds: 10)));
      // Now we expect there to be a valid connection
      expect(connector.connections.length, 1);
      expect(connector.pendingA.length, 0);
      expect(connector.pendingB.length, 0);

      String rcvdB = '';
      socketB.listen((List<int> data) {
        rcvdB = String.fromCharCodes(data);
      });

      String rcvdA = '';
      socketA.listen((List<int> data) {
        rcvdA = String.fromCharCodes(data);
      });

      socketA.write('hello world from side A');
      socketB.write('hello world from side B');
      // Wait for the sockets to send and receive data
      await Future.delayed(Duration(milliseconds: 10));

      expect(
          (rcvdA == "hello world from side B") &&
              (rcvdB == "hello world from side A"),
          isTrue);

      socketB.destroy();
      // Wait for SocketConnector to handle the events
      await (Future.delayed(Duration(milliseconds: 10)));
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });

    test('Test multiple authenticated connections', () async {
      Duration timeout = Duration(milliseconds: 200);
      SocketConnector connector = await SocketConnector.serverToServer(
        socketAuthVerifierA: goAuthVerifier,
        socketAuthVerifierB: goAuthVerifier,
        timeout: timeout,
        verbose: true,
      );
      expect(connector.connections.isEmpty, true);

      List<Socket> authedA = [];
      List<Socket> authedB = [];

      final r = Random();
      while (authedA.length < 3 || authedB.length < 3) {
        // Create new sockets to side A and side B
        // Randomly authenticate them 1 time out of 5 until we have 3
        // verified connections on both sides
        Socket socketA = await Socket.connect(
          'localhost',
          connector.sideAPort!,
        );
        if (authedA.length < 3 && r.nextInt(5) == 4) {
          print('adding to authedA');
          socketA.write('go');
          authedA.add(socketA);
        }
        Socket socketB = await Socket.connect(
          'localhost',
          connector.sideBPort!,
        );
        if (authedB.length < 3 && r.nextInt(5) == 4) {
          print('adding to authedB');
          socketB.write('go');
          authedB.add(socketB);
        }
      }
      await (Future.delayed(Duration(milliseconds: 10)));
      expect(connector.connections.length, 3);
      expect(connector.pendingA.length, 0);
      expect(connector.pendingB.length, 0);

      Map<Socket, String> rcvdA = {};
      Map<Socket, String> rcvdB = {};
      int i = 0;
      for (Socket a in authedA) {
        a.write('hello world from side A, socket ${++i}');
        a.listen((List<int> data) {
          rcvdA[a] = String.fromCharCodes(data);
        });
      }
      i = 0;
      for (Socket b in authedB) {
        b.write('hello world from side B, socket ${++i}');
        b.listen((List<int> data) {
          rcvdB[b] = String.fromCharCodes(data);
        });
      }
      await Future.delayed(Duration(milliseconds: 10));

      i = 0;
      for (Socket a in authedA) {
        expect(rcvdA[a], 'hello world from side B, socket ${++i}');
      }
      i = 0;
      for (Socket b in authedB) {
        expect(rcvdB[b], 'hello world from side A, socket ${++i}');
      }

      await (Future.delayed(Duration(milliseconds: 10)));
      expect(connector.closed, false);

      authedA[0].destroy();
      authedA[1].destroy();
      await (Future.delayed(Duration(milliseconds: 10)));
      expect(connector.closed, false);

      authedB[2].destroy();
      await (Future.delayed(Duration(milliseconds: 10)));
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });
  });
  group('Transformer tests', () {
    test('Test socketToServer with one string reversing transformer', () async {
      // Bind to a port that SocketConnector.socketToServer can connect to
      ServerSocket testExternalServer = await ServerSocket.bind('127.0.0.1', 0);

      SocketConnector connector = await SocketConnector.socketToServer(
        addressA: testExternalServer.address,
        portA: testExternalServer.port,
        transformAtoB: reverser,
        timeout: Duration(milliseconds: 100),
      );
      expect(connector.connections.isEmpty, true);

      String rcvdA = '';
      String rcvdB = '';

      late Socket socketA;
      Completer readyA = Completer();
      testExternalServer.listen((socket) {
        socketA = socket;
        socketA.listen((List<int> data) {
          rcvdA = String.fromCharCodes(data);
        });
        readyA.complete();
      });

      await readyA.future;
      expect(connector.connections.isEmpty, true);

      Socket socketB = await Socket.connect(
        'localhost',
        connector.sideBPort!,
      );
      // Wait for SocketConnector to handle the events
      await (Future.delayed(Duration(milliseconds: 10)));
      expect(connector.connections.isEmpty, false);

      socketB.listen((List<int> data) {
        rcvdB = String.fromCharCodes(data);
      });

      socketA.write('hello world from side A');
      socketB.write('hello world from side B');
      // Wait for the sockets to send and receive data
      await Future.delayed(Duration(milliseconds: 10));

      print ('rcvdA: [$rcvdA], rcvdB: [$rcvdB]');
      expect(rcvdA, "hello world from side B");
      expect(rcvdB, reverseString("hello world from side A"));

      socketB.destroy();
      // Wait for SocketConnector to handle the events
      await (Future.delayed(Duration(milliseconds: 10)));
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });

    test('Test socketToSocket with two prefixing transformers', () async {
      // Bind two ports that SocketConnector.socketToSocket can connect to
      ServerSocket testExternalServerA =
      await ServerSocket.bind('127.0.0.1', 0);
      ServerSocket testExternalServerB =
      await ServerSocket.bind('127.0.0.1', 0);

      SocketConnector connector = await SocketConnector.socketToSocket(
        addressA: testExternalServerA.address,
        portA: testExternalServerA.port,
        transformAtoB: aToB,
        addressB: testExternalServerB.address,
        portB: testExternalServerB.port,
        transformBtoA: bToA,
      );

      String rcvdA = '';
      String rcvdB = '';

      late Socket socketA;
      Completer readyA = Completer();
      testExternalServerA.listen((socket) {
        socketA = socket;
        readyA.complete();

        socketA.listen((List<int> data) {
          rcvdA = String.fromCharCodes(data);
        });
      });

      late Socket socketB;
      Completer readyB = Completer();
      testExternalServerB.listen((socket) {
        socketB = socket;
        readyB.complete();

        socketB.listen((List<int> data) {
          rcvdB = String.fromCharCodes(data);
        });
      });

      await readyA.future;
      await readyB.future;

      socketA.write("hello world from side A");
      socketB.write('hello world from side B');
      await Future.delayed(Duration(milliseconds: 10));

      print ('rcvdA: [$rcvdA], rcvdB: [$rcvdB]');
      expect(rcvdA, "$prefixFromB hello world from side B");
      expect(rcvdB, "$prefixFromA hello world from side A");

      socketA.destroy();
      // Wait for SocketConnector to handle the events
      await (Future.delayed(Duration(milliseconds: 10)));
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });

    test('Test serverToSocket with two string reversing transformers', () async {
      // Bind to a port that SocketConnector.serverToSocket can connect to
      ServerSocket testExternalServer = await ServerSocket.bind('127.0.0.1', 0);

      SocketConnector connector = await SocketConnector.serverToSocket(
        addressB: testExternalServer.address,
        portB: testExternalServer.port,
        transformAtoB: reverser,
        transformBtoA: reverser,
        timeout: Duration(milliseconds: 100),
      );
      expect(connector.connections.isEmpty, true);

      String rcvdA = '';
      String rcvdB = '';

      late Socket socketB;
      Completer readyB = Completer();
      testExternalServer.listen((socket) {
        socketB = socket;
        readyB.complete();
        socketB.listen((List<int> data) {
          rcvdB = String.fromCharCodes(data);
        });
      });

      await readyB.future;
      expect(connector.connections.isEmpty, true);

      Socket socketA = await Socket.connect(
        'localhost',
        connector.sideAPort!,
      );
      // Wait for SocketConnector to handle the events
      await (Future.delayed(Duration(milliseconds: 10)));
      expect(connector.connections.isEmpty, false);

      socketA.listen((List<int> data) {
        rcvdA = String.fromCharCodes(data);
      });

      socketA.write('hello world from side A');
      socketB.write('hello world from side B');
      await Future.delayed(Duration(milliseconds: 10));

      print ('rcvdA: [$rcvdA], rcvdB: [$rcvdB]');
      expect(rcvdA, reverseString("hello world from side B"));
      expect(rcvdB, reverseString("hello world from side A"));

      socketA.destroy();
      // Wait for SocketConnector to handle the events
      await (Future.delayed(Duration(milliseconds: 10)));
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });
  });
}

Stream<List<int>> addPrefix(Stream<List<int>> source, {List<int> prefix = const []}) async* {
  await for (final bytes in source) {
    final List<int> l = List.from(prefix);
    l.addAll(bytes);
    yield l;
  }
}
var prefixFromA = 'from A:';
Stream<List<int>> aToB(Stream<List<int>> source) {
  return addPrefix(source, prefix: '$prefixFromA '.codeUnits);
}
var prefixFromB = 'from B:';
Stream<List<int>> bToA(Stream<List<int>> source) {
  return addPrefix(source, prefix: '$prefixFromB '.codeUnits);
}

String reverseString (String s) {
  return s.split('').reversed.join();
}
Stream<List<int>> reverser(Stream<List<int>> source, {List<int> prefix = const []}) async* {
  await for (final bytes in source) {
    yield reverseString(String.fromCharCodes(bytes)).codeUnits;
  }
}
