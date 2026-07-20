import AppKit
import ApplicationServices
import EnLLMCore
import Foundation

@MainActor
public final class AccessibilityPermissionService {
    public init() {}

    public var isTrusted: Bool { AXIsProcessTrusted() }

    public func requestAccessPrompt() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    public func openSettings() -> Bool {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}

@MainActor
public final class AccessibilitySelectionService: AccessibilitySelectionReading {
    private var retainedTargets: [SelectionTargetToken: AXUIElement] = [:]
    private var retainedWindows: [SelectionWindowToken: AXUIElement] = [:]

    public init() {}

    public func readSelection() throws -> AccessibilitySelectionResult {
        guard AXIsProcessTrusted() else {
            return .permissionMissing
        }
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return .unavailable(context: .unavailable)
        }

        let processID = application.processIdentifier
        let axApplication = AXUIElementCreateApplication(processID)
        retainedTargets.removeAll(keepingCapacity: true)
        retainedWindows.removeAll(keepingCapacity: true)
        let focusedWindowToken = retainFocusedWindow(from: axApplication)
        let focusedResult = copyElementAttribute(
            kAXFocusedUIElementAttribute,
            from: axApplication
        )

        let focusedElement: AXUIElement
        switch focusedResult {
        case .success(let element):
            focusedElement = element
        case .unavailable:
            return .unavailable(
                context: SelectionTargetContext(
                    frontmostProcessID: processID,
                    focusedWindowToken: focusedWindowToken,
                    targetToken: nil,
                    selectedRange: nil
                )
            )
        case .permissionMissing:
            return .permissionMissing
        case .failure:
            throw EnLLMError.selectionCaptureFailed
        }

        if isSecure(focusedElement) {
            return .secureField
        }

        let token = SelectionTargetToken()
        retainedTargets[token] = focusedElement
        let context = SelectionTargetContext(
            frontmostProcessID: processID,
            focusedWindowToken: focusedWindowToken,
            targetToken: token,
            selectedRange: selectedRange(from: focusedElement)
        )

        var selectedValue: CFTypeRef?
        let selectedResult = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        )

        switch selectedResult {
        case .success:
            guard let selectedText = selectedValue as? String else {
                return .unavailable(context: context)
            }
            guard !selectedText.isEmpty else {
                return .empty
            }
            return .selected(selectedText, context: context)
        case .attributeUnsupported, .noValue, .notImplemented:
            return .unavailable(context: context)
        case .apiDisabled:
            return .permissionMissing
        default:
            throw EnLLMError.selectionCaptureFailed
        }
    }

    public func readCurrentTarget(
        for capture: SelectionCapture,
        includeSelectedText: Bool
    ) -> CurrentSelectionTarget {
        let currentProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard AXIsProcessTrusted(), let currentProcessID else {
            return CurrentSelectionTarget(
                frontmostProcessID: currentProcessID,
                focusedWindowMatches: nil,
                focusedElementMatches: nil,
                selectedRange: nil,
                selectedText: nil
            )
        }

        let application = AXUIElementCreateApplication(currentProcessID)
        let focusedWindow = successfulElement(
            copyElementAttribute(kAXFocusedWindowAttribute, from: application)
        )
        let focusedElement = successfulElement(
            copyElementAttribute(kAXFocusedUIElementAttribute, from: application)
        )

        let windowMatches: Bool?
        if let token = capture.targetContext.focusedWindowToken,
           let capturedWindow = retainedWindows[token],
           let focusedWindow {
            windowMatches = CFEqual(focusedWindow, capturedWindow)
        } else {
            windowMatches = nil
        }

        let elementMatches: Bool?
        if let token = capture.targetContext.targetToken,
           let capturedElement = retainedTargets[token],
           let focusedElement {
            elementMatches = CFEqual(focusedElement, capturedElement)
        } else {
            elementMatches = nil
        }

        return CurrentSelectionTarget(
            frontmostProcessID: currentProcessID,
            focusedWindowMatches: windowMatches,
            focusedElementMatches: elementMatches,
            selectedRange: focusedElement.flatMap { selectedRange(from: $0) },
            selectedText: includeSelectedText ? focusedElement.flatMap { selectedText(from: $0) } : nil
        )
    }

    private enum ElementAttributeResult {
        case success(AXUIElement)
        case unavailable
        case permissionMissing
        case failure
    }

    private func retainFocusedWindow(from application: AXUIElement) -> SelectionWindowToken? {
        guard case .success(let window) = copyElementAttribute(
            kAXFocusedWindowAttribute,
            from: application
        ) else {
            return nil
        }
        let token = SelectionWindowToken()
        retainedWindows[token] = window
        return token
    }

    private func successfulElement(_ result: ElementAttributeResult) -> AXUIElement? {
        guard case .success(let element) = result else { return nil }
        return element
    }

    private func copyElementAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> ElementAttributeResult {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        switch result {
        case .success:
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return .failure
            }
            return .success(unsafeDowncast(value, to: AXUIElement.self))
        case .attributeUnsupported, .noValue, .notImplemented:
            return .unavailable
        case .apiDisabled:
            return .permissionMissing
        default:
            return .failure
        }
    }

    private func selectedRange(from element: AXUIElement) -> TextSelectionRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }

        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range), range.location >= 0, range.length >= 0 else {
            return nil
        }
        return TextSelectionRange(location: range.location, length: range.length)
    }

    private func selectedText(from element: AXUIElement) -> String? {
        guard !isSecure(element) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        attributeString(kAXSubroleAttribute, from: element) == kAXSecureTextFieldSubrole as String
    }

    private func attributeString(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
