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
        verbose: false,
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
        verbose: false,
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
        verbose: false,
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
        verbose: false,
      );

      expect(connector.closed, false);

      await (Future.delayed(Duration(milliseconds: 6)));
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });

    test('Test ServerToServer', () async {
      int timeoutMs = 200;
      Duration timeout = Duration(milliseconds: timeoutMs);
      SocketConnector connector = await SocketConnector.serverToServer(
        portA: 0,
        portB: 0,
        timeout: timeout,
        verbose: false,
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
      await (Future.delayed(Duration(milliseconds: timeoutMs)));
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });

    test('Test socketToServer', () async {
      int timeoutMs = 100;
      // Bind to a port that SocketConnector.socketToServer can connect to
      ServerSocket testExternalServer = await ServerSocket.bind('127.0.0.1', 0);

      SocketConnector connector = await SocketConnector.socketToServer(
        addressA: testExternalServer.address,
        portA: testExternalServer.port,
        verbose: false,
        timeout: Duration(milliseconds: timeoutMs),
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
      await (Future.delayed(Duration(milliseconds: timeoutMs)));
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });

    test('Test socketToSocket', () async {
      int timeoutMs = 200;
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
        verbose: false,
        timeout: Duration(milliseconds: timeoutMs),
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
      await (Future.delayed(Duration(milliseconds: timeoutMs)));
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });

    test('Test serverToSocket single', () async {
      // Bind to a port that SocketConnector.serverToSocket can connect to
      ServerSocket testExternalServer = await ServerSocket.bind('127.0.0.1', 0);

      int timeoutMs = 100;
      SocketConnector connector = await SocketConnector.serverToSocket(
        addressB: testExternalServer.address,
        portB: testExternalServer.port,
        verbose: false,
        timeout: Duration(milliseconds: timeoutMs),
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

      Socket socketA = await Socket.connect(
        'localhost',
        connector.sideAPort!,
      );
      // Wait for SocketConnector to handle the events
      await (Future.delayed(Duration(milliseconds: 10)));
      await readyB.future;

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
      await (Future.delayed(Duration(milliseconds: timeoutMs)));
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });

    test('Test serverToSocket multi', () async {
      // Bind to a port that SocketConnector.serverToSocket can connect to
      ServerSocket testExternalServer = await ServerSocket.bind('127.0.0.1', 0);

      int serverConnections = 0;
      SocketConnector connector = await SocketConnector.serverToSocket(
          addressB: testExternalServer.address,
          portB: testExternalServer.port,
          verbose: true,
          timeout: Duration(milliseconds: 100),
          multi: true,
          beforeJoining: (Side sideA, Side sideB) {
            serverConnections++;
            print('SocketConnector.serverToSocket onConnect called back');
            sideA.transformer = aToB;
            sideB.transformer = bToA;
          });
      expect(connector.connections.isEmpty, true);

      List<String> rcvdA = [];
      List<String> rcvdB = [];
      List<Socket> bSockets = [];

      Socket? currentSocketB;
      testExternalServer.listen((socket) {
        currentSocketB = socket;
        bSockets.add(socket);
        int which = bSockets.length;
        socket.listen((List<int> data) {
          var msg = '$which: ${String.fromCharCodes(data)}';
          print('socket B ultimate destination received $msg');
          rcvdB.add(msg);
        });
      });

      expect(connector.connections.isEmpty, true);

      int howMany = 5;
      List<Socket> aSockets = [];
      for (int i = 0; i < howMany; i++) {
        Socket socketA = await Socket.connect(
          'localhost',
          connector.sideAPort!,
        );
        aSockets.add(socketA);
        // Wait for SocketConnector to handle the events
        await (Future.delayed(Duration(milliseconds: 10)));
        expect(connector.connections.isEmpty, false);

        socketA.listen((List<int> data) {
          var msg = '${aSockets.length}: ${String.fromCharCodes(data)}';
          print('socket A ultimate client received $msg');
          rcvdA.add(msg);
        });

        // Wait for the sockets to send and receive data
        await Future.delayed(Duration(milliseconds: 10));

        socketA.write('hello world');
        expect(currentSocketB != null, true);
        currentSocketB?.write('hello world');
        // Wait for the sockets to send and receive data
        await Future.delayed(Duration(milliseconds: 10));

        expect(rcvdA.last, "${aSockets.length}: from B: hello world");
        expect(rcvdB.last, "${bSockets.length}: from A: hello world");
        expect(rcvdA.length, i + 1);
        expect(rcvdB.length, i + 1);
      }

      expect(serverConnections, howMany);

      for (final s in aSockets) {
        s.destroy();
      }
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
        verbose: false,
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
      await (Future.delayed(timeout));
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });

    test('Test auth verification failure first then success', () async {
      Duration timeout = Duration(milliseconds: 200);
      SocketConnector connector = await SocketConnector.serverToServer(
        socketAuthVerifierA: goAuthVerifier,
        socketAuthVerifierB: goAuthVerifier,
        timeout: timeout,
        verbose: false,
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
      await (Future.delayed(timeout));
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });

    test('Test multiple authenticated connections', () async {
      Duration timeout = Duration(milliseconds: 200);
      SocketConnector connector = await SocketConnector.serverToServer(
        socketAuthVerifierA: goAuthVerifier,
        socketAuthVerifierB: goAuthVerifier,
        timeout: timeout,
        verbose: false,
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
          socketA.write('go');
          authedA.add(socketA);
        }
        Socket socketB = await Socket.connect(
          'localhost',
          connector.sideBPort!,
        );
        if (authedB.length < 3 && r.nextInt(5) == 4) {
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
      await (Future.delayed(timeout));
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });
  });
  group('Transformer tests', () {
    test('Test socketToServer with one string reversing transformer', () async {
      // Bind to a port that SocketConnector.socketToServer can connect to
      ServerSocket testExternalServer = await ServerSocket.bind('127.0.0.1', 0);

      var timeout = Duration(milliseconds: 100);
      SocketConnector connector = await SocketConnector.socketToServer(
        addressA: testExternalServer.address,
        portA: testExternalServer.port,
        transformAtoB: reverser,
        timeout: timeout,
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

      print('rcvdA: [$rcvdA], rcvdB: [$rcvdB]');
      expect(rcvdA, "hello world from side B");
      expect(rcvdB, reverseString("hello world from side A"));

      socketB.destroy();
      // Wait for SocketConnector to handle the events
      await (Future.delayed(timeout));
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });

    test('Test socketToSocket with two prefixing transformers', () async {
      int timeoutMs = 100;
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
        timeout: Duration(milliseconds: timeoutMs),
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

      print('rcvdA: [$rcvdA], rcvdB: [$rcvdB]');
      expect(rcvdA, "$prefixFromB hello world from side B");
      expect(rcvdB, "$prefixFromA hello world from side A");

      socketA.destroy();
      // Wait for SocketConnector to handle the events
      await (Future.delayed(Duration(milliseconds: timeoutMs)));
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });

    test('Test serverToSocket with two string reversing transformers',
        () async {
      // Bind to a port that SocketConnector.serverToSocket can connect to
      ServerSocket testExternalServer = await ServerSocket.bind('127.0.0.1', 0);

      var timeout = Duration(milliseconds: 100);
      SocketConnector connector = await SocketConnector.serverToSocket(
        addressB: testExternalServer.address,
        portB: testExternalServer.port,
        transformAtoB: reverser,
        transformBtoA: reverser,
        timeout: timeout,
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

      Socket socketA = await Socket.connect(
        'localhost',
        connector.sideAPort!,
      );
      // Wait for SocketConnector to handle the events
      await (Future.delayed(Duration(milliseconds: 10)));
      await readyB.future;
      expect(connector.connections.isEmpty, false);

      socketA.listen((List<int> data) {
        rcvdA = String.fromCharCodes(data);
      });

      socketA.write('hello world from side A');
      socketB.write('hello world from side B');
      await Future.delayed(Duration(milliseconds: 10));

      print('rcvdA: [$rcvdA], rcvdB: [$rcvdB]');
      expect(rcvdA, reverseString("hello world from side B"));
      expect(rcvdB, reverseString("hello world from side A"));

      socketA.destroy();
      // Wait for SocketConnector to handle the events
      await (Future.delayed(timeout));
      expect(connector.closed, true);
      await connector.done.timeout(Duration.zero);
    });
  });

  group('Keepalive tests', () {
    // SO_KEEPALIVE level/option differs by platform.
    RawSocketOption keepAliveOption() {
      if (Platform.isLinux || Platform.isAndroid) {
        return RawSocketOption(
            0x1, 0x0009, Uint8List(4)); // SOL_SOCKET/SO_KEEPALIVE
      }
      // macOS, iOS, Windows
      return RawSocketOption(0xffff, 0x0008, Uint8List(4));
    }

    bool keepAliveEnabled(Socket socket) {
      final value = socket.getRawOption(keepAliveOption());
      return value.any((b) => b != 0);
    }

    Future<SocketConnector> connectPair(SocketKeepAlive keepAlive) async {
      SocketConnector connector = await SocketConnector.serverToServer(
        portA: 0,
        portB: 0,
        timeout: Duration(milliseconds: 500),
        keepAlive: keepAlive,
        verbose: false,
      );
      await Socket.connect('localhost', connector.sideAPort!);
      await Socket.connect('localhost', connector.sideBPort!);
      // Wait for SocketConnector to pair them into a Connection
      await Future.delayed(Duration(milliseconds: 20));
      expect(connector.connections.length, 1);
      return connector;
    }

    test('Keepalive enabled by default on both sides', () async {
      SocketConnector connector = await connectPair(SocketKeepAlive.defaults);
      Connection c = connector.connections.first;
      expect(keepAliveEnabled(c.sideA.socket), isTrue);
      expect(keepAliveEnabled(c.sideB.socket), isTrue);
      connector.close();
      await connector.done;
    });

    test('Keepalive can be disabled via override', () async {
      SocketConnector connector = await connectPair(SocketKeepAlive.disabled);
      Connection c = connector.connections.first;
      expect(keepAliveEnabled(c.sideA.socket), isFalse);
      expect(keepAliveEnabled(c.sideB.socket), isFalse);
      connector.close();
      await connector.done;
    });

    test('SocketKeepAlive defaults are idle 60, interval 10, count 5', () {
      const k = SocketKeepAlive.defaults;
      expect(k.enable, isTrue);
      expect(k.idleSeconds, 60);
      expect(k.intervalSeconds, 10);
      expect(k.probeCount, 5);
    });
  });

  group('Backpressure tests', () {
    const int totalBytes = 32 * 1024 * 1024;
    late int savedHighWaterMark;

    setUp(() {
      savedHighWaterMark = SocketConnector.bufferHighWaterMark;
      SocketConnector.bufferHighWaterMark = 64 * 1024;
    });

    tearDown(() {
      SocketConnector.bufferHighWaterMark = savedHighWaterMark;
    });

    /// Sends [totalBytes] through a connector whose destination reader is
    /// paused, and asserts the writer is throttled (flush cannot complete)
    /// rather than the connector buffering everything in memory. Then resumes
    /// the reader and asserts every byte arrives.
    Future<void> expectThrottled({
      Stream<List<int>> Function(Stream<List<int>>)? transformAtoB,
    }) async {
      int destReceived = 0;
      StreamSubscription<Uint8List>? destSub;
      final destPaused = Completer<void>();

      final destServer =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      destServer.listen((s) {
        destSub = s.listen((d) => destReceived += d.length);
        destSub!.pause();
        destPaused.complete();
      });

      SocketConnector connector = await SocketConnector.serverToSocket(
        addressB: InternetAddress.loopbackIPv4,
        portB: destServer.port,
        transformAtoB: transformAtoB,
        verbose: false,
      );

      final writer =
          await Socket.connect(InternetAddress.loopbackIPv4, connector.sideAPort!);
      final chunk = Uint8List(64 * 1024);
      for (int sent = 0; sent < totalBytes; sent += chunk.length) {
        writer.add(chunk);
      }

      await destPaused.future;
      // With backpressure, the connector stops reading once the far socket's
      // queue passes the high-water mark, the writer's kernel buffers fill,
      // and this flush cannot complete. Without backpressure the connector
      // drains all 32 MiB into its own memory at once and flush returns
      // almost immediately. (One flush future, reused below: Socket.flush
      // keeps the sink bound while pending, so a second call would throw.)
      final flushed = writer.flush();
      bool flushCompleted = false;
      unawaited(flushed.then((_) => flushCompleted = true));
      await Future.delayed(Duration(seconds: 3));
      expect(flushCompleted, isFalse,
          reason: 'writer drained while the destination was not reading:'
              ' the connector buffered instead of throttling');

      destSub!.resume();
      await flushed;
      await writer.close();

      final deadline = DateTime.now().add(Duration(seconds: 30));
      while (destReceived < totalBytes) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Only $destReceived of $totalBytes bytes arrived');
        }
        await Future.delayed(Duration(milliseconds: 50));
      }
      expect(destReceived, totalBytes);

      connector.close();
      await destServer.close();
    }

    test('writer is throttled instead of buffering unboundedly (direct path)',
        () async {
      await expectThrottled();
    }, timeout: Timeout(Duration(seconds: 90)));

    test('writer is throttled instead of buffering unboundedly (transformer)',
        () async {
      await expectThrottled(transformAtoB: (s) => s.map((d) => d));
    }, timeout: Timeout(Duration(seconds: 90)));

    // Heavy flush churn must not lose or reorder data. The regression it
    // guards: while [Socket.flush] holds the far socket bound, an add() that
    // reached the socket threw "StreamSink is bound to a stream" and closed
    // the side mid-stream. A slow, bursty reader keeps many flushes in flight
    // while a fast writer sends many chunks; every byte must still arrive, in
    // order. (The bound-race itself is timing- and buffer-size-dependent — it
    // surfaces readily under the small socket buffers of a container and less
    // so under a host's large auto-tuned buffers — so this asserts the
    // invariant that must hold either way: no byte is lost or reordered.)
    Future<void> expectIntactUnderFlushChurn({
      Stream<List<int>> Function(Stream<List<int>>)? transformAtoB,
    }) async {
      const int chunk = 16 * 1024;
      const int chunks = 512; // 8 MiB through a 256 KiB gate -> many flushes
      SocketConnector.bufferHighWaterMark = 256 * 1024;

      final received = BytesBuilder(copy: false);
      final allReceived = Completer<void>();
      final destServer =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      destServer.listen((s) {
        final sub = s.listen((d) {
          received.add(d);
          if (received.length >= chunk * chunks && !allReceived.isCompleted) {
            allReceived.complete();
          }
        });
        // Bursty reader: repeatedly pause so the far send buffer fills and
        // flush() stays in flight, then let it drain a little.
        Timer.periodic(Duration(milliseconds: 6), (t) {
          if (allReceived.isCompleted) {
            t.cancel();
            return;
          }
          sub.pause();
          Timer(Duration(milliseconds: 3), sub.resume);
        });
      });

      final connector = await SocketConnector.serverToSocket(
        addressB: InternetAddress.loopbackIPv4,
        portB: destServer.port,
        transformAtoB: transformAtoB,
        verbose: false,
      );

      final writer = await Socket.connect(
          InternetAddress.loopbackIPv4, connector.sideAPort!);
      for (int i = 0; i < chunks; i++) {
        // Each chunk filled with its index, so truncation or reordering shows.
        writer.add(Uint8List(chunk)..fillRange(0, chunk, i & 0xff));
      }
      await writer.flush();

      await allReceived.future.timeout(Duration(seconds: 60));
      final bytes = received.takeBytes();
      expect(bytes.length, chunk * chunks, reason: 'bytes lost or truncated');
      for (int i = 0; i < chunks; i++) {
        expect(bytes[i * chunk], i & 0xff,
            reason: 'chunk $i corrupted or reordered');
      }

      await writer.close();
      connector.close();
      await destServer.close();
    }

    test('data stays intact under heavy flush churn (direct path)', () async {
      await expectIntactUnderFlushChurn();
    }, timeout: Timeout(Duration(seconds: 90)));

    test('data stays intact under heavy flush churn (transformer)', () async {
      await expectIntactUnderFlushChurn(transformAtoB: (s) => s.map((d) => d));
    }, timeout: Timeout(Duration(seconds: 90)));
  });

  group('Flush gate tests', () {
    late int savedHighWaterMark;

    setUp(() {
      savedHighWaterMark = SocketConnector.bufferHighWaterMark;
      SocketConnector.bufferHighWaterMark = 4 * 1024;
    });

    tearDown(() {
      SocketConnector.bufferHighWaterMark = savedHighWaterMark;
    });

    /// Binds [socket]'s sink for as long as the returned controller is open.
    ///
    /// That is the state any in-flight `flush()` puts the socket in, and the
    /// state the relay has to survive rather than close the side over. A real
    /// flush only holds it for as long as the OS takes to accept the queued
    /// bytes, which on a host with large socket buffers is too short to write
    /// a test against; `addStream` holds it until asked to let go.
    StreamController<List<int>> bindSink(Socket socket) {
      final holder = StreamController<List<int>>();
      unawaited(socket.addStream(holder.stream).catchError((Object e) => e));
      return holder;
    }

    test('a write onto a bound socket is replayed, and the relay keeps '
        'running afterwards', () async {
      const int chunk = 6 * 1024; // each chunk on its own crosses the mark
      final received = BytesBuilder(copy: false);
      final allArrived = Completer<void>();
      final destServer =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      destServer.listen((s) => s.listen((d) {
            received.add(d);
            if (received.length >= 2 * chunk && !allArrived.isCompleted) {
              allArrived.complete();
            }
          }));

      final connector = await SocketConnector.serverToSocket(
        addressB: InternetAddress.loopbackIPv4,
        portB: destServer.port,
        verbose: false,
      );
      final Future<Connection> established = connector.connectionStream.first;
      final writer = await Socket.connect(
          InternetAddress.loopbackIPv4, connector.sideAPort!);
      final Connection connection = await established;

      final holder = bindSink(connection.sideB.socket);
      await Future<void>.delayed(Duration(milliseconds: 100));

      writer.add(Uint8List(chunk)..fillRange(0, chunk, 0x41));
      await writer.flush();
      await Future<void>.delayed(Duration(milliseconds: 300));
      expect(received.length, 0,
          reason: 'nothing can reach the far side while its sink is bound');

      await holder.close();
      await Future<void>.delayed(Duration(milliseconds: 300));

      // The replayed chunk crosses the high water mark on its way out, which
      // starts a second flush while the source is already paused for the
      // first. A pause that never gets its own resume stops this relay
      // direction for good, and only this second chunk would notice.
      writer.add(Uint8List(chunk)..fillRange(0, chunk, 0x42));
      await writer.flush();

      await allArrived.future.timeout(Duration(seconds: 15), onTimeout: () {
        throw StateError('relay stopped after the replay:'
            ' ${received.length} of ${2 * chunk} bytes arrived');
      });
      final bytes = received.takeBytes();
      expect(bytes.length, 2 * chunk);
      expect(bytes[0], 0x41, reason: 'replayed chunk lost');
      expect(bytes[chunk], 0x42, reason: 'chunks out of order');

      await writer.close();
      connector.close();
      await destServer.close();
    }, timeout: Timeout(Duration(seconds: 60)));

  });
}

Stream<List<int>> addPrefix(Stream<List<int>> source,
    {List<int> prefix = const []}) async* {
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

String reverseString(String s) {
  return s.split('').reversed.join();
}

Stream<List<int>> reverser(Stream<List<int>> source,
    {List<int> prefix = const []}) async* {
  await for (final bytes in source) {
    yield reverseString(String.fromCharCodes(bytes)).codeUnits;
  }
}
