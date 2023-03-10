import 'dart:io';
import 'package:tcp_rendezvous/src/socket_stream.dart';

import 'package:chalkdart/chalk.dart';

void handleSingleConnection(Socket socket, bool sender, SocketStream socketStream, bool verbose) {
  List<int> buffer = [];
  if (sender) {
    socketStream.connectionsA++;
    // If another connection is detected close it
    if (socketStream.connectionsA > 1) {
      socket.destroy();
    } else {
      socketStream.socketA = socket;
    }
  } else {
    socketStream.connectionsB++;
    // If another connection is detected close it
    if (socketStream.connectionsB > 1) {
      socket.destroy();
    } else {
      socketStream.socketB = socket;
    }
  }

  // listen for events from the client
  socket.listen(
    // handle data from the client
    (List<int> data) async {
      final message = String.fromCharCodes(data);
      if (sender) {
        if (verbose) {
          print(chalk.brightGreen('Sender:${message.replaceAll(RegExp('[^A-Za-z0-9 -/]'), '*')}\n'));
        }
        if (socketStream.socketB == null) {
          buffer = (buffer + data);
        } else {
          data = (buffer + data);
          try {
            socketStream.socketB?.add(data);
          } catch (e) {
            stderr.write('Receiver Socket error : ${e.toString()}');
          }
          buffer.clear();
        }
      } else {
        if (verbose) {
          print(chalk.brightRed('Receiver:${message.replaceAll(RegExp('[^A-Za-z0-9 -/]'), '*')}\n'));
        }
        if (socketStream.socketA == null) {
          buffer = (buffer + data);
        } else {
          data = (buffer + data);
          try {
            socketStream.socketA?.add(data);
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
      socket.destroy();
      if (sender) {
        socketStream.connectionsA--;
      } else {
        socket.destroy();
        socketStream.connectionsB--;
      }
    },

    // handle the client closing the connection
    onDone: () {
      if (sender) {
        socketStream.connectionsA--;
        if (socketStream.connectionsA == 0) {
          socketStream.socketB?.destroy();
          socketStream.socketB = null;
          socketStream.socketA = null;
          socketStream.serverSocketA?.close();
          socketStream.serverSocketB?.close();
        }
      } else {
        socketStream.connectionsB--;
        if (socketStream.connectionsB == 0) {
          socketStream.socketA?.destroy();
          socketStream.socketB = null;
          socketStream.socketA = null;
          socketStream.serverSocketA?.close();
          socketStream.serverSocketB?.close();
        }
      }
    },
  );
}
