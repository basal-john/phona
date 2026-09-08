import AppKit
import Foundation
import PhonaCore

/// Watches the left Option key without remapping it.
///
/// A listen-only event tap observes flag changes and key presses. Option keeps working
/// normally for Option+click, Option+e and every other shortcut.
///
/// Tap Option to start dictating, tap it again to stop. `TapToggle` holds the decision and
/// its tests hold the behaviour, because a live event tap and a real keyboard cannot be put
/// in a unit test. This class only classifies events and forwards them.
///
/// Both Option keys, one dictation. `OptionKey` reads the side out of the device-dependent
/// flag bits, and the side that starts a dictation chooses what cleans it: the left key uses
/// the local model, the right key the cloud one. Either key stops a running dictation, for
/// the reason `TapToggle` already stops on any release: a microphone left open is worse than
/// one closed a moment early, so stopping stays easier than starting.
///
/// A side is only read at the moment a dictation starts. Nothing about the choice can change
/// afterwards, so a dictation cannot end up cleaned by a backend the speaker did not pick.
final class HotkeyMonitor {
    /// `cloud` is true when the right key started this dictation.
    var onBegin: (_ cloud: Bool) -> Void = { _ in }
    var onEnd: () -> Void = {}
    var onAbort: () -> Void = {}

    /// `--probe-hotkey` logs every flag change with the side bits it saw.
    ///
    /// Whether a given keyboard reports the device-dependent bits is not something a unit
    /// test can answer, and the whole left-only behaviour rests on them, so there has to be
    /// a way to read them off a real keyboard.
    var probing = false

    var isRecording: Bool { toggle.isRecording }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var toggle = TapToggle()
    /// The side currently held down alone, or nil when no Option key is arming.
    private var armedSide: OptionSide?
    /// The side that started the dictation now running, which decides what cleans it.
    private var dictationSide: OptionSide = .left
    /// Said once, not on every flag change, because it would otherwise fill the log.
    private var reportedSidelessOption = false

    static func hasAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// The tap is disabled by the system if it ever times out. Put it back.
    func reenableIfNeeded() {
        if let tap, !CGEvent.tapIsEnabled(tap: tap) {
            Paths.log("event tap was found disabled by the poll, re-enabling")
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func perform(_ action: TapAction) {
        switch action {
        case .none:
            return
        case .start:
            let cloud = dictationSide == .right
            DispatchQueue.main.async { self.onBegin(cloud) }
        case .stop:
            DispatchQueue.main.async { self.onEnd() }
        case .abort:
            DispatchQueue.main.async { self.onAbort() }
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Paths.log("event tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input"), re-enabling")
            armedSide = nil
            perform(toggle.reset())
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        if type == .keyDown {
            let escape: Int64 = 53
            if event.getIntegerValueField(.keyboardEventKeycode) == escape {
                perform(toggle.escapePressed())
                return
            }
            if armedSide != nil {
                perform(toggle.otherKeyPressed())
            }
            return
        }

        let flags = event.flags
        if probing {
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            Paths.log(String(
                format: "hotkey probe: keycode %lld (%@), flags %#010llx, left %@, right %@, arms %@",
                keycode,
                OptionKey.side(ofKeycode: keycode).map { $0 == .left ? "left option" : "right option" }
                    ?? "not option",
                flags.rawValue,
                OptionKey.leftIsDown(flags: flags.rawValue) ? "down" : "up",
                OptionKey.rightIsDown(flags: flags.rawValue) ? "down" : "up",
                OptionKey.armsDictation(flags: flags.rawValue) ? "local"
                    : OptionKey.armsCloudDictation(flags: flags.rawValue) ? "cloud" : "nothing"))
        }

        if OptionKey.optionWithoutSide(flags: flags.rawValue), !reportedSidelessOption {
            reportedSidelessOption = true
            Paths.log(String(
                format: "this keyboard reports Option with no side bit (flags %#010llx), so the "
                    + "tap cannot be told from the right key and dictation will not start",
                flags.rawValue))
        }

        if let side = armedSide {
            if !sideIsDown(side, flags: flags.rawValue) {
                armedSide = nil
                let action = toggle.optionUp(at: Date())
                /// Read the side only on a start. A stop keeps whichever side opened the
                /// dictation, so releasing the other key cannot reroute text already spoken.
                if action == .start { dictationSide = side }
                perform(action)
            } else if !sideArms(side, flags: flags.rawValue) {
                // Another modifier joined, so this press is a shortcut rather than a tap.
                perform(toggle.otherKeyPressed())
            }
            return
        }

        /// The left key is asked first. Both keys down arms neither, so the order only
        /// decides which one is tested, never which one wins.
        if OptionKey.armsDictation(flags: flags.rawValue) {
            armedSide = .left
            perform(toggle.optionDown(at: Date()))
        } else if OptionKey.armsCloudDictation(flags: flags.rawValue) {
            armedSide = .right
            perform(toggle.optionDown(at: Date()))
        }
    }

    private func sideIsDown(_ side: OptionSide, flags: UInt64) -> Bool {
        side == .left ? OptionKey.leftIsDown(flags: flags) : OptionKey.rightIsDown(flags: flags)
    }

    private func sideArms(_ side: OptionSide, flags: UInt64) -> Bool {
        side == .left
            ? OptionKey.armsDictation(flags: flags)
            : OptionKey.armsCloudDictation(flags: flags)
    }
}
