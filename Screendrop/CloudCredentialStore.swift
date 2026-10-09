//
//  CloudCredentialStore.swift
//  Screendrop
//
//  Keychain-backed storage for cloud upload configuration.
//  Secrets (upload token) go in the Keychain.
//  Non-secret config (worker URL) goes in UserDefaults.
//

import Foundation
import Security

/// Immutable snapshot of credentials used across actor boundaries.
struct CloudCredentials: Sendable {
    let workerURL: String
    let uploadToken: String

    var isConfigured: Bool {
        !workerURL.isEmpty && !uploadToken.isEmpty
    }
}

@Observable
final class CloudCredentialStore {
    static let shared = CloudCredentialStore()

    private let defaults = UserDefaults.standard
    static let keychainService = ScreendropStorage.keychainService

    // MARK: - Keys

    enum Keys {
        static let uploadToken = "cloud_upload_token"
        static let workerURL = "cloudWorkerURL"       // Matches existing key
    }

    // MARK: - Backing storage (observed)

    private(set) var _uploadToken: String = ""
    private(set) var _workerURL: String = ""

    // MARK: - Public computed setters

    var uploadToken: String {
        get { _uploadToken }
        set {
            _uploadToken = newValue
            Self.setKeychainItem(key: Keys.uploadToken, value: newValue)
        }
    }

    var workerURL: String {
        get { _workerURL }
        set {
            _workerURL = newValue
            defaults.set(newValue, forKey: Keys.workerURL)
        }
    }

    // MARK: - Convenience

    var isConfigured: Bool {
        !_workerURL.isEmpty && !_uploadToken.isEmpty
    }

    /// Create an immutable snapshot for passing across actor boundaries.
    func snapshot() -> CloudCredentials {
        CloudCredentials(
            workerURL: _workerURL,
            uploadToken: _uploadToken
        )
    }

    // MARK: - Init

    private init() {
        _uploadToken = Self.getKeychainItem(key: Keys.uploadToken) ?? ""
        _workerURL = defaults.string(forKey: Keys.workerURL) ?? ""

        // Only the personal app migrates its historical credentials.
        if ScreendropStorage.isPersonalBuild {
            migrateFromLegacyDefaults()
            migrateFromLegacyS3Credentials()
        }
    }

    private func migrateFromLegacyDefaults() {
        let oldTokenKey = "cloudUploadToken"
        if let oldToken = defaults.string(forKey: oldTokenKey), !oldToken.isEmpty, _uploadToken.isEmpty {
            uploadToken = oldToken
            defaults.removeObject(forKey: oldTokenKey)
        }
    }

    /// Remove S3/R2 credential artifacts left over from pre-presigned-URL versions.
    private func migrateFromLegacyS3Credentials() {
        let legacyDefaultsKeys = [
            "cloud_s3_bucket",
            "cloud_s3_region",
            "cloud_s3_endpoint",
            "cloud_s3_public_url_base",
        ]
        for key in legacyDefaultsKeys {
            defaults.removeObject(forKey: key)
        }

        let legacyKeychainKeys = [
            "cloud_s3_access_key_id",
            "cloud_s3_secret_access_key",
        ]
        for key in legacyKeychainKeys {
            Self.deleteKeychainItem(key: key)
        }
    }

    // MARK: - Keychain

    /// `service` defaults to this app's; the Screendrop import also reads and writes others.
    static func setKeychainItem(key: String, value: String, service: String = keychainService) {
        let data = Data(value.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
        ]

        SecItemDelete(query as CFDictionary)

        var newQuery = query
        newQuery[kSecValueData as String] = data
        SecItemAdd(newQuery as CFDictionary, nil)
    }

    static func getKeychainItem(key: String, service: String = keychainService) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private static func deleteKeychainItem(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: keychainService,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
