import XCTest

/// Scripted UI tour used by CI (manual proof shots only) to capture
/// screenshots the maintainer reviews: main menu -> Settings table
/// (scroll), back. It only navigates and stages nothing — it never
/// applies anything.
final class TourUITests: XCTestCase {
    func testTour() throws {
        let app = XCUIApplication()
        // Demonstrate the supported (open) iOS 26 state in the tour.
        app.launchArguments = ["-DemoIOS26"]
        app.launch()
        XCTAssertEqual(app.state, .runningForeground,
                       "app must be in the foreground after launch")
        let settings = app.buttons["menu-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15),
                      "main menu never appeared — app UI not shown")
        sleep(2)

        settings.tap()
        sleep(1)
        app.swipeUp()
        sleep(1)
        app.swipeUp()
        sleep(1)
        app.swipeDown()
        sleep(1)
    }
}
