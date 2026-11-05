import Foundation
import Security

/// The Navidrome server, username and password, in the Keychain.
///
/// A SECOND Keychain item under its own service name rather than more fields on
/// `TokenStore`. Those are two unrelated secrets for two unrelated servers:
/// rotating the atlas token must not disturb the Navidrome password, and
/// clearing one must not clear the other.
///
/// All three values live in one item, encoded as JSON, because they are only
/// ever read or written together - a base URL saved without the password that
/// goes with it is not a state worth being able to represent.
///
/// `service` is injectable (default `com.example.audioindex.navidrome`) so
/// tests can point at a throwaway keychain item instead of the app's real one.
final class NavidromeStore {
    private let service: String

    init(service: String = "com.example.audioindex.navidrome") {
        self.service = service
    }

    private var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "navidrome-credentials",
        ]
    }

    var credentials: NavidromeCredentials? {
        get {
            var q = base
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &out)
            guard status == errSecSuccess, let data = out as? Data else {
                if status != errSecSuccess && status != errSecItemNotFound {
                    assertionFailure("NavidromeStore load: unexpected OSStatus \(status)")
                }
                return nil
            }
            // A stored blob that no longer decodes reads as "not configured".
            // Better than trapping: the user can simply enter the server again.
            return try? JSONDecoder().decode(NavidromeCredentials.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                clear()
                return
            }
            var q = base
            q[kSecValueData as String] = data
            // ThisDeviceOnly so the password never rides an iCloud backup onto
            // a second device. WhenUnlocked rather than Always because nothing
            // here runs in the background.
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(q as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                // A bare SecItemAdd fails on the second save and leaves the OLD
                // credentials in place - stranding the user on a password they
                // thought they had replaced. Update the existing item instead.
                let update: [String: Any] = [kSecValueData as String: data]
                let updateStatus = SecItemUpdate(base as CFDictionary, update as CFDictionary)
                if updateStatus != errSecSuccess {
                    assertionFailure("NavidromeStore save: unexpected OSStatus \(updateStatus)")
                }
            } else if addStatus != errSecSuccess {
                assertionFailure("NavidromeStore save: unexpected OSStatus \(addStatus)")
            }
        }
    }

    func clear() {
        let status = SecItemDelete(base as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            assertionFailure("NavidromeStore clear: unexpected OSStatus \(status)")
        }
    }
}
