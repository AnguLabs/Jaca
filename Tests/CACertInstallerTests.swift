import XCTest
@testable import Jaca

final class CACertInstallerTests: XCTestCase {
    func testApexInjectionBindsIntoNamespaces() {
        let script = AndroidCACertInstaller.injectionScript(
            hash: "4ed68daa", devCert: "/data/local/tmp/4ed68daa.0", useApex: true)
        XCTAssertTrue(script.contains("mount -t tmpfs tmpfs"))
        XCTAssertTrue(script.contains("chcon u:object_r:system_file:s0"))
        XCTAssertTrue(script.contains("nsenter --mount=/proc/$pid/ns/mnt"))
        XCTAssertTrue(script.contains("pidof zygote zygote64"))
        XCTAssertTrue(script.contains("/data/local/tmp/4ed68daa.0"))
        XCTAssertTrue(script.contains("JACA_INJECT_OK"))
    }

    func testLegacyInjectionSkipsApexBind() {
        let script = AndroidCACertInstaller.injectionScript(
            hash: "abc12345", devCert: "/data/local/tmp/abc12345.0", useApex: false)
        XCTAssertTrue(script.contains("mount -t tmpfs tmpfs"))
        XCTAssertFalse(script.contains("nsenter"))   // no APEX on API < 34
        XCTAssertTrue(script.contains("JACA_INJECT_OK"))
    }

    func testUninstallScriptLazyUnmounts() {
        let apex = AndroidCACertInstaller.uninstallScript(hash: "4ed68daa", useApex: true)
        XCTAssertTrue(apex.contains("umount -l"))
        XCTAssertTrue(apex.contains("nsenter"))
        let legacy = AndroidCACertInstaller.uninstallScript(hash: "abc12345", useApex: false)
        XCTAssertFalse(legacy.contains("nsenter"))
    }
}
