import Carbon
import EnLLMCore
import Foundation

private let enLLMHotkeySignature: OSType = 0x454E4C4D
private let correctHotkeyID: UInt32 = 1
private let translateHotkeyID: UInt32 = 2

@MainActor
protocol HotkeySystem {
    func installEventHandler(eventType: inout EventTypeSpec, context: UnsafeMutableRawPointer, handler: inout EventHandlerRef?) -> OSStatus
    func registerHotkey(keyCode: UInt32, modifiers: UInt32, hotkeyID: EventHotKeyID, hotkey: inout EventHotKeyRef?) -> OSStatus
    func unregisterHotkey(_ hotkey: EventHotKeyRef) -> OSStatus
    func removeEventHandler(_ handler: EventHandlerRef) -> OSStatus
}

@MainActor
private struct CarbonHotkeySystem: HotkeySystem {
    func installEventHandler(eventType: inout EventTypeSpec, context: UnsafeMutableRawPointer, handler: inout EventHandlerRef?) -> OSStatus {
        InstallEventHandler(GetApplicationEventTarget(), enLLMHotkeyCallback, 1, &eventType, context, &handler)
    }
    func registerHotkey(keyCode: UInt32, modifiers: UInt32, hotkeyID: EventHotKeyID, hotkey: inout EventHotKeyRef?) -> OSStatus {
        RegisterEventHotKey(keyCode, modifiers, hotkeyID, GetApplicationEventTarget(), 0, &hotkey)
    }
    func unregisterHotkey(_ hotkey: EventHotKeyRef) -> OSStatus { UnregisterEventHotKey(hotkey) }
    func removeEventHandler(_ handler: EventHandlerRef) -> OSStatus { RemoveEventHandler(handler) }
}

@MainActor
public final class DefaultHotkeyRegistrar: HotkeyRegistering {
    public static let defaultCorrectKeyCode = UInt32(kVK_ANSI_T)
    public static let defaultCorrectModifiers = UInt32(controlKey | shiftKey)
    public static let defaultTranslateKeyCode = UInt32(kVK_ANSI_T)
    public static let defaultTranslateModifiers = UInt32(optionKey)

    private struct Registration {
        let definition: HotkeyDefinition
        let id: UInt32
        let handle: EventHotKeyRef
    }
    private struct Pending {
        var staged: [AppAction: Registration]
        var reused: [AppAction: Registration]
        var removed: [AppAction: Registration]
        let action: @MainActor @Sendable (AppAction) -> Void
    }

    private let system: any HotkeySystem
    private var active: [AppAction: Registration] = [:]
    private var retainedFailedUnregistrations: [AppAction: [Registration]] = [:]
    private var activeIDs: [UInt32: AppAction] = [:]
    private var eventHandler: EventHandlerRef?
    private var action: (@MainActor @Sendable (AppAction) -> Void)?
    private var pending: Pending?
    private var generation: UInt32 = 1
    private var recordingAction: AppAction?
    private var disabledActions: Set<AppAction> = []
    public private(set) var lastRollbackResult: HotkeyRollbackResult = .restored

    public var activeDefinitions: [AppAction: HotkeyDefinition] {
        active.mapValues(\.definition)
    }

    public convenience init() { self.init(system: CarbonHotkeySystem()) }
    init(system: any HotkeySystem) { self.system = system }

    public func registerDefaults(action: @escaping @MainActor @Sendable (AppAction) -> Void) throws {
        try prepare(correct: BuiltInDefaults.correctHotkey, translate: BuiltInDefaults.translateHotkey, action: action)
        activate()
    }

    public func prepare(
        correct: HotkeyDefinition,
        translate: HotkeyDefinition,
        action: @escaping @MainActor @Sendable (AppAction) -> Void
    ) throws {
        guard correct.isValid, translate.isValid, correct != translate else { throw EnLLMError.hotkeyRegistrationFailed }
        _ = rollback()
        guard retryFailedUnregistrations() else { throw EnLLMError.hotkeyRegistrationFailed }
        lastRollbackResult = .restored
        try ensureHandler()
        generation &+= 1
        let desired: [AppAction: HotkeyDefinition] = [.correctSelection: correct, .translateSelectionToUkrainian: translate]
        var staged: [AppAction: Registration] = [:]
        var reused: [AppAction: Registration] = [:]
        var removed: [AppAction: Registration] = [:]

        for appAction in AppAction.allCases {
            guard let registration = active[appAction] else { continue }
            if desired[appAction] == registration.definition {
                reused[appAction] = registration
                continue
            }
            guard system.unregisterHotkey(registration.handle) == noErr else {
                finishFailedPreparation(staged: staged, removed: removed)
                throw EnLLMError.hotkeyRegistrationFailed
            }
            removed[appAction] = registration
            active.removeValue(forKey: appAction)
            activeIDs.removeValue(forKey: registration.id)
        }

        do {
            let isInitialRegistration = active.isEmpty && removed.isEmpty
            for appAction in AppAction.allCases where reused[appAction] == nil {
                guard let definition = desired[appAction] else { continue }
                let id = isInitialRegistration
                    ? baseID(for: appAction)
                    : generation &* 10 &+ baseID(for: appAction)
                staged[appAction] = try register(definition, id: id)
            }
            pending = Pending(staged: staged, reused: reused, removed: removed, action: action)
        } catch {
            finishFailedPreparation(staged: staged, removed: removed)
            throw EnLLMError.hotkeyRegistrationFailed
        }
    }

    public func activate() {
        guard let pending else { return }
        active = pending.reused.merging(pending.staged) { _, new in new }
        activeIDs = Dictionary(uniqueKeysWithValues: active.map { ($0.value.id, $0.key) })
        action = pending.action
        disabledActions.removeAll()
        self.pending = nil
    }

    public func rollback() -> HotkeyRollbackResult {
        guard let pending else { return lastRollbackResult }
        finishFailedPreparation(staged: pending.staged, removed: pending.removed)
        self.pending = nil
        return lastRollbackResult
    }

    public func setRecordingAction(_ action: AppAction?) { recordingAction = action }

    public func unregister() {
        _ = rollback()
        action = nil
        disabledActions = Set(AppAction.allCases)
        activeIDs.removeAll()
        for (appAction, registration) in active {
            if system.unregisterHotkey(registration.handle) == noErr {
                active.removeValue(forKey: appAction)
            }
        }
        for appAction in AppAction.allCases {
            retainedFailedUnregistrations[appAction] = retainedFailedUnregistrations[appAction]?.filter {
                system.unregisterHotkey($0.handle) != noErr
            }
        }
        removeHandler()
    }

    func fire(hotkeyID: UInt32) {
        guard recordingAction == nil, let appAction = activeIDs[hotkeyID], !disabledActions.contains(appAction) else { return }
        action?(appAction)
    }

    private func retryFailedUnregistrations() -> Bool {
        var uncertain: Set<AppAction> = []
        for appAction in AppAction.allCases {
            let remaining = retainedFailedUnregistrations[appAction, default: []].filter {
                system.unregisterHotkey($0.handle) != noErr
            }
            retainedFailedUnregistrations[appAction] = remaining
            if !remaining.isEmpty { uncertain.insert(appAction) }
        }
        lastRollbackResult = uncertain.isEmpty ? .restored : .uncertain(uncertain)
        return uncertain.isEmpty
    }

    private func finishFailedPreparation(
        staged: [AppAction: Registration],
        removed: [AppAction: Registration]
    ) {
        var uncertain: Set<AppAction> = []
        for (appAction, registration) in staged {
            if system.unregisterHotkey(registration.handle) != noErr {
                retainedFailedUnregistrations[appAction, default: []].append(registration)
                uncertain.insert(appAction)
            }
        }
        for (appAction, registration) in removed {
            do {
                let restored = try register(registration.definition, id: registration.id)
                active[appAction] = restored
                activeIDs[restored.id] = appAction
            } catch {
                uncertain.insert(appAction)
            }
        }
        disabledActions.formUnion(uncertain)
        lastRollbackResult = uncertain.isEmpty ? .restored : .uncertain(uncertain)
        if active.isEmpty && retainedFailedUnregistrations.values.allSatisfy(\.isEmpty) { removeHandler() }
    }

    private func ensureHandler() throws {
        guard eventHandler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = system.installEventHandler(eventType: &type, context: Unmanaged.passUnretained(self).toOpaque(), handler: &eventHandler)
        guard status == noErr, eventHandler != nil else { eventHandler = nil; throw EnLLMError.hotkeyRegistrationFailed }
    }

    private func register(_ definition: HotkeyDefinition, id: UInt32) throws -> Registration {
        var handle: EventHotKeyRef?
        let status = system.registerHotkey(
            keyCode: definition.keyCode,
            modifiers: definition.modifiers,
            hotkeyID: EventHotKeyID(signature: enLLMHotkeySignature, id: id),
            hotkey: &handle
        )
        guard status == noErr, let handle else { throw EnLLMError.hotkeyRegistrationFailed }
        return Registration(definition: definition, id: id, handle: handle)
    }

    private func baseID(for action: AppAction) -> UInt32 {
        action == .correctSelection ? correctHotkeyID : translateHotkeyID
    }

    private func removeHandler() {
        if let eventHandler { _ = system.removeEventHandler(eventHandler); self.eventHandler = nil }
    }

    isolated deinit {
        if let pending {
            for registration in pending.staged.values { _ = system.unregisterHotkey(registration.handle) }
        }
        for registration in active.values { _ = system.unregisterHotkey(registration.handle) }
        for registrations in retainedFailedUnregistrations.values {
            for registration in registrations { _ = system.unregisterHotkey(registration.handle) }
        }
        if let eventHandler { _ = system.removeEventHandler(eventHandler) }
    }
}

public enum HotkeyFormatter {
    public static func string(for definition: HotkeyDefinition) -> String {
        var result = ""
        if definition.modifiers & HotkeyDefinition.controlModifier != 0 { result += "⌃" }
        if definition.modifiers & HotkeyDefinition.optionModifier != 0 { result += "⌥" }
        if definition.modifiers & HotkeyDefinition.shiftModifier != 0 { result += "⇧" }
        if definition.modifiers & HotkeyDefinition.commandModifier != 0 { result += "⌘" }
        return result + keyName(definition.keyCode)
    }

    private static func keyName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [
            0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",49:"Space",53:"Esc",123:"←",124:"→",125:"↓",126:"↑"
        ]
        return names[code] ?? "Key \(code)"
    }
}

private let enLLMHotkeyCallback: EventHandlerUPP = { _, event, context in
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr, id.signature == enLLMHotkeySignature else { return OSStatus(eventNotHandledErr) }
    let registrar = Unmanaged<DefaultHotkeyRegistrar>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { registrar.fire(hotkeyID: id.id) }
    return noErr
}
