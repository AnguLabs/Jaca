import XCTest
@testable import Jaca

final class AndroidCapabilitiesTests: XCTestCase {
    func testEmulatorUserdebugIsRooted() {
        let caps = AndroidCapabilityProbe.parse(
            serial: "emulator-5554", qemu: "1", kernelQemu: "1", sdk: "36",
            abi: "arm64-v8a", buildType: "userdebug", suOK: false, lockDisabled: "true"
        )
        XCTAssertTrue(caps.isEmulator)
        XCTAssertEqual(caps.sdkInt, 36)
        XCTAssertEqual(caps.abi, "arm64-v8a")
        XCTAssertEqual(caps.root, .rooted)        // userdebug ⇒ adb root works
        XCTAssertTrue(caps.usesApexCACerts)       // API 36 ≥ 34
        XCTAssertTrue(caps.canAutoInstallCA)
        XCTAssertFalse(caps.hasScreenLock)        // get-disabled == true ⇒ no lock
    }

    func testProductionUserBuildNotRooted() {
        let caps = AndroidCapabilityProbe.parse(
            serial: "RZ8N1234", qemu: "", kernelQemu: "", sdk: "33",
            abi: "arm64-v8a", buildType: "user", suOK: false, lockDisabled: "false"
        )
        XCTAssertFalse(caps.isEmulator)
        XCTAssertEqual(caps.root, .notRooted)
        XCTAssertFalse(caps.usesApexCACerts)      // API 33 < 34: legacy /system store
        XCTAssertFalse(caps.canAutoInstallCA)
        XCTAssertTrue(caps.hasScreenLock)         // get-disabled == false ⇒ lock set
    }

    func testMagiskSuMakesUserBuildRooted() {
        let caps = AndroidCapabilityProbe.parse(
            serial: "RZ8N1234", qemu: "", kernelQemu: "", sdk: "34",
            abi: "arm64-v8a", buildType: "user", suOK: true, lockDisabled: nil
        )
        XCTAssertEqual(caps.root, .rooted)        // su present (Magisk)
        XCTAssertFalse(caps.hasScreenLock)        // nil lock output ⇒ assume none
    }

    func testEmptyBuildTypeIsUnknownRoot() {
        let caps = AndroidCapabilityProbe.parse(
            serial: "RZ8N1234", qemu: "", kernelQemu: "", sdk: "",
            abi: "", buildType: "", suOK: false, lockDisabled: nil
        )
        XCTAssertEqual(caps.root, .unknown)
        XCTAssertEqual(caps.sdkInt, 0)
    }

    func testKernelQemuFallbackDetectsEmulator() {
        let caps = AndroidCapabilityProbe.parse(
            serial: "1234abcd", qemu: "", kernelQemu: "1", sdk: "30",
            abi: "x86_64", buildType: "userdebug", suOK: false, lockDisabled: "true"
        )
        XCTAssertTrue(caps.isEmulator)            // ro.kernel.qemu fallback
    }
}
