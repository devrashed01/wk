import Carbon.HIToolbox
import Foundation

/// A system-wide hotkey via Carbon's RegisterEventHotKey (no Accessibility permission needed).
final class HotKey {
    struct Combo: Hashable, Identifiable {
        let id: String
        let label: String
        let keyCode: UInt32
        let modifiers: UInt32
    }

    /// Choices offered in Settings (stored by id in the config's `hotkey`).
    static let choices: [Combo] = [
        Combo(id: "option+space", label: "⌥ Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)),
        Combo(id: "control+space", label: "⌃ Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey)),
        Combo(id: "command+shift+space", label: "⇧⌘ Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey)),
        Combo(id: "control+option+w", label: "⌃⌥ W", keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(controlKey | optionKey)),
        Combo(id: "command+option+k", label: "⌥⌘ K", keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | optionKey)),
    ]

    static func combo(for id: String?) -> Combo {
        choices.first { $0.id == id } ?? choices[0]
    }

    private var reference: EventHotKeyRef?
    private var handlerReference: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerReference)
    }

    @discardableResult
    func register(_ combo: Combo) -> Bool {
        unregister()
        let identifier = EventHotKeyID(signature: OSType(0x776B_6B79), id: 1) // "wkky"
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
        return status == noErr
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }

    deinit {
        unregister()
        if let handlerReference { RemoveEventHandler(handlerReference) }
    }
}
