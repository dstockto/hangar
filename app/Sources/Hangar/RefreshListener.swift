import Foundation
import HangarCore

/// Answers `hangar refresh`. The command line cannot call AWS, so it asks here,
/// and this runs the same refresh the menu's Refresh item runs.
@MainActor
final class RefreshListener {
    private let store: FleetStore
    private var observer: NSObjectProtocol?
    private var queue = RefreshQueue()

    init(store: FleetStore) {
        self.store = store
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(RefreshSignal.request), object: nil,
            queue: .main) { [weak self] note in
            // Any process in the session can post this, so the id is checked
            // before it is echoed anywhere.
            guard let id = note.object as? String, RefreshSignal.isRequestID(id) else {
                return
            }
            Task { @MainActor in self?.receive(id) }
        }
    }

    private func receive(_ id: String) {
        let admission = queue.admit(id)
        guard admission != .dropped else { return }
        post(.started, to: id)
        // Already answering: this request rides on that refresh.
        guard admission == .startsAnswer else { return }
        Task { await answer() }
    }

    private func answer() async {
        Log.info(.fleet, "refresh requested from the command line")
        let failed: Bool
        if case .failed = store.status { failed = true } else { failed = false }
        if queue.startsFetch(isRefreshing: store.status == .refreshing,
                             fetchedAt: store.fetchedAt, lastFailed: failed, now: Date()) {
            await store.refresh()
        }
        // Covers a refresh the timer or the menu started, which this joins
        // rather than reporting before it lands.
        while store.status == .refreshing {
            try? await Task.sleep(for: .milliseconds(100))
        }
        var failure: String?
        if case .failed(let reason) = store.status { failure = reason.detail }
        let reply = RefreshQueue.reply(failure: failure, reports: store.sourceReports)
        for id in queue.release() { post(reply, to: id) }
    }

    private func post(_ reply: RefreshSignal.Reply, to id: String) {
        // Delivered at once whatever the receiver's suspension state, so an app
        // or a shell in the background still hears it.
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(RefreshSignal.reply), object: id,
            userInfo: RefreshSignal.userInfo(for: reply), deliverImmediately: true)
    }
}
