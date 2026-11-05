import XCTest

@testable import AudioIndex

final class TokenStoreTests: XCTestCase {
    private let store = TokenStore(service: "com.example.audioindex.tests")

    override func setUp() { store.clear() }
    override func tearDown() { store.clear() }

    func testRoundTrips() {
        XCTAssertNil(store.token)
        store.token = "abc123"
        XCTAssertEqual(store.token, "abc123")
    }

    // Saving twice must UPDATE, not fail with errSecDuplicateItem and silently
    // leave the old value in place - which would strand the app on a token the
    // user thought they had replaced.
    func testOverwritesAnExistingToken() {
        store.token = "first"
        store.token = "second"
        XCTAssertEqual(store.token, "second")
    }

    func testClearRemovesIt() {
        store.token = "abc"
        store.clear()
        XCTAssertNil(store.token)
    }

    func testSettingNilClears() {
        store.token = "abc"
        store.token = nil
        XCTAssertNil(store.token)
    }
}
