import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

typedef DataTransformer = Stream<List<int>> Function(Stream<List<int>>);

/// Authenticate a socket with user-defined authentication mechanism.
///
/// - Future must complete once authentication is complete
/// - If authentication succeeded, a stream is returned which must yield
///   everything received on the socket after authentication completed
/// - If authentication failed, a stream should not be returned (and will be
///   ignored if it is)
/// - Upon socket listen onDone, the stream must be closed
/// - Upon socket listen onError, the error must be written to the stream
///
/// Example: (see example/socket_connector_with_authenticator.dart)
/// ```dart
/// Future<(bool, Stream<Uint8List>?)> goAuthVerifier(Socket socket) async {
///   Completer<(bool, Stream<Uint8List>?)> completer = Completer();
///   bool authenticated = false;
///   StreamController<Uint8List> sc = StreamController();
///   socket.listen((Uint8List data) {
///     if (authenticated) {
///       sc.add(data);
///     } else {
///       final message = String.fromCharCodes(data);
///
///       if (message.startsWith("go")) {
///         authenticated = true;
///         completer.complete((true, sc.stream));
///       }
///
///       if (message.startsWith("dontgo")) {
///         authenticated = false;
///         completer.complete((false, null));
///       }
///     }
///   }, onError: (error) => sc.addError(error), onDone: () => sc.close());
///   return completer.future;
/// }
/// ```
typedef SocketAuthVerifier = Future<(bool, Stream<Uint8List>?)> Function(
    Socket socket);

class Connection {
  final Side sideA;
  final Side sideB;

  Connection(this.sideA, this.sideB) {
    sideA.farSide = sideB;
    sideB.farSide = sideA;
  }
}

class Side {
  SideState state = SideState.open;
  bool isSideA;
  Socket socket;
  late Stream<Uint8List> stream;
  late StreamSink<List<int>> sink;
  bool authenticated = false;
  BytesBuilder buffer = BytesBuilder();
  Side? farSide;
  SocketAuthVerifier? socketAuthVerifier;
  DataTransformer? transformer;

  String get name => isSideA ? 'A' : 'B';
  Side(this.socket, this.isSideA, {this.socketAuthVerifier, this.transformer}) {
    sink = socket;
    stream = socket;
  }
}

enum SideState { open, closing, closed }
