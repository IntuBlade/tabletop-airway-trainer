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

    func testGuidedCaptureLossAndIndependentAnswers() throws {
        let app = XCUIApplication()
        app.launch()
        walkGuidedRep(in: app)
    }

    /// Runs against the Firebase variant with a configured project. The hybrid
    /// session answers on the device when its model is available, and through
    /// Firebase otherwise.
    func testGuidedRepReviewGetsHybridCoaching() throws {
        let app = XCUIApplication()
        app.launch()
        walkGuidedRep(in: app)
        let fallback = app.buttons["Allow cloud fallback"]
        try XCTSkipUnless(fallback.waitForExistence(timeout: 3), "This build has no Firebase project configured.")
        fallback.tap()
        app.buttons["Allow for this rep"].tap()
        let route = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["On-device coaching", "Cloud coaching"])).firstMatch
        XCTAssertTrue(route.waitForExistence(timeout: 45))
        add(XCTAttachment(string: route.label))
        print("COACH ROUTE: \(route.label)")
    }

    private func walkGuidedRep(in app: XCUIApplication) {
        app.buttons["Start a guided rep"].tap()
        let airway = app.descendants(matching: .any)["guided-airway"].firstMatch
        XCTAssertTrue(airway.waitForExistence(timeout: 6))
        let rendered = airway.label == "Rendered airway frame"
        let lift = app.buttons["Lift"]
        let release = app.buttons["Release"]
        func tap(_ image: XCUIElement, _ x: CGFloat, _ y: CGFloat) {
            image.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
        }
        tap(airway, 0.09, 0.92)
        XCTAssertFalse(app.buttons["Mark useful view"].exists)
        tap(airway, 0.44, rendered ? 0.17 : 0.33)
        app.buttons["Mark useful view"].tap()
        XCTAssertFalse(app.buttons["Mark recovered view"].exists)
        for _ in 0..<6 { lift.tap() }
        app.buttons["Mark useful view"].tap()
        lift.tap()
        XCTAssertFalse(app.buttons["Mark recovered view"].exists)
        for _ in 0..<4 { release.tap() }
        XCTAssertTrue(app.buttons["Mark recovered view"].waitForExistence(timeout: 4))
        for _ in 0..<4 { lift.tap() }
        app.buttons["Mark recovered view"].tap()
        for slot in 0..<2 {
            let key = slot == 0 ? "Next view" : "Reveal both views"
            XCTAssertFalse(app.buttons[key].isEnabled)
            let label = rendered ? "Rendered airway frame" : "Synthetic airway frame"
            let image = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
            tap(image, rendered ? 0.45 : 0.50, rendered ? (slot == 0 ? 0.112 : 0.09) : 0.33)
            app.segmentedControls.buttons["Glottic opening"].tap()
            tap(image, rendered ? 0.468 : 0.50, rendered ? 0.23 : 0.61)
            app.buttons.containing(NSPredicate(format: "label CONTAINS 'POGO range'")).firstMatch.tap()
            app.buttons["30–50%"].tap()
            XCTAssertFalse(app.staticTexts["Reference range"].exists)
            app.buttons[key].tap()
        }
        XCTAssertTrue(app.staticTexts["Both views matched"].waitForExistence(timeout: 5))
    }

    private func answer(in app: XCUIApplication) {
        app.buttons["Unsure"].tap()
        app.segmentedControls.buttons["Glottic opening"].tap()
        app.buttons["Unsure"].tap()
        app.buttons.containing(NSPredicate(format: "label CONTAINS 'POGO range'")).firstMatch.tap()
        app.buttons["30–50%"].tap()
    }
}
