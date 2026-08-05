import AppKit
import Foundation

/// What could not be carried across a paste.
public enum ClipboardLoss: Equatable {
    /// Everything on the clipboard was copied and can be put back.
    case none
    /// Some items could not be read, and the rest can be put back.
    case partial
    /// Nothing could be read. A file promise looks like this: the pasteboard advertises a
    /// type and produces the bytes only when a real receiver asks for them.
    case unreadable
    /// Too much data to copy, so nothing was.
    case tooLarge
}

/// A copy of everything on the clipboard, taken before a dictation replaces it.
///
/// The bytes are copied eagerly and deliberately. `NSPasteboardItem` objects owned by a
/// pasteboard stop reporting anything the moment `clearContents()` is called, so holding the
/// items and reading them afterwards returns nothing at all.
///
/// Types are kept in the order the pasteboard reported them, because that order is the
/// preference list a receiving app walks when it decides which representation to take. A
/// dictionary would have reordered them arbitrarily and quietly changed what pasting
/// produces.
public struct ClipboardSnapshot: Equatable {
    public struct Entry: Equatable {
        public let type: String
        public let data: Data

        public init(type: String, data: Data) {
            self.type = type
            self.data = data
        }
    }

    public struct Item: Equatable {
        public let entries: [Entry]

        public init(entries: [Entry]) {
            self.entries = entries
        }
    }

    public let items: [Item]
    public let loss: ClipboardLoss

    /// Above this, the clipboard is left alone rather than copied into memory. A screenshot
    /// is a few megabytes, so the cap is only reached by something like a copied video,
    /// where holding a second copy for the length of a dictation is the worse trade.
    public static let byteLimit = 32 * 1024 * 1024

    public static let tooLarge = ClipboardSnapshot(items: [], loss: .tooLarge)

    public init(items: [Item], loss: ClipboardLoss) {
        self.items = items
        self.loss = loss
    }

    /// Nothing was copied, because nothing was going to be put back.
    public static let notTaken = ClipboardSnapshot(items: [], loss: .none)

    /// Decide what is restorable from what the pasteboard reported, one item at a time.
    ///
    /// Loss is counted at two levels, because both change what a later paste produces. An
    /// item whose every type returned nothing is gone outright, which is what a promised file
    /// and an item waiting on Universal Clipboard both look like. An item that gave up some of
    /// its types and not others comes back diminished, and an app that wanted one of the
    /// missing representations will quietly take a different one instead. Counting whole items
    /// alone reported that second case as no loss at all.
    ///
    /// An item that advertises no types is neither: there was nothing there to lose.
    public static func from(_ reported: [[(type: String, data: Data?)]]) -> ClipboardSnapshot {
        var items: [Item] = []
        var lostItems = 0
        var lostTypes = 0

        for entries in reported {
            let usable = entries.compactMap { pair in
                pair.data.map { Entry(type: pair.type, data: $0) }
            }
            if usable.isEmpty {
                if !entries.isEmpty { lostItems += 1 }
            } else {
                lostTypes += entries.count - usable.count
                items.append(Item(entries: usable))
            }
        }

        let loss: ClipboardLoss
        if lostItems == 0, lostTypes == 0 {
            loss = .none
        } else {
            loss = items.isEmpty ? .unreadable : .partial
        }
        return ClipboardSnapshot(items: items, loss: loss)
    }

    /// Whether there is anything worth putting back. False for an empty clipboard, which is
    /// not a loss and must not be reported as one.
    public var canRestore: Bool { !items.isEmpty }

    /// What to tell the user, or nil when nothing was lost.
    public var warning: String? {
        switch loss {
        case .none:
            return nil
        case .partial:
            return "Part of your clipboard could not be copied. The rest has been put back."
        case .unreadable:
            return "Your clipboard held something Phona cannot copy, such as a promised file. "
                + "It has been replaced and cannot be restored."
        case .tooLarge:
            return "Your clipboard held more than \(ClipboardSnapshot.byteLimit / 1_048_576) MB, "
                + "so it was not copied. It has been replaced and cannot be restored."
        }
    }
}

/// Reads and writes a real pasteboard.
///
/// Separate from the decisions above so the decisions can be tested on their own, and kept
/// here rather than in the app so both halves can be exercised against a private pasteboard
/// instead of the user's own.
public enum ClipboardStore {
    /// Copy everything a pasteboard will hand over.
    ///
    /// The running total is checked while reading rather than afterwards, because the point
    /// of the cap is to not hold the bytes in the first place. Hitting it abandons the whole
    /// snapshot: restoring the first few items of a clipboard and dropping the rest would
    /// leave the user with something that looks intact and is not.
    public static func snapshot(of board: NSPasteboard) -> ClipboardSnapshot {
        var reported: [[(type: String, data: Data?)]] = []
        var bytes = 0

        for item in board.pasteboardItems ?? [] {
            var entries: [(type: String, data: Data?)] = []
            for type in item.types {
                let data = item.data(forType: type)
                if let data {
                    bytes += data.count
                    if bytes > ClipboardSnapshot.byteLimit { return .tooLarge }
                }
                entries.append((type.rawValue, data))
            }
            reported.append(entries)
        }
        return ClipboardSnapshot.from(reported)
    }

    /// Put a snapshot back, replacing whatever is on the pasteboard now.
    @discardableResult
    public static func restore(_ snapshot: ClipboardSnapshot, to board: NSPasteboard) -> Bool {
        guard snapshot.canRestore else { return false }
        let items = snapshot.items.map { item -> NSPasteboardItem in
            let restored = NSPasteboardItem()
            for entry in item.entries {
                restored.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type))
            }
            return restored
        }
        board.clearContents()
        return board.writeObjects(items)
    }
}
