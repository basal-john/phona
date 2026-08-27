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
/// The left key only. `maskAlternate` is set by either one, so watching it meant the right
/// key started dictations too, which is the one Option most often reached for as a modifier.
/// `OptionKey` reads the side out of the device-dependent flag bits, and the right key is
/// treated as an ordinary modifier from here on.
final class HotkeyMonitor {
    var onBegin: () -> Void = {}
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
    private var optionDown = false
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
            DispatchQueue.main.async { self.onBegin() }
        case .stop:
            DispatchQueue.main.async { self.onEnd() }
        case .abort:
            DispatchQueue.main.async { self.onAbort() }
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Paths.log("event tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input"), re-enabling")
            optionDown = false
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
            if optionDown {
                perform(toggle.otherKeyPressed())
            }
            return
        }

        let flags = event.flags
        if probing {
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            Paths.log(String(
                format: "hotkey probe: keycode %lld (%@), flags %#010llx, left %@, right %@, ours %@",
                keycode,
                OptionKey.side(ofKeycode: keycode).map { $0 == .left ? "left option" : "right option" }
                    ?? "not option",
                flags.rawValue,
                OptionKey.leftIsDown(flags: flags.rawValue) ? "down" : "up",
                OptionKey.rightIsDown(flags: flags.rawValue) ? "down" : "up",
                OptionKey.dictationSideIsDown(flags: flags.rawValue) ? "yes" : "no"))
        }

        if OptionKey.optionWithoutSide(flags: flags.rawValue), !reportedSidelessOption {
            reportedSidelessOption = true
            Paths.log(String(
                format: "this keyboard reports Option with no side bit (flags %#010llx), so the "
                    + "tap cannot be told from the right key and dictation will not start",
                flags.rawValue))
        }

        let alt = OptionKey.dictationSideIsDown(flags: flags.rawValue)
        let altAlone = OptionKey.armsDictation(flags: flags.rawValue)

        if altAlone && !optionDown {
            optionDown = true
            perform(toggle.optionDown(at: Date()))
        } else if optionDown && !alt {
            optionDown = false
            perform(toggle.optionUp(at: Date()))
        } else if optionDown && !altAlone {
            // Another modifier joined, so this press is a shortcut rather than a tap.
            perform(toggle.otherKeyPressed())
        }
    }
}
