import AppKit

public struct InputBridge {
    // Linux evdev button constants
    public static let BTN_LEFT: UInt32 = 0x110
    public static let BTN_RIGHT: UInt32 = 0x111
    public static let BTN_MIDDLE: UInt32 = 0x112

    // Converts macOS NSEvent.ModifierFlags to evdev modifiers
    public static func linuxButton(from event: NSEvent) -> UInt32 {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            return BTN_LEFT
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return BTN_RIGHT
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return BTN_MIDDLE
        default:
            return BTN_LEFT
        }
    }

    // Converts macOS virtual keycode to Linux evdev keycode
    public static func linuxKeycode(from macKeyCode: UInt16) -> UInt32 {
        // Standard ANSI keyboard translation table
        switch macKeyCode {
        case 0: return 30   // A -> KEY_A
        case 1: return 31   // S -> KEY_S
        case 2: return 32   // D -> KEY_D
        case 3: return 33   // F -> KEY_F
        case 4: return 35   // H -> KEY_H
        case 5: return 34   // G -> KEY_G
        case 6: return 44   // Z -> KEY_Z
        case 7: return 45   // X -> KEY_X
        case 8: return 46   // C -> KEY_C
        case 9: return 47   // V -> KEY_V
        case 11: return 48  // B -> KEY_B
        case 12: return 16  // Q -> KEY_Q
        case 13: return 17  // W -> KEY_W
        case 14: return 18  // E -> KEY_E
        case 15: return 19  // R -> KEY_R
        case 16: return 21  // Y -> KEY_Y
        case 17: return 20  // T -> KEY_T
        case 18: return 2   // 1 -> KEY_1
        case 19: return 3   // 2 -> KEY_2
        case 20: return 4   // 3 -> KEY_3
        case 21: return 5   // 4 -> KEY_4
        case 22: return 7   // 6 -> KEY_6
        case 23: return 6   // 5 -> KEY_5
        case 24: return 13  // = -> KEY_EQUAL
        case 25: return 10  // 9 -> KEY_9
        case 26: return 8   // 7 -> KEY_7
        case 27: return 12  // - -> KEY_MINUS
        case 28: return 9   // 8 -> KEY_8
        case 29: return 11  // 0 -> KEY_0
        case 31: return 22  // O -> KEY_O
        case 32: return 23  // U -> KEY_U
        case 34: return 24  // I -> KEY_I
        case 35: return 25  // P -> KEY_P
        case 36: return 28  // Return -> KEY_ENTER
        case 37: return 38  // L -> KEY_L
        case 38: return 37  // J -> KEY_J
        case 40: return 36  // K -> KEY_K
        case 45: return 26  // N -> KEY_N
        case 46: return 50  // M -> KEY_M
        case 48: return 15  // Tab -> KEY_TAB
        case 49: return 57  // Space -> KEY_SPACE
        case 51: return 14  // Delete -> KEY_BACKSPACE
        case 53: return 1   // Escape -> KEY_ESC
        case 123: return 105 // Left Arrow -> KEY_LEFT
        case 124: return 106 // Right Arrow -> KEY_RIGHT
        case 125: return 108 // Down Arrow -> KEY_DOWN
        case 126: return 103 // Up Arrow -> KEY_UP
        default:
            return UInt32(macKeyCode + 8)
        }
    }
}
