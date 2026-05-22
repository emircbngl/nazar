import Foundation

/// Lock-protected progress holder. The cleanup pipeline writes; a main-thread
/// heartbeat reads. Decouples worker speed from UI repaints.
final class StatusBox {
    struct Snapshot { let percent: Double; let label: String }

    private let lock = NSLock()
    private var percent: Double = 0
    private var label: String = ""

    func update(percent: Double, label: String) {
        lock.lock()
        self.percent = percent
        self.label = label
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(percent: percent, label: label)
    }
}

/// Drives a fake-but-smooth percent ramp during opaque, blocking work like
/// `softwareupdate -l`. Caps at `maxPct` so the real completion can take it
/// the rest of the way.
final class ProgressHeartbeat {
    private let maxPct: Double
    private let onTick: (Double) -> Void
    private var timer: DispatchSourceTimer?
    private var current: Double = 0

    init(maxPct: Double, onTick: @escaping (Double) -> Void) {
        self.maxPct = maxPct
        self.onTick = onTick
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: 0.4)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Asymptotic ramp — fast at the start, slows down toward maxPct
            self.current += (self.maxPct - self.current) * 0.08
            self.onTick(self.current)
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Safety net: if a caller forgets stop() (e.g. early return from a step),
    /// the timer is cancelled when this object goes out of scope rather than
    /// leaking onto a global queue.
    deinit { timer?.cancel() }
}
