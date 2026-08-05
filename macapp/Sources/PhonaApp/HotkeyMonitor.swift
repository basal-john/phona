import AppKit
import Foundation
import PhonaCore

/// Watches the left Option key without remapping it.
///
/// A listen-only event tap observes flag changes and key presses. Option keeps working
/// normally for Option+click, Option+e and every other shortcut. A hold only counts once
/// Option has been down alone for `holdDelay` with no other key pressed.
///
/// The left key only. `maskAlternate` is set by either one, so watching it meant the right
/// key started dictations too, which is the one Option most often reached for as a modifier.
/// `OptionKey` reads the side out of the device-dependent flag bits, and the right key is
/// treated as an ordinary modifier from here on.
final class HotkeyMonitor {
    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}
    var onAbort: () -> Void = {}
    /// Double-tapping Option starts hands-free dictation, which runs until the next
    /// double tap or Escape. Holding a key down through a long dictation is tiring, and
    /// this reuses the same key rather than asking the user to learn a second one.
    var onToggleHandsFree: () -> Void = {}

    /// The floor on how soon a hold can be acknowledged. Lowered from 250 ms because it is
    /// the whole cost once the main thread stops being blocked, and 250 ms is perceptible.
    /// The cost is arming slightly more readily on a hold that was reaching for a shortcut,
    /// which the dirty flag still cancels the moment a second key lands.
    var holdDelay: TimeInterval = 0.15
    var doubleTapWindow: TimeInterval = 0.4
    /// Set by the app while a hands-free dictation is running.
    var handsFree = false

    /// `--probe-hotkey` logs every flag change with the side bits it saw.
    ///
    /// Whether a given keyboard reports the device-dependent bits is not something a unit
    /// test can answer, and the whole left-only behaviour rests on them, so there has to be
    /// a way to read them off a real keyboard.
    var probing = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var optionDown = false
    private var dirty = false
    private var armed = false
    private var timer: Timer?
    private var lastTapEnded: Date?
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

    /// Classify one event into hold, double tap, or an ordinary shortcut.
    ///
    /// A release too short to be a hold is remembered, so a second one inside
    /// `doubleTapWindow` counts as a double tap and starts hands-free instead. Any other
    /// modifier joining means the user is reaching for a real shortcut, not dictating.
    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Paths.log("event tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input"), re-enabling")
            optionDown = false
            dirty = false
            armed = false
            cancelTimer()
            lastTapEnded = nil
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        if type == .keyDown {
            let escape: Int64 = 53
            if handsFree, event.getIntegerValueField(.keyboardEventKeycode) == escape {
                DispatchQueue.main.async { self.onAbort() }
                return
            }
            if optionDown {
                dirty = true
                cancelTimer()
                lastTapEnded = nil
                if armed { armed = false; DispatchQueue.main.async { self.onAbort() } }
            }
            return
        }

        let flags = event.flags
        if probing {
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            Paths.log(String(
                format: "hotkey probe: keycode %d (%@), flags %#010llx, left %@, right %@, ours %@",
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
                    + "hold cannot be told from the right key and dictation will not arm",
                flags.rawValue))
        }

        let alt = OptionKey.dictationSideIsDown(flags: flags.rawValue)
        let others = flags.contains(.maskCommand) || flags.contains(.maskControl)
            || flags.contains(.maskShift) || flags.contains(.maskSecondaryFn)
            || OptionKey.onlyRightIsDown(flags: flags.rawValue)
        let altAlone = alt && !others

        if altAlone && !optionDown {
            optionDown = true
            dirty = false
            cancelTimer()

            if let last = lastTapEnded, Date().timeIntervalSince(last) < doubleTapWindow {
                lastTapEnded = nil
                DispatchQueue.main.async { self.onToggleHandsFree() }
                return
            }

            let work = Timer(timeInterval: holdDelay, repeats: false) { [weak self] _ in
                guard let self, self.optionDown, !self.dirty, !self.armed else { return }
                self.armed = true
                self.onBegin()
            }
            timer = work
            RunLoop.main.add(work, forMode: .common)
        } else if optionDown && !alt {
            optionDown = false
            cancelTimer()
            if armed {
                armed = false
                lastTapEnded = nil
                DispatchQueue.main.async { self.onEnd() }
            } else if !dirty {
                lastTapEnded = Date()
            }
        } else if optionDown && !altAlone {
            dirty = true
            cancelTimer()
            if armed {
                armed = false
                DispatchQueue.main.async { self.onAbort() }
            }
        }
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }
}
