import "package:pigeon/pigeon.dart";

/// To generate bindings from this file run `dart run pigeon --input pigeon_spec.dart`
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/native_method_channel_spec.g.dart',
    dartOptions: DartOptions(),
    // cppOptions: CppOptions(namespace: 'pigeon_example'),
    // cppHeaderOut: 'windows/runner/messages.g.h',
    // cppSourceOut: 'windows/runner/messages.g.cpp',
    // gobjectHeaderOut: 'linux/messages.g.h',
    // gobjectSourceOut: 'linux/messages.g.cc',
    // gobjectOptions: GObjectOptions(),
    // kotlinOut:
    //     'android/app/src/main/kotlin/dev/flutter/pigeon_example_app/Messages.g.kt',
    // kotlinOptions: KotlinOptions(),
    // javaOut: 'android/app/src/main/java/io/flutter/plugins/Messages.java',
    // javaOptions: JavaOptions(),
    swiftOut: 'ios/SocketConnector/NativeMethodChannelSpec.g.swift',
    swiftOptions: SwiftOptions(),
    // objcHeaderOut: 'macos/Runner/messages.g.h',
    // objcSourceOut: 'macos/Runner/messages.g.m',
    // Set this to a unique prefix for your plugin or application, per Objective-C naming conventions.
    // objcOptions: ObjcOptions(prefix: 'PGN'),
    // copyrightHeader: 'pigeons/copyright.txt',
    dartPackageName: 'test_app',
  ),
)
class PacketTunnelRequest {
  final String localHost;
  final int localPort;

  PacketTunnelRequest({required this.localHost, this.localPort = 443});
}

@HostApi()
abstract class SocketConnectorHostAPI {
  String getHostLanguage();

  @async
  @SwiftFunction('startTunnel(request:)')
  void startTunnel(PacketTunnelRequest request);
}
