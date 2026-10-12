import Carbon
import Foundation

/// Asks the current keyboard layout what its keys type. NSMenu matches a shortcut against the
/// character the key produces with Shift, so a shifted punctuation shortcut has to be declared
/// as that character, which depends on the layout ("}" for ⇧⌘] on US, "_" for ⇧⌘- on Danish).
enum KeyboardLayout {
    /// What the key that types `base` unshifted types with Shift, or nil if no key types `base`.
    static func shiftedCharacter(for base: String) -> String? {
        guard let layout = currentLayoutData() else { return nil }
        for code in UInt16(0)..<UInt16(128) {
            guard translate(code, shift: false, layout: layout) == base else { continue }
            return translate(code, shift: true, layout: layout)
        }
        return nil
    }

    private static func currentLayoutData() -> Data? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    }

    private static func translate(_ code: UInt16, shift: Bool, layout: Data) -> String? {
        layout.withUnsafeBytes { buffer -> String? in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
            let status = UCKeyTranslate(
                ptr, code, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars
            )
            guard status == noErr, length == 1 else { return nil }
            let s = String(utf16CodeUnits: chars, count: length)
            // Control characters and dead-key placeholders are not usable key equivalents.
            guard let scalar = s.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F else { return nil }
            return s
        }
    }
}
