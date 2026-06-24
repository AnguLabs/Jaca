import XCTest
@testable import Jaca

final class MdnsServiceParserTests: XCTestCase {
    func testParsesTabSeparatedServices() {
        let raw = """
        List of discovered mdns services
        adb-939AX05XBZ-vWgJpq\t_adb-tls-connect._tcp\t192.168.1.86:39149
        adb-939AX05XBZ-vWgJpq\t_adb-tls-pairing._tcp\t192.168.1.86:37313
        """
        let services = MdnsServiceParser.parse(raw)
        XCTAssertEqual(services.count, 2)
        XCTAssertEqual(services[0].instance, "adb-939AX05XBZ-vWgJpq")
        XCTAssertEqual(services[0].kind, .connect)
        XCTAssertEqual(services[0].ip, "192.168.1.86")
        XCTAssertEqual(services[0].port, 39149)
        XCTAssertEqual(services[1].kind, .pairing)
        XCTAssertEqual(services[1].port, 37313)
    }

    func testStripsTrailingDotOnServiceType() {
        let raw = "jaca-abc\t_adb-tls-pairing._tcp.\t10.0.0.5:5555"
        let services = MdnsServiceParser.parse(raw)
        XCTAssertEqual(services.first?.serviceType, "_adb-tls-pairing._tcp")
        XCTAssertEqual(services.first?.kind, .pairing)
    }

    func testDropsBogusZeroAddressAndDedups() {
        let raw = """
        adb-x\t_adb-tls-connect._tcp\t0.0.0.0:1234
        adb-y\t_adb-tls-connect._tcp\t192.168.0.2:5555
        adb-y\t_adb-tls-connect._tcp\t192.168.0.2:5555
        """
        let services = MdnsServiceParser.parse(raw)
        XCTAssertEqual(services.count, 1)
        XCTAssertEqual(services.first?.instance, "adb-y")
    }

    func testHandlesSpaceSeparatedFallback() {
        let raw = "adb-z   _adb._tcp   192.168.1.9:5555"
        let services = MdnsServiceParser.parse(raw)
        XCTAssertEqual(services.first?.kind, .legacy)
        XCTAssertEqual(services.first?.port, 5555)
    }

    func testEmptyAndHeaderOnlyYieldsNothing() {
        XCTAssertTrue(MdnsServiceParser.parse("").isEmpty)
        XCTAssertTrue(MdnsServiceParser.parse("List of discovered mdns services\n").isEmpty)
    }
}

final class PairResultParsingTests: XCTestCase {
    func testParsesSuccessWithGuid() {
        let out = "Successfully paired to 192.168.1.174:40711 [guid=adb-43081FDAS000ST-GIVKML]"
        let result = PairResult.parse(stdout: out, stderr: "", exitCode: 0)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.address, "192.168.1.174:40711")
        XCTAssertEqual(result.guid, "adb-43081FDAS000ST-GIVKML")
    }

    func testParsesSuccessWithoutGuid() {
        let result = PairResult.parse(stdout: "Successfully paired", stderr: "", exitCode: 0)
        XCTAssertTrue(result.success)
        XCTAssertNil(result.guid)
    }

    func testFailureKeepsMessage() {
        let err = "Failed: Wrong password or connection was dropped"
        let result = PairResult.parse(stdout: "", stderr: err, exitCode: 1)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("Wrong password"))
    }

    func testEmptyOutputIsFriendlyFailure() {
        let result = PairResult.parse(stdout: "", stderr: "", exitCode: 1)
        XCTAssertFalse(result.success)
        XCTAssertFalse(result.message.isEmpty)
    }
}

final class MdnsHealthParsingTests: XCTestCase {
    func testHealthyBackend() {
        let health = MdnsHealth.parse(stdout: "mdns daemon version [Openscreen discovery 0.0.0]", stderr: "")
        XCTAssertTrue(health.isHealthy)
        if case .ok(let backend) = health { XCTAssertTrue(backend.contains("Openscreen")) } else { XCTFail() }
    }

    func testDisabledOnError() {
        let health = MdnsHealth.parse(stdout: "", stderr: "ERROR: mdns daemon unavailable")
        XCTAssertFalse(health.isHealthy)
        if case .disabled = health {} else { XCTFail("expected disabled") }
    }

    func testUnknownBackendBracketsTreatedAsDisabled() {
        let health = MdnsHealth.parse(stdout: "mdns daemon version [Unknown]", stderr: "")
        if case .disabled = health {} else { XCTFail("expected disabled for Unknown backend") }
    }
}

final class QrPairingTests: XCTestCase {
    func testPayloadFormat() {
        let creds = QrPairingCredentials(serviceName: "jaca-ABC123", password: "secretPW")
        XCTAssertEqual(creds.qrPayload, "WIFI:T:ADB;S:jaca-ABC123;P:secretPW;;")
    }

    func testGeneratedCredentialsAreWellFormed() {
        let creds = QrPairingCredentials.generate()
        XCTAssertTrue(creds.serviceName.hasPrefix("jaca-"))
        XCTAssertFalse(creds.password.isEmpty)
        // Payload grammar must not be broken by generated chars.
        XCTAssertFalse(creds.serviceName.contains(";"))
        XCTAssertFalse(creds.password.contains(";"))
        XCTAssertFalse(creds.password.contains(":"))
        XCTAssertEqual(creds.qrPayload.hasPrefix("WIFI:T:ADB;S:jaca-"), true)
    }

    func testGeneratedCredentialsAreUnique() {
        XCTAssertNotEqual(QrPairingCredentials.generate().serviceName,
                          QrPairingCredentials.generate().serviceName)
    }
}

final class PairedDeviceStoreTests: XCTestCase {
    private func tempStore() -> (PairedDeviceStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jaca-paired-\(UUID().uuidString).json")
        return (PairedDeviceStore(fileURL: url), url)
    }

    func testRememberAndReload() async {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        await store.remember(guid: "adb-AAA-bbb", name: "Pixel", address: "10.0.0.2:5555",
                             method: .pairingCode, now: now)
        let reloaded = PairedDeviceStore(fileURL: url)
        let all = await reloaded.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "Pixel")
        XCTAssertEqual(all.first?.method, .pairingCode)
    }

    func testReconnectTargetsMatchKnownConnectServices() async {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        await store.remember(guid: "adb-known", name: "K", address: nil, method: .qrCode)
        let services = [
            MdnsService(instance: "adb-known", serviceType: "_adb-tls-connect._tcp", ip: "10.0.0.3", port: 5555),
            MdnsService(instance: "adb-stranger", serviceType: "_adb-tls-connect._tcp", ip: "10.0.0.4", port: 5556),
            MdnsService(instance: "adb-known", serviceType: "_adb-tls-pairing._tcp", ip: "10.0.0.3", port: 7777),
        ]
        let targets = await store.reconnectTargets(from: services)
        // Only the known device's CONNECT service is a target (not the stranger, not pairing).
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets.first?.guid, "adb-known")
        XCTAssertEqual(targets.first?.address, "10.0.0.3:5555")
    }
}
