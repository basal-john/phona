import XCTest
@testable import PhonaCore

/// The privacy dot, which is the one claim in this window that may never over-state safety.
final class RouteTests: XCTestCase {

    private static let berlin = TimeZone(identifier: "Europe/Berlin")!

    private func row(_ json: String) -> HistoryRow {
        guard let parsed = HistoryParser.row(from: json, timeZone: Self.berlin) else {
            preconditionFailure("the line did not parse: \(json)")
        }
        return parsed
    }

    private func line(mode: String?, backend: String?, cloudSent: Bool?) -> String {
        var fields = ["\"ts\": \"2026-09-08T09:00:00\"", "\"text\": \"Delivered.\"",
                      "\"raw\": \"delivered\"", "\"source\": \"voice\""]
        if let mode { fields.append("\"mode\": \"\(mode)\"") }
        if let backend { fields.append("\"backend\": \"\(backend)\"") }
        if let cloudSent { fields.append("\"cloud_sent\": \(cloudSent)") }
        return "{\(fields.joined(separator: ", "))}"
    }

    /// The finding this file exists for. `correct_cloud` clears `backend` when the local
    /// guard refuses the cloud reply, and the transcript has already been piped to an agent
    /// CLI by then, so a dot taken from `backend` promised the text never left the Mac.
    func testARefusedCloudReplyStillReadsAsHavingLeftTheMac() {
        let refused = row(line(mode: "cloud", backend: nil, cloudSent: true))

        XCTAssertEqual(refused.route, .cloud)
        XCTAssertNil(refused.backend, "a refused reply was not the one delivered")
    }

    func testACloudReplyThatWasUsedReadsAsHavingLeftTheMac() {
        XCTAssertEqual(row(line(mode: "cloud", backend: "claude", cloudSent: true)).route,
                       .cloud)
    }

    /// The right Option key with no agent CLI installed. `cloud_correct` raises before any
    /// process starts, so nothing was sent and the row may say so.
    func testARightOptionDictationThatSentNothingReadsAsLocal() {
        XCTAssertEqual(row(line(mode: "cloud", backend: nil, cloudSent: false)).route, .local)
    }

    func testALocalDictationReadsAsLocal() {
        XCTAssertEqual(row(line(mode: "correct", backend: nil, cloudSent: false)).route,
                       .local)
    }

    /// Rows written before `cloud_sent` existed fall back to the key that was held. That
    /// over-states leaving for the not-installed case and never under-states it, which is
    /// the only direction a privacy claim may be wrong in.
    func testAnOlderRowFallsBackToTheKeyThatWasHeld() {
        let old = row(line(mode: "cloud", backend: nil, cloudSent: nil))

        XCTAssertNil(old.cloudSent, "the key is absent, which is not the same as false")
        XCTAssertEqual(old.route, .cloud)
        XCTAssertEqual(row(line(mode: "cloud", backend: "claude", cloudSent: nil)).route,
                       .cloud)
        XCTAssertEqual(row(line(mode: "correct", backend: nil, cloudSent: nil)).route, .local)
        XCTAssertEqual(row(line(mode: nil, backend: nil, cloudSent: nil)).route, .local)
        XCTAssertEqual(row(line(mode: nil, backend: "claude", cloudSent: nil)).route, .cloud,
                       "a vintage that recorded a backend but no mode still left this Mac")
    }

    /// A false `cloud_sent` outranks a `mode` of cloud, because the engine wrote the flag
    /// and the flag is the witness. Reading `mode` first would undo the whole fix.
    func testTheRecordedFlagWinsOverTheKey() {
        XCTAssertEqual(row(line(mode: "cloud", backend: nil, cloudSent: false)).cloudSent,
                       false)
        XCTAssertEqual(row(line(mode: "correct", backend: nil, cloudSent: true)).route,
                       .cloud)
    }
}
