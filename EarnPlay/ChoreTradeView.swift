import EarnPlayCore
import Foundation
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
    var theme: DesignSystem.Theme = DesignSystem.defaultTheme
    @StateObject private var viewModel: ChoreTradeViewModel
    /// Unlock-status ticker: fires while this view is rendered (via
    /// `onReceive` on the outer container), driving the view model's
    /// periodic status refresh independently of the chore session's phase
    /// (fix round 5). The granted countdown and the restored-window
    /// banner both refresh from this single subscription.
    private let statusTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(theme: DesignSystem.Theme = DesignSystem.defaultTheme) {
        self.theme = theme
        let policyStore = PolicyStore()
        // Demo mode is the ABSENCE of a parent-authored policy (fix round
        // 3): a cached parent policy with an EMPTY pool is respected
        // (no offers, real policy path), never replaced by the demo seed.
        let resolution = ChoreTradePoolSource.resolve(
            policy: policyStore.currentPolicy)
        let pool = resolution.pool
        let caption = resolution.poolSourceCaption
        // Configured policy/enumeration pair (fix round 2): the grant
        // path only unlocks enumerated challenge-unlockable apps, so
        // `.empty` enumeration could never grant. Demo mode (no sync)
        // uses an isolated fixture store, leaving the real cache and
        // the default-deny policy untouched; a synced policy derives
        // its enumeration from its own app lists.
        let manager: ShieldManager
        if resolution.isDemo {
            let demoDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("EarnPlayChoreTradeDemo", isDirectory: true)
            let demoStore = PolicyStore(directory: demoDirectory)
            _ = demoStore.apply(ChoreTradeDemoShield.demoPolicy(chorePool: pool))
            manager = ShieldManager(
                policyStore: demoStore,
                enumeration: ChoreTradeDemoShield.demoEnumeration(),
                backend: DemoShieldBackend(),
                unlockStore: FileUnlockWindowStore(directory: demoDirectory)
            )
        } else {
            manager = ShieldManager(
                policyStore: policyStore,
                enumeration: ChoreTradeDemoShield.enumeration(
                    for: policyStore.currentPolicy),
                backend: DemoShieldBackend(),
                unlockStore: FileUnlockWindowStore()
            )
        }
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
        // Every label below pairs with the fixed light card
        // background (adaptive text would wash out in Dark Mode);
        // the style stays on the labels so the default-style buttons
        // keep their native colors.
        VStack(alignment: .leading, spacing: 12) {
            Text("Chore trade")
                .font(.headline)
                .foregroundStyle(theme.tokens.tutorText.color)
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
                    .onAppear { viewModel.startStatusUpdates() }
                    .onDisappear { viewModel.stopStatusUpdates() }
            }
            // Restored-window status (fix round 5): a same-boot relaunch
            // during an active unlock restores the window but starts a
            // fresh session that never reaches `.granted`. The countdown
            // and expiry message live in `shieldStatus`, so render them
            // here whenever non-empty outside the granted screen — the
            // status is independent of the chore session's phase.
            if !viewModel.shieldStatus.isEmpty && !viewModel.session.hasGrantedUnlock {
                Text(viewModel.shieldStatus)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryOnTheme)
                    .accessibilityIdentifier("restoredUnlockStatus")
            }
            Text(viewModel.poolSourceCaption)
                .font(.caption)
                .foregroundStyle(theme.secondaryOnTheme)
        }
        .padding()
        .background(theme.tokens.tutorBackground.color)
        .cornerRadius(theme.cardRadius)
        .onReceive(statusTicker) { _ in
            if !viewModel.shieldStatus.isEmpty || viewModel.session.hasGrantedUnlock {
                viewModel.refreshGrantedStatus()
            }
        }
    }

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.declinedCount > 0 {
                Text("Practice resumes. \(viewModel.declinedCount) chore\(viewModel.declinedCount == 1 ? "" : "s") declined this session — won't be offered again.")
                    .font(.subheadline)
                    .foregroundStyle(theme.tokens.tutorText.color)
            } else {
                Text("Practice placeholder — a chore trade can be offered mid-session.")
                    .font(.subheadline)
                    .foregroundStyle(theme.tokens.tutorText.color)
            }
            if viewModel.lastTriggerFoundNone {
                Text("No chores available right now.")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryOnTheme)
            }
            Button("Take a chore break") { viewModel.triggerOffer() }
                .accessibilityIdentifier("triggerOfferButton")
        }
    }

    private func offerView(_ offer: ChoreTradeOffer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your AI suggests one chore:")
                .font(.subheadline)
                .foregroundStyle(theme.tokens.tutorText.color)
            Text(offer.entry.chore)
                .font(.title3.bold())
                .foregroundStyle(theme.tokens.tutorText.color)
                .accessibilityIdentifier("offerChoreText")
            Text("Earns \(offer.entry.unlockMinutes) minutes when your parent confirms.")
                .font(.subheadline)
                .foregroundStyle(theme.tokens.tutorText.color)
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
                .foregroundStyle(theme.tokens.tutorText.color)
            Text("Do the chore, then tap Done.")
                .font(.subheadline)
                .foregroundStyle(theme.tokens.tutorText.color)
            Button("Done") { viewModel.markDone() }
                .accessibilityIdentifier("doneButton")
        }
    }

    private func awaitingConfirmView(_ offer: ChoreTradeOffer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Waiting for parent…")
                .font(.subheadline.bold())
                .foregroundStyle(theme.tokens.tutorText.color)
            Text("Done: \(offer.entry.chore). No unlock yet — your parent must confirm in person.")
                .font(.subheadline)
                .foregroundStyle(theme.tokens.tutorText.color)
            // Grant failure feedback (fix round 3): a failed grant leaves
            // the session here, so the failure must show here — otherwise
            // Confirm appears to do nothing. The button stays tappable:
            // the same tap retries the grant.
            if let failure = viewModel.confirmationFailureText {
                Text(failure)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("grantFailureText")
            }
            Button("Parent: Confirm completion") { viewModel.parentConfirm() }
                .accessibilityIdentifier("parentConfirmButton")
        }
    }

    private func grantedView(_ record: ChoreTradeRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Unlock granted: \(record.grantedUnlockMinutes) minutes for \"\(record.chore)\".")
                .font(.subheadline.bold())
                .foregroundStyle(theme.tokens.tutorText.color)
                .accessibilityIdentifier("grantedText")
            Text(viewModel.shieldStatus)
                .font(.caption)
                .foregroundStyle(theme.secondaryOnTheme)
        }
    }
}
