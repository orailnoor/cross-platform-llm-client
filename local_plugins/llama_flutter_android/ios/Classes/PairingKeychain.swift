import Foundation
import Security

/// This worker's phone-cluster pairing secret (shown in its QR code), in
/// the Keychain: this device only, never synced to iCloud or put in backups
/// restored elsewhere.
enum PairingKeychain {
    private static let service = "com.privatelm.cluster.pairing"
    private static let account = "worker"
    static let secretLength = 32

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// This worker's secret; created on first use.
    static func workerSecret() -> Data {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, data.count == secretLength {
            return data
        }
        return resetWorkerSecret()
    }

    /// Replaces this worker's secret: every paired master must scan again.
    @discardableResult
    static func resetWorkerSecret() -> Data {
        var secret = Data(count: secretLength)
        let status = secret.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, secretLength, $0.baseAddress!)
        }
        precondition(status == errSecSuccess, "No secure random bytes")
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = secret
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        if added != errSecSuccess {
            NSLog("[LlamaCluster] Couldn't save the pairing key (%d)", added)
        }
        return secret
    }
}
