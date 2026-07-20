import EnLLMCore
import Foundation
import Security

struct KeychainItemKey: Sendable, Equatable {
    let service: String
    let account: String
}

protocol KeychainOperations: Sendable {
    func copy(_ key: KeychainItemKey) -> (status: OSStatus, data: Data?)
    func update(_ key: KeychainItemKey, data: Data) -> OSStatus
    func add(_ key: KeychainItemKey, data: Data) -> OSStatus
    func delete(_ key: KeychainItemKey) -> OSStatus
}

private struct SecurityKeychainOperations: KeychainOperations, @unchecked Sendable {
    func copy(_ key: KeychainItemKey) -> (status: OSStatus, data: Data?) {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func update(_ key: KeychainItemKey, data: Data) -> OSStatus {
        SecItemUpdate(
            baseQuery(key) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
    }

    func add(_ key: KeychainItemKey, data: Data) -> OSStatus {
        var query = baseQuery(key)
        query[kSecValueData as String] = data
        return SecItemAdd(query as CFDictionary, nil)
    }

    func delete(_ key: KeychainItemKey) -> OSStatus {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    private func baseQuery(_ key: KeychainItemKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account
        ]
    }
}

public actor KeychainCredentialStore: CredentialStoring {
    private let service: String
    private let operations: any KeychainOperations

    public init(service: String = BuiltInDefaults.bundleIdentifier) {
        self.service = service
        operations = SecurityKeychainOperations()
    }

    init(service: String = BuiltInDefaults.bundleIdentifier, operations: any KeychainOperations) {
        self.service = service
        self.operations = operations
    }

    public func loadCredential(for provider: LLMProvider) async throws -> String? {
        let result = operations.copy(itemKey(for: provider))
        switch result.status {
        case errSecSuccess:
            guard let data = result.data, let credential = String(data: data, encoding: .utf8) else {
                throw EnLLMError.credentialStoreFailure
            }
            return credential
        case errSecItemNotFound:
            return nil
        default:
            throw EnLLMError.credentialStoreFailure
        }
    }

    public func saveCredential(_ credential: String, for provider: LLMProvider) async throws {
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try await deleteCredential(for: provider)
            return
        }

        let key = itemKey(for: provider)
        let data = Data(trimmed.utf8)
        let updateStatus = operations.update(key, data: data)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound,
              operations.add(key, data: data) == errSecSuccess else {
            throw EnLLMError.credentialStoreFailure
        }
    }

    public func deleteCredential(for provider: LLMProvider) async throws {
        let status = operations.delete(itemKey(for: provider))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw EnLLMError.credentialStoreFailure
        }
    }

    private func itemKey(for provider: LLMProvider) -> KeychainItemKey {
        switch provider {
        case .anthropic:
            KeychainItemKey(service: service, account: "anthropic-api-key")
        case .openAI:
            KeychainItemKey(service: service, account: "openai-api-key")
        }
    }
}
