import AppKit
import Carbon

/// A global keyboard shortcut that tells us when it is pressed and when it is
/// released, so we can do "hold to talk". It works from any app and needs no
/// special permission.
public final class HotKey {
    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?

    private var ref: EventHotKeyRef?
    nonisolated(unsafe) private static var current: HotKey?
    nonisolated(unsafe) private static var handlerInstalled = false

    public init?(keyCode: UInt32, modifiers: UInt32) {
        HotKey.current = self
        if !HotKey.handlerInstalled {
            var specs = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
            ]
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                guard let event else { return noErr }
                let kind = GetEventKind(event)
                DispatchQueue.main.async {
                    if kind == UInt32(kEventHotKeyPressed) { HotKey.current?.onPress?() }
                    else if kind == UInt32(kEventHotKeyReleased) { HotKey.current?.onRelease?() }
                }
                return noErr
            }, 2, &specs, nil, nil)
            HotKey.handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x636C_6431), id: 1)   // 'cld1'
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { return nil }
    }

    deinit { if let ref { UnregisterEventHotKey(ref) } }

    /// Turn text like "option+space" or "ctrl+shift+k" into a key code and modifier flags.
    public static func parse(_ text: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        var mods: UInt32 = 0
        var key: UInt32?
        for part in text.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": mods |= UInt32(cmdKey)
            case "ctrl", "control": mods |= UInt32(controlKey)
            case "opt", "option", "alt": mods |= UInt32(optionKey)
            case "shift": mods |= UInt32(shiftKey)
            default: key = keyCodes[part]
            }
        }
        guard let key, mods != 0 else { return nil }
        return (key, mods)
    }

    private static let keyCodes: [String: UInt32] = [
        "space": 49, "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34,
        "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]
}
