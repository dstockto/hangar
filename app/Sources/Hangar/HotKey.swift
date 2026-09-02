import AppKit
import Carbon.HIToolbox

/// Global hotkeys via RegisterEventHotKey. Chosen over an event tap on purpose:
/// Carbon hotkeys register with the window server, so they need no Accessibility
/// or Input Monitoring grant and the user is never shown a permission prompt.
final class HotKeyManager {
    struct Spec: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32
        var display: String
    }

    private struct Registration {
        var ref: EventHotKeyRef
        var action: () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private static let signature: OSType = 0x484E4752  // 'HNGR'

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.fire(id.id)
            return noErr
        }, 1, &spec, context, &handler)
    }

    deinit {
        unregisterAll()
        if let handler { RemoveEventHandler(handler) }
    }

    private func fire(_ id: UInt32) {
        registrations[id]?.action()
    }

    /// Registers one hotkey. Returns false when the combination is already taken
    /// by another app, which is information the user needs rather than a crash.
    @discardableResult
    func register(_ spec: Spec, action: @escaping () -> Void) -> Bool {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            spec.keyCode, spec.modifiers,
            EventHotKeyID(signature: HotKeyManager.signature, id: id),
            GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        registrations[id] = Registration(ref: ref, action: action)
        return true
    }

    func unregisterAll() {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
    }

    /// Parses a human-written combination such as "cmd+shift+h" or "ctrl+opt+space".
    static func parse(_ text: String) -> Spec? {
        var modifiers: UInt32 = 0
        var keyToken: String?
        var parts: [String] = []

        for raw in text.lowercased().split(whereSeparator: { $0 == "+" || $0 == "-" || $0 == " " }) {
            let token = String(raw).trimmingCharacters(in: .whitespaces)
            switch token {
            case "cmd", "command", "⌘":       modifiers |= UInt32(cmdKey);     parts.append("⌘")
            case "shift", "⇧":                modifiers |= UInt32(shiftKey);   parts.append("⇧")
            case "opt", "option", "alt", "⌥": modifiers |= UInt32(optionKey);  parts.append("⌥")
            case "ctrl", "control", "⌃":      modifiers |= UInt32(controlKey); parts.append("⌃")
            case "":                          continue
            default:                          keyToken = token
            }
        }
        guard let keyToken, let keyCode = HotKeyManager.keyCodes[keyToken] else { return nil }
        guard modifiers != 0 else { return nil }  // a bare key would hijack all typing
        parts.append(keyToken.count == 1 ? keyToken.uppercased() : keyToken)
        return Spec(keyCode: keyCode, modifiers: modifiers, display: parts.joined())
    }

    static let keyCodes: [String: UInt32] = {
        var map: [String: UInt32] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
            "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
            "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
            "k": 40, "n": 45, "m": 46,
            "return": UInt32(kVK_Return), "enter": UInt32(kVK_Return),
            "space": UInt32(kVK_Space), "tab": UInt32(kVK_Tab),
            "escape": UInt32(kVK_Escape), "esc": UInt32(kVK_Escape),
            "left": UInt32(kVK_LeftArrow), "right": UInt32(kVK_RightArrow),
            "up": UInt32(kVK_UpArrow), "down": UInt32(kVK_DownArrow),
            "backslash": UInt32(kVK_ANSI_Backslash), "slash": UInt32(kVK_ANSI_Slash),
            "period": UInt32(kVK_ANSI_Period), "comma": UInt32(kVK_ANSI_Comma),
            "semicolon": UInt32(kVK_ANSI_Semicolon), "quote": UInt32(kVK_ANSI_Quote),
        ]
        let functionKeys: [UInt32] = [
            UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
            UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
            UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
        ]
        for (index, code) in functionKeys.enumerated() { map["f\(index + 1)"] = code }
        return map
    }()
}
