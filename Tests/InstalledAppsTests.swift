import XCTest
@testable import Squeeze

final class InstalledAppsTests: XCTestCase {
    func testAndroidPackageParsingUserFirst() {
        let all = """
        package:com.android.systemui
        package:com.teya.ac.dev
        package:com.android.settings
        """
        let user = "package:com.teya.ac.dev\n"
        let entries = AndroidPackageParser.parse(all: all, userOnly: user)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.first?.id, "com.teya.ac.dev")   // user app sorts first
        XCTAssertTrue(entries.first?.isUserApp == true)
        XCTAssertTrue(entries.dropFirst().allSatisfy { !$0.isUserApp })
        XCTAssertNil(entries.first?.name)                       // Android has no label
    }

    func testSimulatorOpenStepPlistParsing() {
        let plist = """
        {
            "com.apple.mobilesafari" = {
                ApplicationType = System;
                CFBundleDisplayName = Safari;
                CFBundleIdentifier = "com.apple.mobilesafari";
            };
            "com.teya.app" = {
                ApplicationType = User;
                CFBundleDisplayName = "Teya";
                CFBundleIdentifier = "com.teya.app";
            };
        }
        """
        let entries = SimulatorAppsParser.parse(Data(plist.utf8))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.id, "com.teya.app")       // user app first
        XCTAssertEqual(entries.first?.name, "Teya")
        let safari = entries.first { $0.id == "com.apple.mobilesafari" }
        XCTAssertEqual(safari?.name, "Safari")
        XCTAssertEqual(safari?.isUserApp, false)
    }
}
