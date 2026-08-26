import XCTest
@testable import PhonaCore

final class ChatAppsTests: XCTestCase {

    /// Read off the installed bundles. A typo here means the style silently never applies.
    func testInstalledChatAppsAreRecognisedWithoutATitle() {
        XCTAssertEqual(ChatApps.style(bundleIdentifier: "com.tinyspeck.slackmacgap",
                                      windowTitle: nil), .chat)
        XCTAssertEqual(ChatApps.style(bundleIdentifier: "com.hnc.Discord",
                                      windowTitle: nil), .chat)
        XCTAssertEqual(ChatApps.style(bundleIdentifier: "com.apple.MobileSMS",
                                      windowTitle: nil), .chat)
    }

    func testAnythingElseHasNoStyle() {
        XCTAssertNil(ChatApps.style(bundleIdentifier: "com.microsoft.VSCode", windowTitle: nil))
        XCTAssertNil(ChatApps.style(bundleIdentifier: "com.apple.Terminal", windowTitle: nil))
        XCTAssertNil(ChatApps.style(bundleIdentifier: nil, windowTitle: "Slack"))
    }

    /// Mail used to have no style, because chat was the only one. It is mail now, and this
    /// is the assertion that changed when the second style landed.
    func testMailIsNoLongerStyleless() {
        XCTAssertEqual(ChatApps.style(bundleIdentifier: "com.apple.mail",
                                      windowTitle: nil), .mail)
    }

    /// The titles Slack, Discord and Teams actually put in a browser window, including the
    /// unread counter they carry most of the time and the browser's own suffix.
    func testChatInABrowserIsRecognisedFromItsTitle() {
        let titles = [
            "Slack | general | Thomann",
            "(3) Slack | general | Thomann",
            "general (Channel) - Thomann - Slack - Google Chrome",
            "#general | My Server - Discord",
            "(2) WhatsApp",
            "Chat | Microsoft Teams",
        ]
        for title in titles {
            XCTAssertEqual(ChatApps.style(bundleIdentifier: "com.google.Chrome",
                                          windowTitle: title), .chat, title)
        }
    }

    /// The reason a title segment is matched whole rather than searched for. Every one of
    /// these contains the word slack and none of them is Slack, and styling them would strip
    /// a full stop out of a comment box or a commit message.
    func testAPageMerelyNamedAfterAChatAppIsNotChat() {
        let titles = [
            "slack-notifier CI · GitHub",
            "Fix the slack webhook by basal-john · Pull Request #12 · GitHub",
            "How to install Slackware · Wiki",
            "slack integration guide | Confluence",
        ]
        for title in titles {
            XCTAssertNil(ChatApps.style(bundleIdentifier: "com.google.Chrome",
                                        windowTitle: title), title)
        }
    }

    /// A browser that will not report a title has to fall through to not chat. Guessing the
    /// other way would take the full stop off a document.
    func testABrowserWithNoTitleIsNotChat() {
        XCTAssertNil(ChatApps.style(bundleIdentifier: "com.apple.Safari", windowTitle: nil))
        XCTAssertNil(ChatApps.style(bundleIdentifier: "com.apple.Safari", windowTitle: ""))
    }

    /// Only a browser is worth an accessibility call, and only when there is an app at all.
    func testOnlyBrowsersAreAskedForTheirWindowTitle() {
        XCTAssertTrue(ChatApps.needsWindowTitle("com.google.Chrome"))
        XCTAssertTrue(ChatApps.needsWindowTitle("company.thebrowser.Browser"))
        XCTAssertFalse(ChatApps.needsWindowTitle("com.tinyspeck.slackmacgap"))
        XCTAssertFalse(ChatApps.needsWindowTitle(nil))
    }

    /// A bare hyphen is not a separator, because repository and package names are spelled
    /// with one. A hyphen with spaces around it is how a browser joins a title.
    func testSegmentsSplitOnRealSeparatorsOnly() {
        XCTAssertEqual(ChatApps.segments(of: "Slack | general"), ["slack", "general"])
        XCTAssertEqual(ChatApps.segments(of: "general - Slack"), ["general", "slack"])
        XCTAssertEqual(ChatApps.segments(of: "slack-notifier"), ["slack-notifier"])
        XCTAssertEqual(ChatApps.segments(of: "(12) Slack"), ["slack"])
    }

    /// The raw value is what travels to the daemon, which compares it as a string.
    func testTheRawValueIsTheStringTheDaemonExpects() {
        XCTAssertEqual(MessageStyle.chat.rawValue, "chat")
        XCTAssertEqual(MessageStyle.mail.rawValue, "mail")
    }

    /// A mail client is mail whatever window is open, the same way a chat app is chat.
    func testAMailAppIsMail() {
        XCTAssertEqual(ChatApps.style(bundleIdentifier: "com.apple.mail",
                                      windowTitle: nil), .mail)
        XCTAssertEqual(ChatApps.style(bundleIdentifier: "com.microsoft.Outlook",
                                      windowTitle: nil), .mail)
    }

    /// A webmail tab is mail, read the same way a chat tab is read.
    func testAWebmailTabIsMail() {
        XCTAssertEqual(ChatApps.style(bundleIdentifier: "com.google.Chrome",
                                      windowTitle: "Inbox (3) - basal@example.com - Gmail"),
                       .mail)
        XCTAssertEqual(ChatApps.style(bundleIdentifier: "com.google.Chrome",
                                      windowTitle: "Outlook | Mail"), .mail)
    }

    /// Chat is decided before mail. A chat tab whose title happens to carry a mail word
    /// stays chat, which is why the order in `style` is not incidental.
    func testChatWinsOverMailWhenATitleCarriesBoth() {
        XCTAssertEqual(ChatApps.style(bundleIdentifier: "com.google.Chrome",
                                      windowTitle: "Slack | mail"), .chat)
    }

    /// A page merely named after a mail app is not mail, for the same reason
    /// "slack-notifier" is not Slack.
    func testAPageAboutMailIsNotMail() {
        XCTAssertNil(ChatApps.style(bundleIdentifier: "com.google.Chrome",
                                    windowTitle: "gmail-clone on GitHub"))
        XCTAssertNil(ChatApps.style(bundleIdentifier: "com.google.Chrome",
                                    windowTitle: "How mailmerge works"))
    }
}
