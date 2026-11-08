import Foundation
import Network
import Observation

/// Windows アプリが mDNS で広告する _castmic._tcp を探す
@MainActor
@Observable
final class Discovery {
    struct Host: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    private(set) var hosts: [Host] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_castmic._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results.compactMap { r -> Host? in
                guard case .service(let name, _, _, _) = r.endpoint else { return nil }
                return Host(name: name, endpoint: r.endpoint)
            }.sorted { $0.name < $1.name }
            Task { @MainActor in self?.hosts = hosts }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
