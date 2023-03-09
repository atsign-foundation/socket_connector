import 'dart:io';
import 'package:tcp_rendezvous/src/socket_stream.dart';

import 'package:chalkdart/chalk.dart';

void handleConnection(Socket client, bool sender, SocketStream socketStream, bool verbose) {
  List<int> buffer = [];
  if (sender) {
    socketStream.senderCount++;
    // If another connection is detected close it
    if (socketStream.senderCount > 1) {
      client.destroy();
    } else {
      socketStream.senderSocket = client;
    }
  } else {
    socketStream.receiverCount++;
    // If another connection is detected close it
    if (socketStream.receiverCount > 1) {
      client.destroy();
    } else {
      socketStream.receiverSocket = client;
    }
  }

  // listen for events from the client
  client.listen(
    // handle data from the client
    (List<int> data) async {
      final message = String.fromCharCodes(data);
      if (sender) {
        if (verbose) {
          print(chalk.brightGreen('Sender:${message.replaceAll(RegExp('[^A-Za-z0-9 -/]'), '*')}\n'));
        }
        if (socketStream.receiverSocket == null) {
          buffer = (buffer + data);
        } else {
          data = (buffer + data);
          try {
            socketStream.receiverSocket?.add(data);
          } catch (e) {
            stderr.write('Receiver Socket error : ${e.toString()}');
          }
          buffer.clear();
        }
      } else {
        if (verbose) {
          print(chalk.brightRed('Receiver:${message.replaceAll(RegExp('[^A-Za-z0-9 -/]'), '*')}\n'));
        }
        if (socketStream.senderSocket == null) {
          buffer = (buffer + data);
        } else {
          data = (buffer + data);
          try {
            socketStream.senderSocket?.add(data);
          } catch (e) {
            stderr.write('Receiver Socket error : ${e.toString()}');
          }
          buffer.clear();
        }
      }
    },

    // handle errors
    onError: (error) {
      stderr.writeln('Error: $error');
      client.destroy();
      if (sender) {
        socketStream.senderCount--;
      } else {
        client.destroy();
        socketStream.receiverCount--;
      }
    },

    // handle the client closing the connection
    onDone: () {
      if (sender) {
        socketStream.senderCount--;
        if (socketStream.senderCount == 0) {
          socketStream.receiverSocket?.destroy();
          socketStream.receiverSocket = null;
          socketStream.senderSocket = null;
          socketStream.senderServer?.close();
          socketStream.receiverServer?.close();
        }
      } else {
        socketStream.receiverCount--;
        if (socketStream.receiverCount == 0) {
          socketStream.senderSocket?.destroy();
          socketStream.receiverSocket = null;
          socketStream.senderSocket = null;
          socketStream.senderServer?.close();
          socketStream.receiverServer?.close();
        }
      }
    },
  );
}
