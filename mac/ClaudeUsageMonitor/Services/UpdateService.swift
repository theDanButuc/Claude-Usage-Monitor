import Foundation

final class UpdateService {
    static let shared = UpdateService()
    private init() {}

    private let repoAPI = "https://api.github.com/repos/theDanButuc/Claude-Usage-Monitor/releases/latest"
    private let releasePage = "https://github.com/theDanButuc/Claude-Usage-Monitor/releases/latest"

    /// URL to open when the user taps "View Release"
    var releaseURL: URL { URL(string: releasePage)! }

    /// Checks GitHub for a newer release.
    /// Calls `completion` on the main queue with the latest version string if an
    /// update is available, or `nil` if already up to date / check failed.
    func checkForUpdates(completion: @escaping (String?) -> Void) {
        guard let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            completion(nil)
            return
        }

        var request = URLRequest(url: URL(string: repoAPI)!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard
                let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tag  = json["tag_name"] as? String
            else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let isNewer = latest.compare(currentVersion, options: .numeric) == .orderedDescending

            DispatchQueue.main.async {
                completion(isNewer ? latest : nil)
            }
        }.resume()
    }
}
