import XCTest

@MainActor final class T7SuiteUITests: XCTestCase {
    func testLaunchAndOfflineNavigation() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["openBinary"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Kartor"].tap()
        XCTAssertTrue(app.staticTexts["Öppna en firmwarefil"].exists)
        app.tabBars.buttons["Historik"].tap()
        XCTAssertFalse(app.buttons["Ångra senaste ändringen"].isEnabled)
    }
    func testClearlyLabelledLocalProtocolTest() {
        let app = XCUIApplication(); app.launch()
        app.tabBars.buttons["Anslutning"].tap()
        XCTAssertTrue(app.staticTexts["Ingen bil är ansluten"].exists)
        let button = app.buttons["runProtocolTest"]
        if !button.isHittable { app.swipeUp() }
        button.tap()
        XCTAssertTrue(app.staticTexts["Ramtest godkänt."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["TESTDATA – ingen ECU"].exists)
    }
}
