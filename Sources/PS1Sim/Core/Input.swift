import Foundation
import AppKit

/// libretro joypad button ids (RETRO_DEVICE_ID_JOYPAD_*).
enum PadButton: UInt32, CaseIterable, Codable {
    case cross = 0      // B
    case square = 1     // Y
    case select = 2
    case start = 3
    case up = 4
    case down = 5
    case left = 6
    case right = 7
    case circle = 8     // A
    case triangle = 9   // X
    case l1 = 10
    case r1 = 11
    case l2 = 12
    case r2 = 13
    case l3 = 14
    case r3 = 15

    var label: String {
        switch self {
        case .cross: return "Cross ✕"
        case .circle: return "Circle ○"
        case .square: return "Square ▢"
        case .triangle: return "Triangle △"
        case .up: return "D-Pad Up"
        case .down: return "D-Pad Down"
        case .left: return "D-Pad Left"
        case .right: return "D-Pad Right"
        case .start: return "Start"
        case .select: return "Select"
        case .l1: return "L1"
        case .r1: return "R1"
        case .l2: return "L2"
        case .r2: return "R2"
        case .l3: return "L3"
        case .r3: return "R3"
        }
    }

    /// Display order in the settings sheet.
    static var displayOrder: [PadButton] {
        [.up, .down, .left, .right, .cross, .circle, .square, .triangle,
         .l1, .r1, .l2, .r2, .l3, .r3, .start, .select]
    }
}

/// Analog stick directions, mapped to RETRO_DEVICE_ANALOG axes.
enum PadAxis: String, CaseIterable, Codable {
    case leftUp, leftDown, leftLeft, leftRight
    case rightUp, rightDown, rightLeft, rightRight

    var label: String {
        switch self {
        case .leftUp: return "Left Stick Up"
        case .leftDown: return "Left Stick Down"
        case .leftLeft: return "Left Stick Left"
        case .leftRight: return "Left Stick Right"
        case .rightUp: return "Right Stick Up"
        case .rightDown: return "Right Stick Down"
        case .rightLeft: return "Right Stick Left"
        case .rightRight: return "Right Stick Right"
        }
    }

    /// (index, axisID, sign) where index 0 = left stick, axisID 0 = X.
    var target: (index: UInt32, axis: UInt32, sign: Int16) {
        switch self {
        case .leftLeft:   return (0, 0, -1)
        case .leftRight:  return (0, 0, 1)
        case .leftUp:     return (0, 1, -1)
        case .leftDown:   return (0, 1, 1)
        case .rightLeft:  return (1, 0, -1)
        case .rightRight: return (1, 0, 1)
        case .rightUp:    return (1, 1, -1)
        case .rightDown:  return (1, 1, 1)
        }
    }
}

/// Virtual key codes (kVK_*) we bind by default.
enum KeyCode {
    static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
        56: "Shift", 60: "Right Shift", 59: "Control", 58: "Option", 55: "Command",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
    ]

    static func name(for code: UInt16) -> String { names[code] ?? "Key \(code)" }
}

/// Keyboard → controller state. Read on the emulation thread, written on the main
/// thread by the event monitor, so both sides go through the lock.
final class InputState: @unchecked Sendable {
    private let lock = NSLock()
    private var pressed = Set<UInt16>()

    var buttonMap: [UInt16: PadButton] = InputState.defaultButtonMap
    var axisMap: [UInt16: PadAxis] = InputState.defaultAxisMap

    /// Latest physical controller state, if one is connected. Kept separate from
    /// the keyboard so neither can clear the other's buttons.
    private var padButtons = Set<PadButton>()
    private var padAxes: [UInt32: Int16] = [:]

    /// Packs a libretro (stick index, axis id) pair into one dictionary key.
    static func axisKey(index: UInt32, axis: UInt32) -> UInt32 { index << 8 | axis }

    func setGamepad(buttons: Set<PadButton>, axes: [UInt32: Int16]) {
        lock.lock(); padButtons = buttons; padAxes = axes; lock.unlock()
    }

    func clearGamepad() {
        lock.lock(); padButtons.removeAll(); padAxes.removeAll(); lock.unlock()
    }

    static let defaultButtonMap: [UInt16: PadButton] = [
        126: .up, 125: .down, 123: .left, 124: .right,
        7: .cross,       // X
        8: .circle,      // C
        6: .square,      // Z
        1: .triangle,    // S
        0: .l1,          // A
        2: .r1,          // D
        12: .l2,         // Q
        14: .r2,         // E
        15: .l3,         // R
        17: .r3,         // T
        36: .start,      // Return
        60: .select,     // Right Shift
    ]

    static let defaultAxisMap: [UInt16: PadAxis] = [
        34: .leftUp,     // I
        40: .leftDown,   // K
        38: .leftLeft,   // J
        37: .leftRight,  // L
    ]

    func setKey(_ code: UInt16, down: Bool) {
        lock.lock()
        if down { pressed.insert(code) } else { pressed.remove(code) }
        lock.unlock()
    }

    func releaseAll() {
        lock.lock(); pressed.removeAll(); lock.unlock()
    }

    /// True if any key bound to `button` is currently held.
    func isPressed(_ button: PadButton) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if padButtons.contains(button) { return true }
        for (code, mapped) in buttonMap where mapped == button && pressed.contains(code) {
            return true
        }
        return false
    }

    /// Analog axis value in libretro's -32767...32767 range.
    func axisValue(index: UInt32, axis: UInt32) -> Int16 {
        lock.lock(); defer { lock.unlock() }
        var value: Int32 = 0
        for (code, direction) in axisMap where pressed.contains(code) {
            let target = direction.target
            if target.index == index && target.axis == axis {
                value += Int32(target.sign) * 32767
            }
        }
        let keyboard = Int16(max(-32767, min(32767, value)))
        // Whichever input is pushed further wins, so a resting stick never cancels
        // a held key and a held key never caps the stick.
        let stick = padAxes[InputState.axisKey(index: index, axis: axis)] ?? 0
        return abs(Int32(stick)) > abs(Int32(keyboard)) ? stick : keyboard
    }

    /// Is this key bound to anything? Used to decide whether to swallow the event.
    func isBound(_ code: UInt16) -> Bool {
        buttonMap[code] != nil || axisMap[code] != nil
    }
}
