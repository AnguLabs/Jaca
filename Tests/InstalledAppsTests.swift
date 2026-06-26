import XCTest
@testable import Jaca

final class InstalledAppsTests: XCTestCase {
    func testAndroidPackageParsingUserFirst() {
        let all = """
        package:com.android.systemui
        package:com.example.app.dev
        package:com.android.settings
        """
        let user = "package:com.example.app.dev\n"
        let entries = AndroidPackageParser.parse(all: all, userOnly: user)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.first?.id, "com.example.app.dev")   // user app sorts first
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
            "com.example.app" = {
                ApplicationType = User;
                CFBundleDisplayName = "Example";
                CFBundleIdentifier = "com.example.app";
            };
        }
        """
        let entries = SimulatorAppsParser.parse(Data(plist.utf8))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.id, "com.example.app")       // user app first
        XCTAssertEqual(entries.first?.name, "Example")
        let safari = entries.first { $0.id == "com.apple.mobilesafari" }
        XCTAssertEqual(safari?.name, "Safari")
        XCTAssertEqual(safari?.isUserApp, false)
    }

    func testIOSDeviceDevicectlAppsParsing() {
        let json = #"""
        {"result":{"apps":[
          {"bundleIdentifier":"com.apple.Preferences","name":"Settings","removable":false},
          {"bundleIdentifier":"com.example.app","name":"Example","removable":true,"builtByDeveloper":true},
          {"bundleIdentifier":"com.example.app","name":"Example (dup)","removable":true}
        ]}}
        """#
        let entries = IOSAppsParser.parse(Data(json.utf8))
        XCTAssertEqual(entries.count, 2)                        // duplicate bundle id dropped
        XCTAssertEqual(entries.first?.id, "com.example.app")        // user app sorts first
        XCTAssertEqual(entries.first?.name, "Example")
        XCTAssertTrue(entries.first?.isUserApp == true)
        let settings = entries.first { $0.id == "com.apple.Preferences" }
        XCTAssertEqual(settings?.isUserApp, false)              // non-removable → system
    }
}
