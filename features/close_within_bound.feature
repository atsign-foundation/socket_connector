Feature: A SocketConnector closes every side within a bound and reports each connection's end
  Each Connection is reported once on connectionClosedStream after both of its
  sides have been destroyed, with each side's close time and final byte counts.
  No side waits longer than closeFlushTimeout (default 30 s) for its pending
  data to be flushed before it is destroyed, so a peer that stops reading
  cannot keep a socket open, and close() frees every side within that bound.
  A relay flush toward a side begins once bufferHighWaterMark bytes have been
  written toward it since its last flush, or the flush delay (1 second) after
  the first of them.

  @race      Both sides closing at once, close() racing a side's close, and 50
             connections closing in any order: each Connection reported once,
             after both destroys, with final counts. A flush completing as the
             timer fires leaves the connection open; a fired timer is never
             undone. close() racing a flush the flush delay began frees every
             side within the bound.
  @replay    No messages cross a trust boundary here; the event is emitted at
             most once per Connection.
  @dos       A peer that stops reading, or resets while the relay's read of it
             is paused, cannot hold a side open past closeFlushTimeout. A
             connectionClosedStream nobody listens to buffers nothing. A peer
             that stops reading holds its queued bytes for at most the flush
             delay plus stalledFlushTimeout plus closeFlushTimeout, however
             few they are.
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

  Scenario: A relay flush that never completes closes its connection
    Given a paired Connection whose peer B has stopped reading
    And more than bufferHighWaterMark is queued toward side B
    When the relay's flush toward side B has not completed after stalledFlushTimeout
    Then both sides of the Connection are destroyed no later than closeFlushTimeout after that
    And connectionClosedStream emits the Connection once

  Scenario: A reader that keeps draining is not cut off
    Given a paired Connection whose peer B reads slowly but steadily
    And every relay flush toward side B completes within stalledFlushTimeout
    When the Connection carries data for longer than stalledFlushTimeout
    Then the Connection stays open

  Scenario: A stalled flush closes only its own Connection
    Given two paired Connections on one connector, and peer B of the first has stopped reading
    When the first Connection's flush toward side B passes stalledFlushTimeout
    Then the first Connection is destroyed and the second stays open

  Scenario: A peer that stops reading with less than bufferHighWaterMark queued is closed
    Given a paired Connection whose peer B has stopped reading
    When peer A sends less than bufferHighWaterMark and then nothing more
    Then both sides are destroyed no later than the flush delay plus stalledFlushTimeout plus closeFlushTimeout after the last byte reached side B
    And connectionClosedStream emits the Connection once

  Scenario: A sender that trickles cannot hold queued bytes open
    Given a paired Connection whose peer B has stopped reading
    And less than bufferHighWaterMark is queued toward side B
    When peer A sends one byte every half of the flush delay
    Then both sides are destroyed no later than the flush delay plus stalledFlushTimeout plus closeFlushTimeout after the first queued byte reached side B

  Scenario: An idle connection with nothing queued stays open
    Given a paired Connection whose peers have each read everything sent to them
    When neither peer sends anything for longer than the flush delay plus stalledFlushTimeout plus closeFlushTimeout
    Then the Connection stays open
    And the connector has no timer running for it

  Scenario: A slow reader below bufferHighWaterMark is not cut off
    Given a paired Connection whose peer B reads slowly but steadily
    And every relay flush toward side B completes within stalledFlushTimeout
    When peer A sends less than bufferHighWaterMark in each flush delay, for longer than stalledFlushTimeout
    Then the Connection stays open

  @race
  Scenario: close() during a flush begun by the flush delay frees every side within the bound
    Given a paired Connection whose peer B has stopped reading
    And a relay flush toward side B that the flush delay began
    When connector.close() is called
    Then every side is destroyed no later than closeFlushTimeout after close() began
    And no timer the connector started for the Connection is active when connectionClosedStream emits it

  Scenario: connectionClosedStream closes only once every side's socket is destroyed
    Given a side still authenticating whose pending data cannot be flushed
    When connector.close() is called
    Then connectionClosedStream closes no earlier than that side's socket is destroyed
    And no later than closeFlushTimeout after close() began

  Scenario: close() logs nothing for a side it closed while authenticating
    Given a SocketConnector with verbose false and a side whose authentication has not ended
    And connector.close() has been called
    When that side's authentication times out
    Then nothing is written to the logger

  Scenario: An authentication that fails on an open connector is still logged
    Given a SocketConnector with verbose false
    When a side's authentication fails
    Then "Authentication failed on side A" is written to the logger

  Scenario: A side B connected while close() runs is destroyed without an error line
    Given a serverToSocket connector with verbose false whose beforeJoining is still running
    And connector.close() has been called
    When beforeJoining returns
    Then side B's socket is destroyed
    And nothing is written to the logger

  Scenario: close() of a serverToServer connector writes nothing when verbose is false
    Given a serverToServer connector with verbose false
    When connector.close() is called
    Then nothing is written to the logger

  Scenario: A side whose socket fails to destroy is still reported, and its far side still closes
    Given a paired Connection whose side A socket throws from destroy()
    When peer A closes
    Then side A's closedAt is set
    And side B is destroyed no later than closeFlushTimeout after side A's close began
    And connectionClosedStream emits the Connection once
    And the failure is written to the logger
