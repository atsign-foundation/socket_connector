# Modules

These are topics, modules, or concepts that may need to be implemented in one or
more languages.

## Data Transformer

Takes a stream (async) or buffer (sync) and transforms it into another stream
or buffer.

Example: Aes Ctr encrypt/decrypt

## Control Protocol

The control protocol which is used to manage connections at a distance.
This is needed to allow both remote sides of the endpoint to be outbound
connections, as neither side listens for sockets directly, a control socket
is needed to initiate the second outbound remote connection.
This used by NoPorts to establish both sides of a relay connection as a
substitute for multiplexing.

## Session

A session is one application layer session (e.g. one TCP tunnel connection).

## Channel

A channel is a physical socket or virtual stream which exchanges information
over the remote side. One channel may carry multiple sessions in a multiplexing
environment.

## Connector

The overall connector solution which manages sessions and channels.

## Authenticator

An authenticator for a channel.
