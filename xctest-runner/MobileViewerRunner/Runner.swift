import XCTest

class MobileViewerRunner: XCTestCase {
    func testRunCommandServer() throws {
        let done = XCTestExpectation(description: "server-done")
        let server = CommandServer(port: 22087) { done.fulfill() }
        try server.start()
        wait(for: [done], timeout: 3600)
    }
}