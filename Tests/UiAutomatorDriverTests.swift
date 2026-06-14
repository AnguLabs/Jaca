import XCTest
@testable import Jaca

final class UiAutomatorDriverTests: XCTestCase {
    private let sampleXML = """
    <?xml version='1.0' encoding='UTF-8'?>
    <hierarchy rotation="0">
      <node index="0" text="" resource-id="" class="android.widget.FrameLayout" bounds="[0,0][1080,2400]">
        <node index="1" text="Mais configurações de segurança" resource-id="android:id/title" class="android.widget.TextView" clickable="false" bounds="[42,1310][810,1428]"/>
        <node index="2" text="Instalar do armazen. aparelho" resource-id="android:id/title" class="android.widget.TextView" bounds="[42,1500][702,1594]"/>
        <node index="3" text="Instalar mesmo assim" resource-id="com.android.settings:id/button_positive" class="android.widget.Button" clickable="true" bounds="[126,2348][516,2444]"/>
      </node>
    </hierarchy>
    """

    func testParsesNodesAndBounds() {
        let nodes = UiAutomatorDriver.parse(sampleXML)
        XCTAssertEqual(nodes.count, 3)
        let install = nodes.first { $0.text == "Instalar do armazen. aparelho" }
        XCTAssertEqual(install?.bounds, CGRect(x: 42, y: 1500, width: 660, height: 94))
        XCTAssertEqual(install?.center, CGPoint(x: 372, y: 1547))
    }

    func testFindByLocalizedTextCandidates() {
        let nodes = UiAutomatorDriver.parse(sampleXML)
        let found = UiAutomatorDriver.find(
            text: ["Install from device storage", "Instalar do armazen"], in: nodes)
        XCTAssertEqual(found?.text, "Instalar do armazen. aparelho")
    }

    func testFindByStableResourceId() {
        let nodes = UiAutomatorDriver.parse(sampleXML)
        let btn = UiAutomatorDriver.find(id: "com.android.settings:id/button_positive", in: nodes)
        XCTAssertEqual(btn?.text, "Instalar mesmo assim")
    }

    func testParseBounds() {
        XCTAssertEqual(UiAutomatorDriver.parseBounds("[10,20][110,140]"),
                       CGRect(x: 10, y: 20, width: 100, height: 120))
        XCTAssertEqual(UiAutomatorDriver.parseBounds("garbage"), .zero)
    }
}
