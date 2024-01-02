import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

typedef DataTransformer = Stream<List<int>> Function(Stream<List<int>>);

/// Authenticates a socket using some authentication mechanism.
abstract class SocketAuthVerifier {
  /// Completes with `true` or `false` once authentication is complete.
  /// - The stream must yield everything received on the socket after
  /// authentication has completed successfully.
  /// - Upon socket listen onDone, the stream must be closed
  /// - Upon socket listen onError, the error must be written to the stream
  ///
  /// Example: (see example/socket_connector_with_authenticator.dart)
  /// ```dart
  /// class GoSocketAuthenticatorVerifier implements SocketAuthVerifier {
  ///   @override
  ///   Future<(bool, Stream<Uint8List>?)> authenticate(Socket socket) async {
  ///     Completer<(bool, Stream<Uint8List>?)> completer = Completer();
  ///     bool authenticated = false;
  ///     StreamController<Uint8List> sc = StreamController();
  ///     socket.listen((Uint8List data) {
  ///       if (authenticated) {
  ///         sc.add(data);
  ///       } else {
  ///         final message = String.fromCharCodes(data);
  ///
  ///         if (message.startsWith("go")) {
  ///           authenticated = true;
  ///           completer.complete((true, sc.stream));
  ///         }
  ///
  ///         if (message.startsWith("dontgo")) {
  ///           authenticated = false;
  ///           completer.complete((false, null));
  ///         }
  ///       }
  ///     }, onError: (error) => sc.addError(error), onDone: () => sc.close());
  ///     return completer.future;
  ///   }
  /// }
  /// ```
  Future<(bool, Stream<Uint8List>?)> authenticate(Socket socket);
}

enum SideState { open, closing, closed }

class ConnectionSide {
  SideState state = SideState.open;
  bool sender;
  Socket socket;
  late Stream<Uint8List> stream;
  late StreamSink<List<int>> sink;
  bool authenticated = false;
  BytesBuilder buffer = BytesBuilder();
  ConnectionSide? farSide;

  ConnectionSide(this.socket, this.sender) {
    sink = socket;
    stream = socket;
  }
}

class Connection {
  final ConnectionSide sideA;
  final ConnectionSide sideB;

  Connection(this.sideA, this.sideB) {
    sideA.farSide = sideB;
    sideB.farSide = sideA;
  }
}
