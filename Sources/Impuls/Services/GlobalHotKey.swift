import Carbon.HIToolbox
import Foundation

final class GlobalHotKey {
    var onPress: (() -> Void)?
    private(set) var registrationStatus: OSStatus = noErr

    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    init() {
        var event = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        registrationStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return noErr }
                let manager = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { manager.onPress?() }
                return noErr
            },
            1,
            &event,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    deinit {
        unregister()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    @discardableResult
    func register(_ preset: SettingsStore.HotKeyPreset) -> Bool {
        unregister()
        guard eventHandler != nil else { return false }
        guard preset != .disabled else {
            registrationStatus = noErr
            return true
        }

        let modifiers: UInt32
        switch preset {
        case .optionSpace:
            modifiers = UInt32(optionKey)
        case .controlSpace:
            modifiers = UInt32(controlKey)
        case .optionShiftSpace:
            modifiers = UInt32(optionKey | shiftKey)
        case .commandShiftSpace:
            modifiers = UInt32(cmdKey | shiftKey)
        case .disabled:
            modifiers = 0
        }

        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x494D504C, id: 1) // IMPL
        registrationStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        hotKey = registrationStatus == noErr ? reference : nil
        return registrationStatus == noErr
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
}
