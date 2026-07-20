import EnLLMCore
import Foundation
import Security
import Testing
@testable import EnLLMPlatform

private final class FakeKeychainOperations: KeychainOperations, @unchecked Sendable {
    var copyStatus: OSStatus = errSecItemNotFound
    var copiedData: Data?
    var updateStatus: OSStatus = errSecItemNotFound
    var addStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess

    private(set) var copiedKeys: [KeychainItemKey] = []
    private(set) var updatedValues: [(KeychainItemKey, Data)] = []
    private(set) var addedValues: [(KeychainItemKey, Data)] = []
    private(set) var deletedKeys: [KeychainItemKey] = []

    func copy(_ key: KeychainItemKey) -> (status: OSStatus, data: Data?) {
        copiedKeys.append(key)
        return (copyStatus, copiedData)
    }

    func update(_ key: KeychainItemKey, data: Data) -> OSStatus {
        updatedValues.append((key, data))
        return updateStatus
    }

    func add(_ key: KeychainItemKey, data: Data) -> OSStatus {
        addedValues.append((key, data))
        return addStatus
    }

    func delete(_ key: KeychainItemKey) -> OSStatus {
        deletedKeys.append(key)
        return deleteStatus
    }
}

private let expectedAnthropicKey = KeychainItemKey(
    service: "com.radpozniakov.enllm",
    account: "anthropic-api-key"
)
private let expectedOpenAIKey = KeychainItemKey(
    service: "com.radpozniakov.enllm",
    account: "openai-api-key"
)

@Test func keychainLoadUsesEnLLMNamespaceAndHandlesFoundAndMissingItems() async throws {
    let foundOperations = FakeKeychainOperations()
    foundOperations.copyStatus = errSecSuccess
    foundOperations.copiedData = Data("stored-key".utf8)
    let foundStore = KeychainCredentialStore(operations: foundOperations)

    #expect(try await foundStore.loadCredential(for: .anthropic) == "stored-key")
    #expect(foundOperations.copiedKeys == [expectedAnthropicKey])

    let missingOperations = FakeKeychainOperations()
    let missingStore = KeychainCredentialStore(operations: missingOperations)
    #expect(try await missingStore.loadCredential(for: .openAI) == nil)
    #expect(missingOperations.copiedKeys == [expectedOpenAIKey])
}

@Test func keychainSaveUsesProviderSpecificAccountsAndTrimsCredentials() async throws {
    let updateOperations = FakeKeychainOperations()
    updateOperations.updateStatus = errSecSuccess
    let updateStore = KeychainCredentialStore(operations: updateOperations)

    try await updateStore.saveCredential("  updated-key  ", for: .anthropic)
    #expect(updateOperations.updatedValues.count == 1)
    #expect(updateOperations.updatedValues[0].0 == expectedAnthropicKey)
    #expect(String(data: updateOperations.updatedValues[0].1, encoding: .utf8) == "updated-key")
    #expect(updateOperations.addedValues.isEmpty)

    let addOperations = FakeKeychainOperations()
    let addStore = KeychainCredentialStore(operations: addOperations)
    try await addStore.saveCredential("new-openai-key", for: .openAI)
    #expect(addOperations.updatedValues.count == 1)
    #expect(addOperations.addedValues.count == 1)
    #expect(addOperations.addedValues[0].0 == expectedOpenAIKey)
    #expect(String(data: addOperations.addedValues[0].1, encoding: .utf8) == "new-openai-key")
}

@Test func keychainWhitespaceSaveDeletesAndProvidersRemainIsolated() async throws {
    let operations = FakeKeychainOperations()
    operations.deleteStatus = errSecItemNotFound
    let store = KeychainCredentialStore(operations: operations)

    try await store.saveCredential(" \n\t ", for: .anthropic)
    try await store.saveCredential("openai-key", for: .openAI)

    #expect(operations.deletedKeys == [expectedAnthropicKey])
    #expect(operations.addedValues.count == 1)
    #expect(operations.addedValues[0].0 == expectedOpenAIKey)
    #expect(operations.addedValues[0].0 != expectedAnthropicKey)
}

@Test func keychainDeleteUsesProviderSpecificAccount() async throws {
    let operations = FakeKeychainOperations()
    let store = KeychainCredentialStore(operations: operations)

    try await store.deleteCredential(for: .openAI)

    #expect(operations.deletedKeys == [expectedOpenAIKey])
}

@Test func keychainStatusesMapToStableContentFreeError() async {
    let loadOperations = FakeKeychainOperations()
    loadOperations.copyStatus = errSecAuthFailed
    let loadStore = KeychainCredentialStore(operations: loadOperations)
    await #expect(throws: EnLLMError.credentialStoreFailure) {
        try await loadStore.loadCredential(for: .anthropic)
    }

    let saveOperations = FakeKeychainOperations()
    saveOperations.updateStatus = errSecNotAvailable
    let saveStore = KeychainCredentialStore(operations: saveOperations)
    await #expect(throws: EnLLMError.credentialStoreFailure) {
        try await saveStore.saveCredential("secret-key", for: .openAI)
    }
    #expect(!EnLLMError.credentialStoreFailure.localizedDescription.contains("secret-key"))
}
