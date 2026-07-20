import Foundation
import Testing
@testable import EnLLMCore
@testable import EnLLMPlatform

/// A URL-keyed file spy so v1 and v2 paths are distinguishable (migration needs both).
private final class URLFilesSpy: SettingsFileOperations, @unchecked Sendable {
    var store: [URL: Data] = [:]
    var writeErrorURLs: Set<URL> = []
    var removeError = false
    private(set) var writtenURLs: [URL] = []
    func read(_ url: URL) throws -> Data? { store[url] }
    func write(_ data: Data, to url: URL) throws {
        if writeErrorURLs.contains(url) { throw EnLLMError.settingsPersistenceFailed }
        store[url] = data
        writtenURLs.append(url)
    }
    func remove(_ url: URL) throws {
        if removeError { throw EnLLMError.settingsPersistenceFailed }
        store[url] = nil
    }
}

private let v2URL = URL(fileURLWithPath: "/tmp/enllm-test/settings-v2.json")
private let v1URL = URL(fileURLWithPath: "/tmp/enllm-test/settings-v1.json")

private func makeRepository(_ files: URLFilesSpy) -> AtomicSettingsRepository {
    AtomicSettingsRepository(fileURL: v2URL, legacyFileURL: v1URL, files: files)
}

/// Builds a valid schema-v1 JSON payload for migration tests.
private func v1Data(
    primaryProvider: String = "openai",
    fallbackEnabled: Bool = false,
    anthropicModel: String,
    openAIModel: String,
    correctionInstruction: String = "legacy correction",
    translationInstruction: String = "legacy translation"
) throws -> Data {
    let dictionary: [String: Any] = [
        "schemaVersion": 1,
        "primaryProvider": primaryProvider,
        "fallbackEnabled": fallbackEnabled,
        "anthropicModel": anthropicModel,
        "openAIModel": openAIModel,
        "correctionInstruction": correctionInstruction,
        "translationInstruction": translationInstruction,
        "correctHotkey": ["keyCode": 17, "modifiers": Int(HotkeyDefinition.controlModifier | HotkeyDefinition.shiftModifier)],
        "translateHotkey": ["keyCode": 17, "modifiers": Int(HotkeyDefinition.optionModifier)]
    ]
    return try JSONSerialization.data(withJSONObject: dictionary)
}

@Test func settingsRepositoryRoundTripsStrictV2WithoutSecrets() async throws {
    let files = URLFilesSpy()
    let repository = makeRepository(files)
    try await repository.save(BuiltInDefaults.configuration)
    let loaded = await repository.load()
    #expect(loaded == SettingsLoadResult(configuration: BuiltInDefaults.configuration))
    #expect(files.writtenURLs == [v2URL])
    let text = String(decoding: try #require(files.store[v2URL]), as: UTF8.self)
    #expect(text.contains("\"schemaVersion\" : 2"))
    #expect(text.contains("\"openAICorrectionModel\""))
    #expect(text.contains("\"anthropicTranslationModel\""))
    #expect(!text.lowercased().contains("apikey"))
    #expect(!text.lowercased().contains("credential"))
}

@Test func missingSettingsAreCompleteDefaultsAndCorruptV2Recovers() async {
    let files = URLFilesSpy()
    let repository = makeRepository(files)
    #expect(await repository.load() == SettingsLoadResult(configuration: BuiltInDefaults.configuration))
    files.store[v2URL] = Data("{bad".utf8)
    let recovered = await repository.load()
    #expect(recovered.configuration == BuiltInDefaults.configuration)
    if case .recoveredDefaults = recovered.recovery {} else { Issue.record("Expected recovery state") }
}

@Test func strictV2SchemaRejectsUnknownMissingFutureAndDisallowedModels() async throws {
    let valid = try AtomicSettingsRepository.encode(BuiltInDefaults.configuration)
    let base = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
    var variants: [[String: Any]] = []
    var unknown = base; unknown["secret"] = "never"; variants.append(unknown)
    var missing = base; missing.removeValue(forKey: "openAICorrectionModel"); variants.append(missing)
    var wrongVersion = base; wrongVersion["schemaVersion"] = 1; variants.append(wrongVersion)
    var futureVersion = base; futureVersion["schemaVersion"] = 3; variants.append(futureVersion)
    var blank = base; blank["correctionInstruction"] = " "; variants.append(blank)
    var duplicate = base; duplicate["translateHotkey"] = base["correctHotkey"]; variants.append(duplicate)
    var disallowedOpenAI = base; disallowedOpenAI["openAICorrectionModel"] = "gpt-nope"; variants.append(disallowedOpenAI)
    var disallowedAnthropic = base; disallowedAnthropic["anthropicCorrectionModel"] = "claude-sonnet-5"; variants.append(disallowedAnthropic)

    for value in variants {
        let files = URLFilesSpy(); files.store[v2URL] = try JSONSerialization.data(withJSONObject: value)
        let loaded = await makeRepository(files).load()
        #expect(loaded.configuration == BuiltInDefaults.configuration)
        if case .recoveredDefaults = loaded.recovery {} else { Issue.record("Expected strict recovery") }
    }
}

@Test func validV2TakesPrecedenceAndV1IsNotMigrated() async throws {
    let files = URLFilesSpy()
    files.store[v2URL] = try AtomicSettingsRepository.encode(BuiltInDefaults.configuration)
    files.store[v1URL] = try v1Data(anthropicModel: "claude-sonnet-5", openAIModel: "gpt-5.6-luna")
    let loaded = await makeRepository(files).load()
    #expect(loaded == SettingsLoadResult(configuration: BuiltInDefaults.configuration))
    // No migration write should have happened.
    #expect(files.writtenURLs.isEmpty)
}

@Test func migratesValidV1IntoV2PreservingUnrelatedSettingsAndNormalizingModels() async throws {
    let files = URLFilesSpy()
    // claude-sonnet-5 is allowed for Anthropic translation but not correction;
    // gpt-5.6-luna is allowed for both OpenAI actions.
    files.store[v1URL] = try v1Data(
        primaryProvider: "openai",
        fallbackEnabled: false,
        anthropicModel: "claude-sonnet-5",
        openAIModel: "gpt-5.6-luna",
        correctionInstruction: "kept correction",
        translationInstruction: "kept translation"
    )
    let repository = makeRepository(files)
    let loaded = await repository.load()
    #expect(loaded.recovery == .none)
    let config = loaded.configuration
    #expect(config.openAICorrectionModel == "gpt-5.6-luna")
    #expect(config.openAITranslationModel == "gpt-5.6-luna")
    #expect(config.anthropicCorrectionModel == "claude-haiku-4-5") // disallowed -> default
    #expect(config.anthropicTranslationModel == "claude-sonnet-5") // allowed -> kept
    #expect(config.primaryProvider == .openAI)
    #expect(config.fallbackEnabled == false)
    #expect(config.correctionInstruction == "kept correction")
    #expect(config.translationInstruction == "kept translation")
    // The migrated v2 file was written durably; v1 was left untouched.
    #expect(files.writtenURLs == [v2URL])
    let v2 = try #require(files.store[v2URL])
    #expect(try AtomicSettingsRepository.decodeV2(v2) == config)
    #expect(files.store[v1URL] != nil)
    // A second load now prefers the freshly written v2 and does not migrate again.
    let again = await repository.load()
    #expect(again == SettingsLoadResult(configuration: config))
}

@Test func migrationWriteFailureLeavesV1IntactAndRecoversDefaults() async throws {
    let files = URLFilesSpy()
    let originalV1 = try v1Data(anthropicModel: "claude-haiku-4-5", openAIModel: "gpt-5.4-mini")
    files.store[v1URL] = originalV1
    files.writeErrorURLs = [v2URL]
    let loaded = await makeRepository(files).load()
    #expect(loaded.configuration == BuiltInDefaults.configuration)
    if case .recoveredDefaults = loaded.recovery {} else { Issue.record("Expected recovery on migration write failure") }
    // v1 must be untouched and no v2 written.
    #expect(files.store[v1URL] == originalV1)
    #expect(files.store[v2URL] == nil)
}

@Test func invalidV1IsNotMigratedAndRecoversDefaults() async throws {
    let files = URLFilesSpy()
    // Blank OpenAI model makes the v1 file invalid; it must not silently migrate.
    files.store[v1URL] = try v1Data(anthropicModel: "claude-haiku-4-5", openAIModel: " ")
    let loaded = await makeRepository(files).load()
    #expect(loaded.configuration == BuiltInDefaults.configuration)
    if case .recoveredDefaults = loaded.recovery {} else { Issue.record("Expected recovery for invalid v1") }
    #expect(files.store[v2URL] == nil)
}

@Test func snapshotsRestoreExactBytesOrAbsenceAndFailuresAreStable() async throws {
    let files = URLFilesSpy()
    let repository = makeRepository(files)
    #expect(try await repository.snapshot() == .absent)
    let old = Data([1, 2, 3]); files.store[v2URL] = old
    let snapshot = try await repository.snapshot()
    try await repository.save(BuiltInDefaults.configuration)
    try await repository.restore(snapshot)
    #expect(files.store[v2URL] == old)
    try await repository.restore(.absent)
    #expect(files.store[v2URL] == nil)
    files.writeErrorURLs = [v2URL]
    await #expect(throws: EnLLMError.settingsPersistenceFailed) { try await repository.save(BuiltInDefaults.configuration) }
}
