import Foundation
import Security

/// The atlas bearer token, in the Keychain.
///
/// This is the shared secret that authenticates `IndexClient` to audio-index
/// on atlas. It is not a preference - losing it means pasting it back in from
/// `/var/lib/audio-index/config.json` on atlas, never regenerating it here.
///
/// UNLIKE rack-control-ios's `TokenStore`, this one declares no keychain
/// access group. That app deliberately shares its token with a sibling app;
/// this one has no sibling and nothing else should be able to read its token,
/// so it stays in this app's own implicit bundle-scoped group under its own
/// service name.
///
/// `service` is injectable (default `com.example.audioindex`) so tests can
/// point at a throwaway keychain item instead of the app's real one.
final class TokenStore {
    private let service: String

    init(service: String = "com.example.audioindex") {
        self.service = service
    }

    private var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "atlas-bearer-token",
        ]
    }

    var token: String? {
        get {
            var q = base
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &out)
            guard status == errSecSuccess,
                let data = out as? Data,
                let s = String(data: data, encoding: .utf8), !s.isEmpty
            else {
                if status != errSecSuccess && status != errSecItemNotFound {
                    assertionFailure("TokenStore load: unexpected OSStatus \(status)")
                }
                return nil
            }
            return s
        }
        set {
            guard let newValue else {
                clear()
                return
            }
            var q = base
            q[kSecValueData as String] = Data(newValue.utf8)
            // ThisDeviceOnly so the token never rides an iCloud backup onto a
            // second device. WhenUnlocked rather than Always because nothing
            // here runs in the background - there is no reader while the
            // phone is locked.
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(q as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                // A bare SecItemAdd fails on the second save with
                // errSecDuplicateItem and leaves the OLD token in place -
                // stranding the user on a token they thought they replaced.
                // Update the existing item instead.
                let update: [String: Any] = [kSecValueData as String: Data(newValue.utf8)]
                let updateStatus = SecItemUpdate(base as CFDictionary, update as CFDictionary)
                if updateStatus != errSecSuccess {
                    assertionFailure("TokenStore save: unexpected OSStatus \(updateStatus)")
                }
            } else if addStatus != errSecSuccess {
                assertionFailure("TokenStore save: unexpected OSStatus \(addStatus)")
            }
        }
    }

    func clear() {
        let status = SecItemDelete(base as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            assertionFailure("TokenStore clear: unexpected OSStatus \(status)")
        }
    }
}
