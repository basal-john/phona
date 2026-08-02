import AppKit
import Foundation

/// Watches the Option key without remapping it.
///
/// A listen-only event tap observes flag changes and key presses. Option keeps working
/// normally for Option+click, Option+e and every other shortcut. A hold only counts once
/// Option has been down alone for `holdDelay` with no other key pressed.
final class HotkeyMonitor {
    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}
    var onAbort: () -> Void = {}
    /// Double-tapping Option starts hands-free dictation, which runs until the next
    /// double tap or Escape. Holding a key down through a long dictation is tiring, and
    /// this reuses the same key rather than asking the user to learn a second one.
    var onToggleHandsFree: () -> Void = {}

    var holdDelay: TimeInterval = 0.25
    var doubleTapWindow: TimeInterval = 0.4
    /// Set by the app while a hands-free dictation is running.
    var handsFree = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var optionDown = false
    private var dirty = false
    private var armed = false
    private var timer: Timer?
    private var lastTapEnded: Date?

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
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
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
        let alt = flags.contains(.maskAlternate)
        let others = flags.contains(.maskCommand) || flags.contains(.maskControl)
            || flags.contains(.maskShift) || flags.contains(.maskSecondaryFn)
        let altAlone = alt && !others

        if altAlone && !optionDown {
            optionDown = true
            dirty = false
            cancelTimer()

            // A second quick tap inside the window means hands-free, not a hold.
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
                // Too short to be a hold. Remember it, so a second one counts as a double tap.
                lastTapEnded = Date()
            }
        } else if optionDown && !altAlone {
            // Another modifier joined, so this is a real shortcut rather than a dictation.
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
