import XCTest

final class DGXPulseUITests: XCTestCase {
    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()
        // Menu-bar apps may not expose a main window; launch without crashing is enough.
        XCTAssertTrue(app.state == .runningForeground || app.state == .runningBackground)
    }
}
