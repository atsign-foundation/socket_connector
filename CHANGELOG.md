## 2.1.0
- Added `multi` parameter to `SocketConnector.serverToSocket` - whether to
  create new connections on the "B" side every time there is a new "A" side
  connection to the bound server port. Also added `onConnect` parameter,
  so that callers can be informed when every new connection is made, and
  can thus take whatever action they require.

## 2.0.1
- Removed an unnecessary dependency

## 2.0.0
- Added support for requiring client sockets to be authenticated in some 
  app-defined way before they will be connected to the other side
- Added support for app-defined data transformers which can be used to 
  transform the data while sending from A to B, and vice versa. Useful for
  adding traffic encryption, for example.
- Refactored for readability
- Multiple breaking changes to improve API readability
- More documentation
- More tests

## 1.0.11
- Added close function to SocketConnector

## 1.0.10
- Small format error to get to 140/140 on pub.dev

## 1.0.9
- Improved network throughput of socket_connector

## 1.0.8

- Added connection timeout if only one side connects
## 1.0.7

- fix change log
## 1.0.6

- Bug fix with cloing sockets.
## 1.0.5

- Ready for isolates
## 1.0.4

- Formated with dart format 140/140 (I hope)
## 1.0.3

- Included dart docs and formated with dart format

## 1.0.2

- Updated library name to match src

## 1.0.1

- Improved RegEx to show as much ascii as possible when using verbose option

## 1.0.0

- Initial version.
