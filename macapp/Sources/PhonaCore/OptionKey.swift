import Foundation

/// Which Option key an event was about.
public enum OptionSide: Equatable {
    case left
    case right
}

/// Tells the two Option keys apart.
///
/// `CGEventFlags.maskAlternate` is set by either key, so it cannot answer this on its own.
/// The side lives in the device-dependent bits that IOKit puts in the same field, which are
/// the only side-aware signal a listening tap gets. The keycode says which key changed but
/// not what is still held, so state comes from the bits and the keycode is only used to
/// recognise that a change concerned Option at all.
public enum OptionKey {
    /// Virtual keycodes, `kVK_Option` and `kVK_RightOption`.
    public static let leftKeycode: Int64 = 58
    public static let rightKeycode: Int64 = 61

    /// `NX_DEVICELALTKEYMASK` and `NX_DEVICERALTKEYMASK`.
    public static let leftMask: UInt64 = 0x0000_0020
    public static let rightMask: UInt64 = 0x0000_0040

    /// `CGEventFlags.maskAlternate`, either side.
    public static let eitherMask: UInt64 = 0x0008_0000

    public static func side(ofKeycode keycode: Int64) -> OptionSide? {
        switch keycode {
        case leftKeycode: return .left
        case rightKeycode: return .right
        default: return nil
        }
    }

    public static func leftIsDown(flags: UInt64) -> Bool { flags & leftMask != 0 }
    public static func rightIsDown(flags: UInt64) -> Bool { flags & rightMask != 0 }
    public static func eitherIsDown(flags: UInt64) -> Bool { flags & eitherMask != 0 }

    /// Whether the Option key that starts a dictation is held. The left one, and only ever
    /// the left one.
    ///
    /// Strictly the left bit, with no fallback for a keyboard that reports Option without any
    /// side bit at all. Treating a sideless Option as the left key would let the right key
    /// start dictations on such a setup, which is the whole thing being fixed. The cost is
    /// that the hotkey would not work there, so `optionWithoutSide` exists to make that
    /// diagnosable rather than mysterious.
    public static func dictationSideIsDown(flags: UInt64) -> Bool {
        leftIsDown(flags: flags)
    }

    /// Option is held but neither side bit is set, so no keyboard side can be established.
    /// Logged rather than guessed at.
    public static func optionWithoutSide(flags: UInt64) -> Bool {
        eitherIsDown(flags: flags) && !leftIsDown(flags: flags) && !rightIsDown(flags: flags)
    }

    /// Whether the only Option key held is the right one, which is now an ordinary modifier
    /// rather than a hotkey, and so has to cancel an arming hold the way any other key does.
    public static func onlyRightIsDown(flags: UInt64) -> Bool {
        rightIsDown(flags: flags) && !leftIsDown(flags: flags)
    }
}
