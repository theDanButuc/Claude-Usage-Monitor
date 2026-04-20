import Foundation

enum UpdateState: Equatable {
    case none
    case available(version: String, downloadURL: URL)
    case downloading(progress: Double)
    case ready(localURL: URL)
}

final class UpdateService: ObservableObject {
    static let shared = UpdateService()
    private init() {}

    private let repoAPI = "https://api.github.com/repos/theDanButuc/Claude-Usage-Monitor/releases/latest"

    @Published var updateState: UpdateState = .none

    func checkForUpdates() {
        guard let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return }

        var request = URLRequest(url: URL(string: repoAPI)!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard
                let self,
                let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tag  = json["tag_name"] as? String
            else { return }

            let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            guard latest.compare(currentVersion, options: .numeric) == .orderedDescending else { return }

            let downloadURL: URL? = (json["assets"] as? [[String: Any]])?.first
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap { URL(string: $0) }

            DispatchQueue.main.async {
                switch self.updateState {
                case .downloading, .ready:
                    break // don't interrupt an in-progress download
                default:
                    if let url = downloadURL {
                        self.updateState = .available(version: latest, downloadURL: url)
                    }
                }
            }
        }.resume()
    }

    func downloadUpdate(from url: URL) {
        guard case .available(let version, _) = updateState else { return }
        updateState = .downloading(progress: 0)

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            guard let self else { return }
            if let error = error {
                NSLog("[UpdateService] Download failed: %@", error.localizedDescription)
                DispatchQueue.main.async {
                    self.updateState = .available(version: version, downloadURL: url)
                }
                return
            }
            guard let tempURL else { return }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClaudeUsageMonitor-\(version).dmg")
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: tempURL, to: dest)
                DispatchQueue.main.async { self.updateState = .ready(localURL: dest) }
            } catch {
                NSLog("[UpdateService] Move failed: %@", error.localizedDescription)
                DispatchQueue.main.async { self.updateState = .available(version: version, downloadURL: url) }
            }
        }

        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async { self?.updateState = .downloading(progress: progress.fractionCompleted) }
        }
        objc_setAssociatedObject(task, "progressObs", observation, .OBJC_ASSOCIATION_RETAIN)

        task.resume()
    }
}
