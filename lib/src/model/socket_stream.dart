import 'dart:io';

class SocketStream {
  ServerSocket? senderServer;
  ServerSocket? receiverServer;
  Socket? senderSocket;
  Socket? receiverSocket;
  int senderCount = 0;
  int receiverCount = 0;

  SocketStream(this.receiverSocket, this.senderSocket, this.receiverCount,
      this.senderCount, this.receiverServer, this.senderServer);

  int? senderPort() {
    return senderServer?.port;
  }

  int? receierPort() {
   return receiverServer?.port;
  }
}
