import EarnPlayCore
import SwiftUI

/// Single-chore offer UI (T3.2).
///
/// Shows exactly one chore at a time — offer card, accept/decline,
/// Done button, then in-person parent confirm granting the unlock.
/// There is deliberately no chore menu or list anywhere in this view:
/// the session surfaces one `currentOffer`, and declined chores are
/// reported as a count only, never named or iterated.
///
/// The "Take a chore break" trigger is the demo stand-in for offer
/// timing. T3.3 owns the real offer-choice logic (when to offer,
/// movement vs chore, weekly caps) and will replace this button.
struct ChoreTradeView: View {
    @StateObject private var viewModel: ChoreTradeViewModel

    init() {
        let policyStore = PolicyStore()
        let policyPool = policyStore.currentPolicy.chorePool
        // Demo seed only when the policy pool is empty (no sync in the
        // demo); a synced parent-stocked pool always wins.
        let pool = policyPool.isEmpty ? DemoChorePool.seeded() : policyPool
        let caption = policyPool.isEmpty
            ? "Demo chores"
            : "Parent's chores (policy v\(policyStore.currentPolicy.version))"
        let manager = ShieldManager(
            policyStore: policyStore,
            enumeration: .empty,
            backend: DemoShieldBackend(),
            unlockStore: FileUnlockWindowStore()
        )
        // No live practice session in this placeholder host: the chat
        // view (T1.8) will inject its EffortSessionRecorder so trade
        // taps count as session interactions.
        _viewModel = StateObject(wrappedValue: ChoreTradeViewModel(
            pool: pool,
            poolSourceCaption: caption,
            shieldManager: manager,
            effortRecorder: nil
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chore trade")
                .font(.headline)
            switch viewModel.session.phase {
            case .idle:
                idleView
            case .offered(let offer):
                offerView(offer)
            case .accepted(let offer, _):
                acceptedView(offer)
            case .doneAwaitingConfirm(let offer, _, _):
                awaitingConfirmView(offer)
            case .granted(let record):
                grantedView(record)
            }
            Text(viewModel.poolSourceCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.declinedCount > 0 {
                Text("Practice resumes. \(viewModel.declinedCount) chore\(viewModel.declinedCount == 1 ? "" : "s") declined this session — won't be offered again.")
                    .font(.subheadline)
            } else {
                Text("Practice placeholder — a chore trade can be offered mid-session.")
                    .font(.subheadline)
            }
            if viewModel.lastTriggerFoundNone {
                Text("No chores available right now.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button("Take a chore break") { viewModel.triggerOffer() }
                .accessibilityIdentifier("triggerOfferButton")
        }
    }

    private func offerView(_ offer: ChoreTradeOffer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your AI suggests one chore:")
                .font(.subheadline)
            Text(offer.entry.chore)
                .font(.title3.bold())
                .accessibilityIdentifier("offerChoreText")
            Text("Earns \(offer.entry.unlockMinutes) minutes when your parent confirms.")
                .font(.subheadline)
                .accessibilityIdentifier("offerUnlockMinutes")
            HStack {
                Button("Accept") { viewModel.accept() }
                    .accessibilityIdentifier("acceptButton")
                Button("Decline") { viewModel.decline() }
                    .accessibilityIdentifier("declineButton")
            }
        }
        .accessibilityIdentifier("offerCard")
    }

    private func acceptedView(_ offer: ChoreTradeOffer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accepted: \(offer.entry.chore)")
                .font(.subheadline.bold())
            Text("Do the chore, then tap Done.")
                .font(.subheadline)
            Button("Done") { viewModel.markDone() }
                .accessibilityIdentifier("doneButton")
        }
    }

    private func awaitingConfirmView(_ offer: ChoreTradeOffer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Waiting for parent…")
                .font(.subheadline.bold())
            Text("Done: \(offer.entry.chore). No unlock yet — your parent must confirm in person.")
                .font(.subheadline)
            Button("Parent: Confirm completion") { viewModel.parentConfirm() }
                .accessibilityIdentifier("parentConfirmButton")
        }
    }

    private func grantedView(_ record: ChoreTradeRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Unlock granted: \(record.grantedUnlockMinutes) minutes for \"\(record.chore)\".")
                .font(.subheadline.bold())
                .accessibilityIdentifier("grantedText")
            Text(viewModel.shieldStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// View model behind `ChoreTradeView`: owns the `ChoreTradeSession`
/// state machine and calls `ShieldManager` exactly once, on parent
/// confirm. Done never touches the shield manager.
@MainActor
final class ChoreTradeViewModel: ObservableObject {
    @Published private(set) var session: ChoreTradeSession
    @Published private(set) var lastTriggerFoundNone = false
    @Published private(set) var shieldStatus = ""
    @Published private(set) var grantSucceeded: Bool?
    let poolSourceCaption: String

    private let shieldManager: ShieldManager
    private let effortRecorder: EffortSessionRecorder?

    init(
        pool: [ChorePoolEntry],
        poolSourceCaption: String,
        shieldManager: ShieldManager,
        effortRecorder: EffortSessionRecorder? = nil
    ) {
        self.session = ChoreTradeSession(pool: pool)
        self.poolSourceCaption = poolSourceCaption
        self.shieldManager = shieldManager
        self.effortRecorder = effortRecorder
    }

    var declinedCount: Int { session.declinedChores.count }

    func triggerOffer() {
        let offer = session.makeOffer(at: Date())
        lastTriggerFoundNone = (offer == nil && session.currentOffer == nil && !session.hasGrantedUnlock)
        effortRecorder?.recordInteraction()
    }

    func accept() {
        session.acceptOffer(at: Date())
        effortRecorder?.recordInteraction()
    }

    func decline() {
        session.declineOffer()
        effortRecorder?.recordInteraction()
    }

    func markDone() {
        session.markDone(at: Date())
        effortRecorder?.recordInteraction()
    }

    func parentConfirm() {
        guard let record = session.parentConfirm(at: Date()) else { return }
        let ok = shieldManager.grantChoreTradeUnlock(minutes: record.grantedUnlockMinutes)
        grantSucceeded = ok
        effortRecorder?.recordInteraction()
        refreshShieldStatus()
    }

    private func refreshShieldStatus() {
        if shieldManager.isUnlockActive {
            let remaining = Int(shieldManager.remainingUnlockTime.rounded(.down))
            shieldStatus = "Device unlock active, \(remaining) seconds left."
        } else if grantSucceeded == false {
            shieldStatus = "Device shields unchanged (no unblockable apps in the demo policy)."
        } else {
            shieldStatus = ""
        }
    }
}
