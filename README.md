<h1>
  <a href="https://atsign.com#gh-light-mode-only">
    <img width=250px
     src="https://atsign.com/wp-content/uploads/2022/05/atsign-logo-horizontal-color2022.svg#gh-light-mode-only"
     alt="The Atsign Foundation">
  </a>
  <a href="https://atsign.com#gh-dark-mode-only">
    <img width=250px
     src="https://atsign.com/wp-content/uploads/2023/08/atsign-logo-horizontal-reverse2022-Color.svg#gh-dark-mode-only"
     alt="The Atsign Foundation">
  </a>
</h1>

# Socket Connector

Connect two TCP sockets and optionally display the traffic.

## Features

TCP Sockets come in two flavours - a server and a client; you have to be one or
the other. If you want to join two clients or two servers this package includes
all the tools you need to connect servers to servers and clients to clients.
Why would you need this type of service? To create a rendezvous service that two
clients can connect to for example or to join two servers with a shared client.
Also included is a client to server, this acts as a simple TCP proxy and as with
all the services you can optionally set the verbose flag in order to see
more info about what is happening, and the logTraffic flag in order to see the
readable (ascii) characters that are being transmitted and received.

The relay is created via one of four factory methods on `SocketConnector`,
depending on whether each side is a server (something connects *to* us) or a
client (we connect *out*):

| Method           | Side A        | Side B        |
|------------------|---------------|---------------|
| `serverToServer` | binds/listens | binds/listens |
| `serverToSocket` | binds/listens | connects out  |
| `socketToServer` | connects out  | binds/listens |
| `socketToSocket` | connects out  | connects out  |

Other capabilities:

- **Authentication** — pass a `SocketAuthVerifier` per side to gate a connection
  before any data is relayed. See
  [`example/socket_connector_with_authenticator.dart`](example/socket_connector_with_authenticator.dart).
- **Transformers** — pass a `DataTransformer` (`transformAtoB` / `transformBtoA`)
  to rewrite the byte stream in flight (compression, framing, etc.).
- **Stats** — `connector.stats` reports sockets created, bytes relayed each way,
  and the remote addresses seen during the session.
- **Lifecycle** — `connector.connectionStream` emits each new `Connection`, and
  `connector.done` completes when the connector closes. See
  [`example/wait_for_connector_done_example.dart`](example/wait_for_connector_done_example.dart).

## Getting started

```sh
dart pub add socket_connector
```

## Usage

The following code will open two server sockets and connect them and display any
traffic that goes between the sockets. You can test this using ncat to connect
to the two listening ports in two sessions. You will see what is typed in one
window appear in the other plus see the data via the Dart program.

The snippets below assume `import 'dart:io';` (for `InternetAddress`) and
`import 'package:socket_connector/socket_connector.dart';`.

```dart
  // Once running use ncat to check the sockets
  SocketConnector socketConnector = await SocketConnector.serverToServer(
    addressA: InternetAddress.anyIPv4,
    addressB: InternetAddress.anyIPv4,
    portA: 9000,
    portB: 8000,
    verbose: true,
    logTraffic: true,
  );
  print('Sender Port: ${socketConnector.sideAPort}'
      ' Receiver Port: ${socketConnector.sideBPort}');
```

`ncat localhost 8000`

`ncat localhost 9000`

[![asciicast](https://asciinema.org/a/cglnKVtH16DPwWfqGJXgPMCKn.svg)](https://asciinema.org/a/cglnKVtH16DPwWfqGJXgPMCKn)

### TCP keep-alive

Every socket the connector accepts or creates has TCP keep-alive enabled by
default (idle 60s, interval 10s, count 5). Override it by passing a
`SocketKeepAlive` to any of the factory methods (`serverToServer`,
`socketToServer`, `socketToSocket`, `serverToSocket`):

```dart
  SocketConnector socketConnector = await SocketConnector.serverToServer(
    addressA: InternetAddress.anyIPv4,
    addressB: InternetAddress.anyIPv4,
    portA: 9000,
    portB: 8000,
    keepAlive: SocketKeepAlive(
      idleSeconds: 30,
      intervalSeconds: 5,
      probeCount: 4,
    ),
  );
```

Use `SocketKeepAlive.disabled` to turn keep-alive off. On Windows only
`SO_KEEPALIVE` is set (with the system-default timings) because the per-probe
tuning requires an ioctl that `dart:io` does not expose.

## Additional information

Excerpted from the SocketConnector class's documentation:
```
/// Typical usage is via the [serverToServer], [serverToSocket],
/// [socketToSocket] and [socketToServer] methods which are different flavours
/// of the same functionality - to relay information from one socket to another.
///
/// - Upon creation, a [Timer] will be created for [timeout] duration. The
///   timer callback, when it executes, calls [close] if [connections]
//    is empty
/// - When an established connection is closed, [close] will be called if
///   [connections] is empty
/// - New [Connection]s are added to [connections] when both
///   [pendingA] and [pendingB] have at least one entry
/// - When [verbose] is true, log messages will be logged to [logger]
/// - When [logTraffic] is true, socket traffic will be logged to [logger]
```
