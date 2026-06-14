import GRPC
import NIOCore
import NIOPosix
import NIOSSL
import XCTest

@testable import Jaca

/// LIVE: exercises the desktop's grpc-swift client against a real Jaca mobile gRPC server
/// (the same trust-all TLS + ALPN path CompanionLink uses). Requires the companion app
/// running and reachable at 127.0.0.1:8889 — e.g. `adb forward tcp:8889 tcp:8889` against
/// an emulator. Fails when absent, like the other Live* tests; skip with -skip-testing.
final class LiveCompanionGrpcTests: XCTestCase {
    func test_describe_andSetProxy_overTLS() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .none          // link confidentiality, not PKI
        tls.applicationProtocols = ["grpc-exp", "h2"] // required or the server never sees h2
        let connection = ClientConnection.usingTLS(
            with: .makeClientConfigurationBackedByNIOSSL(configuration: tls), on: group
        ).connect(host: "127.0.0.1", port: 8889)
        defer { _ = connection.close() }

        let client = Jaca_CompanionAsyncClient(channel: connection)
        let opts = CallOptions(timeLimit: .timeout(.seconds(5))) // fail fast when offline

        // Unary Describe: TLS + HTTP/2 + protobuf round-trip, incl. the build version.
        let info = try await client.describe(Jaca_Empty(), callOptions: opts)
        XCTAssertFalse(info.name.isEmpty, "device should self-report a name")
        XCTAssertFalse(info.version.isEmpty, "device should report its build commit")

        // SetProxy: a desktop->device unary call the capture source relies on.
        var cfg = Jaca_ProxyConfig()
        cfg.host = "127.0.0.1"
        cfg.port = 65000
        _ = try await client.setProxy(cfg, callOptions: opts)
    }
}
