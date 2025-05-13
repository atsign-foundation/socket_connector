import NetworkExtension
import SocketConnector

private class PigeonApiImplementation: SocketConnectorHostAPI {
    func getHostLanguage() throws -> String {
        return "Swift"
    }

    func startTunnel(
        request: PacketTunnelRequest, completion: @escaping (Result<Void, Error>) -> Void
    ) {
    }
}

private class SocketConnectorPacketTunnelProvider: NEPacketTunnelProvider {

}
