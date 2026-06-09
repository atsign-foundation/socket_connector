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
  late String remoteHost;
  late int remotePort;
  late DateTime timestamp;
  late Stream<Uint8List> stream;
  late StreamSink<List<int>> sink;
  bool authenticated = false;
  BytesBuilder buffer = BytesBuilder();
  Side? farSide;
  SocketAuthVerifier? socketAuthVerifier;
  DataTransformer? transformer;

  /// number of bytes written to this side's socket
  int sent = 0;

  /// number of bytes received from this side's socket
  int rcvd = 0;

  String get name => isSideA ? 'A' : 'B';

  Side(this.socket, this.isSideA, {this.socketAuthVerifier, this.transformer}) {
    timestamp = DateTime.now().toUtc();
    sink = socket;
    stream = socket;
    try {
      remoteHost = socket.remoteAddress.address;
      remotePort = socket.remotePort;
    } catch (e) {
      remoteHost = 'n/a';
      remotePort = -1;
    }
  }
}

enum SideState { open, closing, closed }

/// TCP keep-alive configuration applied to every socket that a
/// [SocketConnector] accepts or creates.
///
/// When [enable] is true, `SO_KEEPALIVE` is turned on and the per-connection
/// probe timings are tuned:
/// - probing starts after [idleSeconds] of idle time
///   (`TCP_KEEPIDLE` on Linux/Android, `TCP_KEEPALIVE` on macOS/iOS),
/// - a probe is then sent every [intervalSeconds] (`TCP_KEEPINTVL`),
/// - and the connection is dropped after [probeCount] unacknowledged probes
///   (`TCP_KEEPCNT`).
///
/// The package defaults are idle 60s, interval 10s, count 5; pass a custom
/// instance to any of the [SocketConnector] factory methods to override.
///
/// On Windows only `SO_KEEPALIVE` is set (with the system-default timings),
/// because the per-probe tuning requires the `SIO_KEEPALIVE_VALS` ioctl which
/// `dart:io` does not expose.
class SocketKeepAlive {
  /// Whether `SO_KEEPALIVE` is enabled on the socket.
  final bool enable;

  /// Seconds a connection is idle before the first keep-alive probe is sent
  /// (`TCP_KEEPIDLE` on Linux/Android, `TCP_KEEPALIVE` on macOS/iOS).
  final int idleSeconds;

  /// Seconds between successive keep-alive probes (`TCP_KEEPINTVL`).
  final int intervalSeconds;

  /// Number of unacknowledged probes before the connection is dropped
  /// (`TCP_KEEPCNT`).
  final int probeCount;

  const SocketKeepAlive({
    this.enable = true,
    this.idleSeconds = 60,
    this.intervalSeconds = 10,
    this.probeCount = 5,
  });

  /// The package-wide defaults: enabled, idle 60s, interval 10s, count 5.
  static const SocketKeepAlive defaults = SocketKeepAlive();

  /// Keep-alive turned off entirely.
  static const SocketKeepAlive disabled = SocketKeepAlive(enable: false);

  /// Applies this configuration to [socket].
  ///
  /// Each option is set independently; a failure on one (e.g. an option the
  /// running platform does not support) is reported via [onError] and does not
  /// prevent the others from being applied.
  void applyTo(Socket socket, {void Function(String message)? onError}) {
    void warn(String message) {
      if (onError != null) onError(message);
    }

    if (Platform.isMacOS || Platform.isIOS) {
      // SOL_SOCKET = 0xffff, SO_KEEPALIVE = 0x0008
      _trySet(socket, RawSocketOption.fromBool(0xffff, 0x0008, enable),
          'SO_KEEPALIVE', warn);
      if (enable) {
        // IPPROTO_TCP = 6
        _trySet(socket, RawSocketOption.fromInt(6, 0x10, idleSeconds),
            'TCP_KEEPALIVE', warn);
        _trySet(socket, RawSocketOption.fromInt(6, 0x101, intervalSeconds),
            'TCP_KEEPINTVL', warn);
        _trySet(socket, RawSocketOption.fromInt(6, 0x102, probeCount),
            'TCP_KEEPCNT', warn);
      }
    } else if (Platform.isLinux || Platform.isAndroid) {
      // SOL_SOCKET = 0x1, SO_KEEPALIVE = 0x0009
      _trySet(socket, RawSocketOption.fromBool(0x1, 0x0009, enable),
          'SO_KEEPALIVE', warn);
      if (enable) {
        // IPPROTO_TCP = 6
        _trySet(socket, RawSocketOption.fromInt(6, 4, idleSeconds),
            'TCP_KEEPIDLE', warn);
        _trySet(socket, RawSocketOption.fromInt(6, 5, intervalSeconds),
            'TCP_KEEPINTVL', warn);
        _trySet(socket, RawSocketOption.fromInt(6, 6, probeCount),
            'TCP_KEEPCNT', warn);
      }
    } else if (Platform.isWindows) {
      // Only SO_KEEPALIVE can be set via setsockopt on Windows; the per-probe
      // timings need the SIO_KEEPALIVE_VALS ioctl, which dart:io can't reach.
      _trySet(socket, RawSocketOption.fromBool(0xffff, 0x0008, enable),
          'SO_KEEPALIVE', warn);
    } else {
      warn('SocketKeepAlive: unsupported platform '
          '${Platform.operatingSystem}');
    }
  }

  void _trySet(Socket socket, RawSocketOption option, String name,
      void Function(String) warn) {
    try {
      socket.setRawOption(option);
    } catch (e) {
      warn('SocketKeepAlive: failed to set $name: $e');
    }
  }
}

class PortAndTimestamp {
  final int port;
  final DateTime timestamp;

  PortAndTimestamp(this.port, this.timestamp);

  Map<String, dynamic> toJson() => {
        'port': port,
        'timestamp': timestamp.toUtc().toIso8601String(),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PortAndTimestamp &&
          runtimeType == other.runtimeType &&
          port == other.port &&
          timestamp == other.timestamp;

  @override
  int get hashCode => Object.hash(port, timestamp);
}

class Stats {
  final Map<String, List<PortAndTimestamp>> socketsSideA = {};
  final Map<String, List<PortAndTimestamp>> socketsSideB = {};
  int numSocketPairs = 0;
  int bytesAtoB = 0;
  int bytesBtoA = 0;

  Map<String, dynamic> toJson() => {
        'socketsSideA': socketsSideA,
        'socketsSideB': socketsSideB,
        'numSocketPairs': numSocketPairs,
        'bytesAtoB': bytesAtoB,
        'bytesBtoA': bytesBtoA,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Stats &&
          runtimeType == other.runtimeType &&
          socketsSideA == other.socketsSideA &&
          socketsSideB == other.socketsSideB &&
          numSocketPairs == other.numSocketPairs &&
          bytesAtoB == other.bytesAtoB &&
          bytesBtoA == other.bytesBtoA;

  @override
  int get hashCode => Object.hash(
      socketsSideA, socketsSideB, numSocketPairs, bytesAtoB, bytesBtoA);
}
