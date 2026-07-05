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

    /// Combine fan-out. Values are always delivered on `emitQueue`
    /// (the bus's private serial queue); subscribers hop schedulers as
    /// appropriate (ProjectSession does `.receive(on: .main)`).
    let publisher: AnyPublisher<Signal, Never>
    private let subject = PassthroughSubject<Signal, Never>()
    /// Serializes emission. `emit` is called concurrently — from the
    /// main actor (app producers) and from the socket server's
    /// concurrent work queue (external emits) — but
    /// `PassthroughSubject.send` requires serialized calls, so every
    /// emit hops onto this queue before touching the subject.
    private let emitQueue = DispatchQueue(label: "dreamux.signals.bus")
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

    /// Fan out a signal to disk and to subscribers. Safe to call from
    /// any thread BECAUSE the append + publish are funneled through the
    /// bus's private serial queue — concurrent `subject.send` calls are
    /// undefined behavior, so the queue is what makes this claim true.
    /// Consequently subscribers receive values on that queue, never on
    /// the emitter's thread.
    func emit(_ signal: Signal) {
        emitQueue.async { [store, subject] in
            store?.append(signal)
            subject.send(signal)
        }
    }
}
