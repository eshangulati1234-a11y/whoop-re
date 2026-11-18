import XCTest

final class PulseNavigationTests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-previewData"]
        app.launch()
        return app
    }
    func testEveryNativeTabOpensWorkouts() {
        let app = launch()
        for title in ["Home", "Sleep", "Heart", "Device"] {
            let tab = app.tabBars.buttons[title]
            XCTAssertTrue(tab.waitForExistence(timeout: 10), "Missing tab: \(title)")
            tab.tap()
            let workouts = app.buttons["open-workouts"]
            XCTAssertTrue(workouts.waitForExistence(timeout: 5))
            workouts.tap()
            XCTAssertTrue(app.navigationBars["Workouts"].waitForExistence(timeout: 5))
            let done = app.navigationBars.buttons["Done"]
            XCTAssertTrue(done.exists)
            done.tap()
        }
    }
    func testStartWorkoutAndReturnWithoutStarting() {
        let app = launch()
        app.buttons["open-workouts"].tap()
        let running = app.buttons["Start Running"]
        XCTAssertTrue(running.waitForExistence(timeout: 5))
        running.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Start workout"].waitForExistence(timeout: 5))
        // Scroll content must reveal the primary action without starting a real session.
        let start = app.buttons["Start Running"]
        for _ in 0..<4 where !start.isHittable { app.swipeUp() }
        XCTAssertTrue(start.isHittable)
        XCTAssertTrue(app.navigationBars.buttons["Close"].exists)
        app.navigationBars.buttons["Close"].tap()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 5))
    }
}
