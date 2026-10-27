import XCTest

final class ForecastAPIUITests: UITestCase {
    func testOwnAPIIsOptionalAndRequiresConfiguration() {
        launch(["BB_SEED_FORECAST": "1"])
        let configure = app.buttons["forecast-api-settings"]
        for _ in 0..<8 where !configure.isHittable { app.swipeUp() }
        tap(configure)
        expect(app.navigationBars["Own API"])
        expect(app.textFields["forecast-api-endpoint"])
        expect(app.textFields["forecast-api-model"])
        expect(app.secureTextFields["forecast-api-key"])
        XCTAssertFalse(app.buttons["Save API configuration"].isEnabled)
        let consent = app.switches["forecast-api-consent"]
        for _ in 0..<5 where !consent.isHittable { app.swipeUp() }
        expectValue(consent, "0")
        XCTAssertFalse(consent.isEnabled)
    }

    func testNoRequestButtonWithoutConsent() {
        launch(["BB_SEED_FORECAST": "1"])
        let configure = app.buttons["forecast-api-settings"]
        for _ in 0..<8 where !configure.isHittable { app.swipeUp() }
        expect(configure)
        expect(app.staticTexts["API sharing is off. Calculated estimates work without it."])
        XCTAssertFalse(app.buttons["forecast-api-request"].exists)
    }
}
