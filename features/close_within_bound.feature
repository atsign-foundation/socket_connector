Feature: A SocketConnector closes every side within a bound and reports each connection's end
  Each Connection is reported once on connectionClosedStream after both of its
  sides have been destroyed, with each side's close time and final byte counts.
  No side waits longer than closeFlushTimeout (default 30 s) for its pending
  data to be flushed before it is destroyed, so a peer that stops reading
  cannot keep a socket open, and close() frees every side within that bound.

  @race      Both sides closing at once, close() racing a side's close, and 50
             connections closing in any order: each Connection reported once,
             after both destroys, with final counts.
  @replay    No messages cross a trust boundary here; the event is emitted at
             most once per Connection.
  @dos       A peer that stops reading, or resets while the relay's read of it
             is paused, cannot hold a side open past closeFlushTimeout. A
             connectionClosedStream nobody listens to buffers nothing.
  @forgery / @impersonation  Consumers attribute an end by Connection identity,
             never by port, so one connection's end cannot be credited to
             another.

  Scenario: A connection whose peers both close is reported once, after both sides are destroyed
    Given a SocketConnector with multi true and one paired Connection
    When peer A closes its socket
    Then connectionClosedStream emits that Connection exactly once
    And both of its sides are destroyed when it is emitted
    And each side's closedAt is set
    And sideA.rcvd equals the bytes peer A sent and sideB.rcvd equals the bytes peer B sent

  Scenario: A peer that stops reading cannot keep its side open
    Given a paired Connection whose peer B has stopped reading with data queued for it
    When peer A closes
    Then side B is destroyed no later than closeFlushTimeout after its close began
    And connectionClosedStream emits the Connection

  Scenario: close() frees a side whose flush cannot finish
    Given a side whose flush cannot complete because its peer stopped reading
    When connector.close() is called
    Then every side is destroyed no later than closeFlushTimeout after close() began
    And done completes

  Scenario: A reset while the relay's read is paused still closes both sides
    Given peer A resets while the relay's read of A is paused by backpressure
    Then both sides are destroyed no later than closeFlushTimeout after the reset is seen
    And connectionClosedStream emits the Connection once

  Scenario: A peer that is reading receives the tail before its side is destroyed
    Given peer B is reading normally and 32 MiB is queued for it
    When peer A closes
    Then peer B receives all 32 MiB before side B is destroyed

  Scenario: Fifty connections are each reported once and correctly
    Given 50 paired Connections on one connector with multi true
    When their peers close in a random order
    Then connectionClosedStream emits 50 events, one per Connection, none repeated
    And each event's byte counts match what that Connection's own peers sent

  Scenario: Nobody listening costs nothing
    Given a SocketConnector whose connectionClosedStream has no listener
    When 1000 Connections open and close
    Then no close events are retained
