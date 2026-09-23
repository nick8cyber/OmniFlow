import Foundation
import Network

final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.nick8cyber.omniflow.network-monitor")
    private let lock = NSLock()
    private var started = false
    private var _isOnline = true

    private init() {}

    var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isOnline
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            self.lock.lock()
            self._isOnline = path.status == .satisfied
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }
}
