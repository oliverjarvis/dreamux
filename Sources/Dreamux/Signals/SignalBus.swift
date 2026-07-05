import Foundation
import Combine

/// App-wide hub every signal flows through. Producers call
/// `SignalBus.shared.emit(_:)`; the bus persists to SQLite and
/// republishes to in-process subscribers (project sessions surfacing
/// external emits, the emit-socket's subscribe streams).
///
/// Single global because there is one ledger per app instance; the
/// per-project scoping lives in the `project_dir` tag, not in separate
/// stores.
final class SignalBus: @unchecked Sendable {
    static let shared = SignalBus()

    /// nil when SQLite failed to open — the app keeps running, the live
    /// stream just won't retain history across launches.
    let store: SQLiteSignalStore?

    /// Combine fan-out. Sent on whatever thread `emit` was called from;
    /// subscribers hop schedulers as appropriate.
    let publisher: AnyPublisher<Signal, Never>
    private let subject = PassthroughSubject<Signal, Never>()
    private var socketServer: SignalEmitSocketServer?

    private convenience init() {
        let resolved: SQLiteSignalStore?
        do {
            let sqlite = try SQLiteSignalStore(dbURL: SQLiteSignalStore.defaultURL())
            sqlite.startPeriodicTrim()
            resolved = sqlite
        } catch {
            NSLog("SignalBus: persistence unavailable — %@", String(describing: error))
            resolved = nil
        }
        self.init(store: resolved, startSocket: true)
    }

    /// Test seam: inject a temp-path store (or nil) and skip the real
    /// socket. Production goes through `shared` only.
    init(store: SQLiteSignalStore?, startSocket: Bool) {
        self.store = store
        self.publisher = subject.eraseToAnyPublisher()
        if startSocket {
            let server = SignalEmitSocketServer(bus: self)
            self.socketServer = server
            DispatchQueue.global(qos: .utility).async {
                server.start(path: SignalEmitSocketServer.defaultSocketPath())
            }
        }
    }

    /// Test-only: attach a server on a custom path (temp dir sockets).
    func attachSocketServer(path: String) -> SignalEmitSocketServer {
        let server = SignalEmitSocketServer(bus: self)
        socketServer = server
        server.start(path: path)
        return server
    }

    /// Fan out a signal to disk and to subscribers. Safe from any thread.
    func emit(_ signal: Signal) {
        store?.append(signal)
        subject.send(signal)
    }
}
