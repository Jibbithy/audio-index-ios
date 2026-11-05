import XCTest

@testable import AudioIndex

final class NavidromeStoreTests: XCTestCase {
    private let store = NavidromeStore(service: "com.example.audioindex.navidrome.tests")

    // Obviously fake, and never sent anywhere.
    private func creds(
        _ user: String = "tester",
        _ password: String = "fake-password"
    ) -> NavidromeCredentials {
        NavidromeCredentials(
            baseURL: URL(string: "http://music.example")!,
            username: user, password: password)
    }

    override func setUp() { store.clear() }
    override func tearDown() { store.clear() }

    func testRoundTripsAllThreeFields() {
        XCTAssertNil(store.credentials)
        store.credentials = creds()
        XCTAssertEqual(store.credentials, creds())
    }

    // Saving twice must UPDATE, not fail with errSecDuplicateItem and leave the
    // old password in place - which would strand the app on a password the user
    // thought they had replaced.
    func testOverwritesExistingCredentials() {
        store.credentials = creds("first", "fake-one")
        store.credentials = creds("second", "fake-two")
        XCTAssertEqual(store.credentials?.username, "second")
        XCTAssertEqual(store.credentials?.password, "fake-two")
    }

    func testClearRemovesThem() {
        store.credentials = creds()
        store.clear()
        XCTAssertNil(store.credentials)
    }

    func testSettingNilClears() {
        store.credentials = creds()
        store.credentials = nil
        XCTAssertNil(store.credentials)
    }

    // Two unrelated secrets for two unrelated servers. Rotating the atlas token
    // must not disturb the Navidrome password, and clearing one must not clear
    // the other.
    func testDoesNotShareAnItemWithTokenStore() {
        // Its own throwaway service, not the one TokenStoreTests uses - two
        // suites clearing the same keychain item would fail each other.
        let tokens = TokenStore(service: "com.example.audioindex.navidrome.tests.atlas")
        defer { tokens.clear() }
        tokens.token = "fake-atlas-token"
        store.credentials = creds()

        store.clear()
        XCTAssertEqual(tokens.token, "fake-atlas-token")
        XCTAssertNil(store.credentials)
    }
}
