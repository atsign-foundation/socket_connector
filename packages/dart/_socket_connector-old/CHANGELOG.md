## 2.3.3

- fix: ensure serverToSocket handles sockets in strict sequence as they are
  accepted
- fix: ensure that, when one side is closed, all data received from that side 
  has been delivered to the other side before closing the other side

## 2.3.2

- fix: stability under load
  - ensure that socket.done is handled in all cases
  - check a side's state before attempting to write to that side's socket

## 2.3.1

- fix: correctly handle situation where a socket has been closed but the other
  side is still writing to it

## 2.3.0

- feat: Add `authTimeout` property to SocketConnector. Previously this was
  hard-coded to 5 seconds which is a bit restrictive for slow network
  connections. It now defaults to 30 seconds but may be set at time of
  construction
- feat: added `authTimeout` parameter to `serverToServer`; this is provided
  to the SocketConnector constructor
- feat: added `backlog` parameter to `serverToServer`; this is provided to
  the ServerSocket.bind call
- feat: added `backlog` parameter to `serverToSocket`; this is provided to
  the ServerSocket.bind call
- fix: reordered some code in `_destroySide` so it handles internal state
  before trying to destroy sockets
- fix: added `catchError` blocks for everywhere we're calling 
  `handleSingleConnection` when wrapped in `unawaited`
- More logging (when in verbose mode)

## 2.2.0

- feat: Enhance serverToSocket adding optional parameter `beforeJoining` which
  will be called before a socket pair is actually joined together. Thus,
  different transformers can be used for each socket pair.

## 2.1.0

- Added `multi` parameter to `SocketConnector.serverToSocket` - whether to
  create new connections on the "B" side every time there is a new "A" side
  connection to the bound server port. Also added `onConnect` parameter,
  so that callers can be informed when every new connection is made, and
  can thus take whatever action they require.
- feat: Added grace period so that SocketConnector doesn't close until both
  (a) initial timeout has expired and (b) number of established connections
  is zero or has dropped to zero

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

- Bug fix with closing sockets.

## 1.0.5

- Ready for isolates

## 1.0.4

- Formatted with dart format 140/140 (I hope)

## 1.0.3

- Included dart docs and formatted with dart format

## 1.0.2

- Updated library name to match src

## 1.0.1

- Improved RegEx to show as much ascii as possible when using verbose option

## 1.0.0

- Initial version.
