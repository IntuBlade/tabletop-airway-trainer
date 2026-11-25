import XCTest

final class TrainerWorkflowTests: XCTestCase {
    func testRecordedRepKeepsAnswersHiddenAndCanRepeat() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Try recorded practice"].tap()
        let mark = app.buttons["Mark view"]
        XCTAssertTrue(mark.waitForExistence(timeout: 5))
        mark.tap()
        app.buttons["Play example"].tap()
        XCTAssertTrue(app.buttons["Play example"].waitForExistence(timeout: 15))
        mark.tap()

        answer(in: app)
        XCTAssertFalse(app.staticTexts["View recovered"].exists)
        app.buttons["Next view"].tap()
        let reveal = app.buttons["Reveal both views"]
        XCTAssertFalse(reveal.isEnabled)
        answer(in: app)
        reveal.tap()
        XCTAssertTrue(app.staticTexts["View recovered"].waitForExistence(timeout: 5))
        app.buttons["Try another rep"].tap()
        XCTAssertTrue(mark.waitForExistence(timeout: 5))
    }

    private func answer(in app: XCUIApplication) {
        app.buttons["Unsure"].tap()
        app.segmentedControls.buttons["Glottic opening"].tap()
        app.buttons["Unsure"].tap()
        app.buttons.containing(NSPredicate(format: "label CONTAINS 'POGO range'")).firstMatch.tap()
        app.buttons["30–50%"].tap()
    }
}
