import Foundation


@main
enum RemoteLifetimeCheck {
    @MainActor
    static func main() async throws {
        var connection: RemoteConnection? = RemoteConnection(
            user: "fixture", host: "invalid", port: 22,
            controlSocket: URL(fileURLWithPath: "/tmp/kero-no-such-control-socket"), sshPID: 0
        )
        weak let releasedConnection = connection
        weak let releasedController = connection!.portForwards
        var controller: PortForwardController? = connection!.portForwards
        precondition(controller === connection!.portForwards)
        var backend: SSHWorkspaceBackend? = connection!.workspaceBackend
        var liveness: SSHWorkspaceBackend? = connection!.livenessBackend
        connection = nil
        precondition(releasedConnection != nil)
        backend = nil
        precondition(releasedConnection != nil)
        liveness = nil
        precondition(releasedConnection == nil)
        do {
            _ = try await controller!.forward(remotePort: 8000)
            fatalError("Released connection must not forward")
        } catch RemoteConnectionError.notConnected {}
        controller = nil
        precondition(releasedController == nil)
        var second: RemoteConnection? = RemoteConnection(
            user: "fixture", host: "invalid", port: 22,
            controlSocket: URL(fileURLWithPath: "/tmp/kero-no-such-control-socket"), sshPID: 0
        )
        weak let secondConnection = second
        weak let secondController = second!.portForwards
        second!.markConnected()
        second!.markDisconnected(reason: "lifetime check without network")
        precondition(second!.portForwards.localPortsByRemote.isEmpty)
        second = nil
        precondition(secondConnection == nil && secondController == nil)
        withExtendedLifetime(backend) {}
        withExtendedLifetime(liveness) {}
        print("PASS: connection-owned controller, request-owned backends, weak release and unavailable forwarding")
        let arguments = CommandLine.arguments
        if arguments.count == 4, let remotePort = Int(arguments[3]) {
            let live = RemoteConnection(
                user: "", host: arguments[2], port: 22,
                controlSocket: URL(fileURLWithPath: arguments[1]), sshPID: 0
            )
            live.markConnected()
            async let first = live.portForwards.forward(remotePort: remotePort)
            async let repeated = live.portForwards.forward(remotePort: remotePort)
            let (firstPort, repeatedPort) = try await (first, repeated)
            precondition(firstPort == repeatedPort)
            precondition(live.portForwards.localPortsByRemote[remotePort] == firstPort)
            let url = URL(string: "http://127.0.0.1:\(firstPort)/kero-lifetime-fixture-does-not-exist")!
            let (_, response) = try await URLSession.shared.data(from: url)
            precondition((response as? HTTPURLResponse)?.statusCode == 404)
            live.markDisconnected(reason: "records check; master still alive")
            precondition(live.portForwards.localPortsByRemote.isEmpty)
            print("PASS: concurrent forwarding reused actual loopback port \(firstPort), HTTP fixture reached; disconnect cleared records only")
        }
    }
}
