import EnLLMCore
import Foundation

protocol SettingsFileOperations: Sendable {
    func read(_ url: URL) throws -> Data?
    func write(_ data: Data, to url: URL) throws
    func remove(_ url: URL) throws
}

private struct FoundationSettingsFileOperations: SettingsFileOperations {
    func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func remove(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// Persists the non-secret configuration as a strict schema-v2 envelope at
/// `settings-v2.json`. The write target is always v2; `settings-v1.json` is only
/// ever read (for one-time migration) and is never overwritten. Migration writes
/// v2 durably *before* the migrated configuration is returned — a failed write
/// leaves v1 untouched and falls back to complete defaults rather than running on
/// an in-memory-only migration.
public actor AtomicSettingsRepository: SettingsPersisting {
    public static let schemaVersion = 2
    static let legacySchemaVersion = 1
    public let fileURL: URL
    let legacyFileURL: URL
    private let files: any SettingsFileOperations

    private static let recoveryMessage =
        "Stored settings were unreadable or invalid. Complete defaults were restored for this session."

    public init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(BuiltInDefaults.bundleIdentifier, isDirectory: true)
        self.init(
            fileURL: base.appendingPathComponent("settings-v2.json"),
            legacyFileURL: base.appendingPathComponent("settings-v1.json")
        )
    }

    public init(fileURL: URL, legacyFileURL: URL) {
        self.init(fileURL: fileURL, legacyFileURL: legacyFileURL, files: FoundationSettingsFileOperations())
    }

    init(fileURL: URL, legacyFileURL: URL, files: any SettingsFileOperations) {
        self.fileURL = fileURL
        self.legacyFileURL = legacyFileURL
        self.files = files
    }

    public func load() async -> SettingsLoadResult {
        // 1. A present v2 file is authoritative. Invalid/unreadable v2 -> defaults.
        do {
            if let data = try files.read(fileURL) {
                return SettingsLoadResult(configuration: try Self.decodeV2(data))
            }
        } catch {
            return recovered()
        }

        // 2. No v2 file: attempt a one-time migration from a valid v1 file.
        do {
            guard let legacyData = try files.read(legacyFileURL) else {
                // Fresh install: no stored settings at all.
                return SettingsLoadResult(configuration: BuiltInDefaults.configuration)
            }
            let migrated = try Self.migrateV1(legacyData)
            // Durably persist v2 before publishing the migrated runtime. A failed
            // write must not partially activate the migration.
            do { try files.write(try Self.encode(migrated), to: fileURL) }
            catch { return recovered() }
            return SettingsLoadResult(configuration: migrated)
        } catch {
            return recovered()
        }
    }

    public func snapshot() async throws -> SettingsStoreSnapshot {
        if let data = try files.read(fileURL) { return .contents(data) }
        return .absent
    }

    public func save(_ configuration: NonSecretConfiguration) async throws {
        guard configuration.isValid else { throw EnLLMError.invalidSettings }
        do { try files.write(try Self.encode(configuration), to: fileURL) }
        catch { throw EnLLMError.settingsPersistenceFailed }
    }

    public func restore(_ snapshot: SettingsStoreSnapshot) async throws {
        do {
            switch snapshot {
            case .absent: try files.remove(fileURL)
            case .contents(let data): try files.write(data, to: fileURL)
            }
        } catch { throw EnLLMError.settingsPersistenceFailed }
    }

    private func recovered() -> SettingsLoadResult {
        SettingsLoadResult(configuration: BuiltInDefaults.configuration, recovery: .recoveredDefaults(Self.recoveryMessage))
    }

    static func encode(_ configuration: NonSecretConfiguration) throws -> Data {
        let envelope = Envelope(configuration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    static func decodeV2(_ data: Data) throws -> NonSecretConfiguration {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys) == Envelope.allowedKeys,
              let correct = dictionary["correctHotkey"] as? [String: Any],
              let translate = dictionary["translateHotkey"] as? [String: Any],
              Set(correct.keys) == Envelope.hotkeyKeys,
              Set(translate.keys) == Envelope.hotkeyKeys else {
            throw EnLLMError.invalidSettings
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.schemaVersion == schemaVersion else { throw EnLLMError.invalidSettings }
        let configuration = try envelope.configuration()
        guard configuration.isValid else { throw EnLLMError.invalidSettings }
        return configuration
    }

    /// Decodes a strict, valid v1 file and produces a normalized v2 configuration:
    /// each provider's single v1 model is copied into both of that provider's action
    /// fields when still allowed, otherwise defaulted; all other settings are preserved.
    static func migrateV1(_ data: Data) throws -> NonSecretConfiguration {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys) == LegacyEnvelope.allowedKeys,
              let correct = dictionary["correctHotkey"] as? [String: Any],
              let translate = dictionary["translateHotkey"] as? [String: Any],
              Set(correct.keys) == Envelope.hotkeyKeys,
              Set(translate.keys) == Envelope.hotkeyKeys else {
            throw EnLLMError.invalidSettings
        }
        let legacy = try JSONDecoder().decode(LegacyEnvelope.self, from: data)
        guard legacy.schemaVersion == legacySchemaVersion else { throw EnLLMError.invalidSettings }
        let migrated = try legacy.migratedConfiguration()
        // Instructions/hotkeys must be structurally sound; models are normalized so
        // they are always allowed. A blank instruction or invalid hotkey is rejected.
        guard migrated.isValid else { throw EnLLMError.invalidSettings }
        return migrated
    }
}

private struct Envelope: Codable {
    static let allowedKeys: Set<String> = [
        "schemaVersion", "primaryProvider", "fallbackEnabled",
        "openAICorrectionModel", "openAITranslationModel",
        "anthropicCorrectionModel", "anthropicTranslationModel",
        "correctionInstruction", "translationInstruction", "correctHotkey", "translateHotkey"
    ]
    static let hotkeyKeys: Set<String> = ["keyCode", "modifiers"]

    let schemaVersion: Int
    let primaryProvider: String
    let fallbackEnabled: Bool
    let openAICorrectionModel: String
    let openAITranslationModel: String
    let anthropicCorrectionModel: String
    let anthropicTranslationModel: String
    let correctionInstruction: String
    let translationInstruction: String
    let correctHotkey: HotkeyDefinition
    let translateHotkey: HotkeyDefinition

    init(_ configuration: NonSecretConfiguration) {
        schemaVersion = AtomicSettingsRepository.schemaVersion
        primaryProvider = configuration.primaryProvider == .anthropic ? "anthropic" : "openai"
        fallbackEnabled = configuration.fallbackEnabled
        openAICorrectionModel = configuration.openAICorrectionModel
        openAITranslationModel = configuration.openAITranslationModel
        anthropicCorrectionModel = configuration.anthropicCorrectionModel
        anthropicTranslationModel = configuration.anthropicTranslationModel
        correctionInstruction = configuration.correctionInstruction
        translationInstruction = configuration.translationInstruction
        correctHotkey = configuration.correctHotkey
        translateHotkey = configuration.translateHotkey
    }

    func configuration() throws -> NonSecretConfiguration {
        NonSecretConfiguration(
            primaryProvider: try Self.provider(primaryProvider),
            fallbackEnabled: fallbackEnabled,
            openAICorrectionModel: openAICorrectionModel,
            openAITranslationModel: openAITranslationModel,
            anthropicCorrectionModel: anthropicCorrectionModel,
            anthropicTranslationModel: anthropicTranslationModel,
            correctionInstruction: correctionInstruction,
            translationInstruction: translationInstruction,
            correctHotkey: correctHotkey,
            translateHotkey: translateHotkey
        )
    }

    static func provider(_ raw: String) throws -> LLMProvider {
        switch raw {
        case "anthropic": .anthropic
        case "openai": .openAI
        default: throw EnLLMError.invalidSettings
        }
    }
}

/// The historical schema-v1 shape, retained only to read a pre-existing v1 file
/// during one-time migration.
private struct LegacyEnvelope: Codable {
    static let allowedKeys: Set<String> = [
        "schemaVersion", "primaryProvider", "fallbackEnabled", "anthropicModel", "openAIModel",
        "correctionInstruction", "translationInstruction", "correctHotkey", "translateHotkey"
    ]

    let schemaVersion: Int
    let primaryProvider: String
    let fallbackEnabled: Bool
    let anthropicModel: String
    let openAIModel: String
    let correctionInstruction: String
    let translationInstruction: String
    let correctHotkey: HotkeyDefinition
    let translateHotkey: HotkeyDefinition

    func migratedConfiguration() throws -> NonSecretConfiguration {
        let provider = try Envelope.provider(primaryProvider)
        // A blank v1 model is not a valid v1 file; do not silently default it.
        guard !anthropicModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !openAIModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EnLLMError.invalidSettings
        }
        return NonSecretConfiguration(
            primaryProvider: provider,
            fallbackEnabled: fallbackEnabled,
            openAICorrectionModel: LLMModelCatalog.normalized(openAIModel, for: .openAI, action: .correctSelection),
            openAITranslationModel: LLMModelCatalog.normalized(openAIModel, for: .openAI, action: .translateSelectionToUkrainian),
            anthropicCorrectionModel: LLMModelCatalog.normalized(anthropicModel, for: .anthropic, action: .correctSelection),
            anthropicTranslationModel: LLMModelCatalog.normalized(anthropicModel, for: .anthropic, action: .translateSelectionToUkrainian),
            correctionInstruction: correctionInstruction,
            translationInstruction: translationInstruction,
            correctHotkey: correctHotkey,
            translateHotkey: translateHotkey
        )
    }
}
