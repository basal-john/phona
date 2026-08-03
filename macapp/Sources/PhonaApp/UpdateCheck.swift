import AppKit
import Foundation

/// Tells the user when a newer release exists. It never installs anything.
///
/// Phona is signed ad-hoc rather than with a Developer ID, so a real auto-updater would
/// need a signed appcast and a notarised build to be trustworthy. Without that, silently
/// replacing a binary that holds Accessibility access is the wrong trade. This checks the
/// public releases feed, and if something newer is out, says so and gets out of the way.
enum UpdateCheck {
    static let releasesAPI = URL(string: "https://api.github.com/repos/basal-john/phona/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/basal-john/phona/releases/latest")!

    private(set) static var availableVersion: String?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Check quietly in the background. Failure is not worth telling the user about.
    static func check(completion: @escaping (String?) -> Void = { _ in }) {
        var request = URLRequest(url: releasesAPI)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String
            else {
                completion(nil)
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let newer = isNewer(latest, than: currentVersion) ? latest : nil
            DispatchQueue.main.async {
                availableVersion = newer
                completion(newer)
            }
        }.resume()
    }

    /// Numeric component comparison, so 1.10.0 beats 1.9.0 where a string compare would not.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let b = current.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    static func openReleasesPage() {
        NSWorkspace.shared.open(releasesPage)
    }
}
