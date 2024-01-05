<h1><a href="https://atsign.com#gh-light-mode-only"><img width=250px
src="https://atsign.com/wp-content/uploads/2022/05/atsign-logo-horizontal-color2022.svg#gh-light-mode-only"
alt="The Atsign Foundation"></a>
<a href="https://atsign.com#gh-dark-mode-only"><img width=250px
src="https://atsign.com/wp-content/uploads/2023/08/atsign-logo-horizontal-reverse2022-Color.svg#gh-dark-mode-only"
alt="The Atsign Foundation"></a></h1>

# Socket Connector

Connect two TCP sockets and optionally display the traffic.

## Features

TCP Sockets come in two flavours a server and a client, you have to be one or
the other. If you want to join two clients or two servers this package
includes all the tools you need. to connect servers to servers and clients to
clients. Why would you need this type of service? To create a rendezvous
service that two clients can connect to for example or to join two servers
with a shared client. Also included is a client to server, this acts as a
simple TCP proxy and as with all the services you can optionally set the
verbose flag and the readable (ascii) characters that are being transmitted
and received will be displayed.

## Getting started

dart pub add socket_connector

## Usage

The following code will open two server sockets and connect them and display
any traffic that goes between the sockets. You can test this using ncat to
connect to the two listening ports in two sessions. You will see what is typed
in one window appear in the other plus see the data on at the dart program.

[![asciicast](https://asciinema.org/a/cglnKVtH16DPwWfqGJXgPMCKn.svg)](https://asciinema.org/a/cglnKVtH16DPwWfqGJXgPMCKn)

`ncat localhost 8000`

`ncat localhost 9000`

```dart
SocketConnector socketStream = await SocketConnector.serverToServer(
      serverAddressA: InternetAddress.anyIPv4,
      serverAddressB: InternetAddress.anyIPv4,
      serverPortA: 9000,
      serverPortB: 8000,
      verbose: true);
  print(
      'Sender Port: ${socketStream.senderPort().toString()}  Receiver Port: ${socketStream.receiverPort().toString()}');
      }
```

## Additional information

TODO: All SocketConnectors only acceot a single session currently, so there
is one type of connection that is currently missing which is server to socket
which could allow separate sessions as clients connect.
