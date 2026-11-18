import XCTest

final class PulseBandSetupTests: XCTestCase {
    func testSetupCanBeDeferredFromBandStep() {
        let app = XCUIApplication()
        app.launchArguments = ["-previewData", "-testOnboarding"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Welcome to Pulse"].waitForExistence(timeout: 10))
        app.buttons["Get started"].tap()
        XCTAssertTrue(app.staticTexts["Set up your band"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Search for my band"].exists)
        app.buttons["Set up later"].tap()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Welcome to Pulse"].exists)
    }

    func testLegacySavedBandOpensHomeWithoutManualSetup() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingDone", "NO", "-bandIdentifier", UUID().uuidString, "-wantsConnection", "NO"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["Welcome to Pulse"].exists)
        app.tabBars.buttons["Device"].tap()
        XCTAssertTrue(app.staticTexts["WHOOP 4.0"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Set up your band"].exists)
        XCTAssertFalse(app.buttons["Search for my band"].exists)
        XCTAssertFalse(app.buttons["Disconnect band"].exists)
    }
}
