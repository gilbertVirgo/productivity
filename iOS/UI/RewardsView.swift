import SwiftUI
import SwiftData
import Core
import StintData

/// Rewards part of the Progress sheet: balance and treats to redeem.
struct RewardsSections: View {
    @Environment(PhoneSync.self) private var sync
    @Environment(\.modelContext) private var ctx
    @Query private var events: [PointEvent]
    @Query(filter: #Predicate<Treat> { $0.archivedAt == nil }, sort: \Treat.cost) private var treats: [Treat]
    @State private var pending: Treat?
    @State private var redeemError: String?

    var body: some View {
        let balance = events.reduce(0) { $0 + $1.delta }
        Group {
                Section("Rewards") {
                    LabeledContent("Balance", value: "\(balance)")
                    LabeledContent("Today", value: "\(sync.snapshot?.pointsToday ?? 0)")
                }
                if let e = redeemError { Section { Text(e).foregroundStyle(Theme.warn) } }
                Section("Treats") {
                    if treats.isEmpty { Text("Add treats on your Mac.").foregroundStyle(.secondary) }
                    ForEach(treats) { t in
                        HStack {
                            Text(t.name)
                            Spacer()
                            Button("\(t.cost) pts") { pending = t }
                                .buttonStyle(.bordered)
                                .disabled(!canRedeem(cost: t.cost, balance: balance))
                        }
                    }
                }
            }
            .confirmationDialog("Redeem \(pending?.name ?? "")?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                                titleVisibility: .visible, presenting: pending) { t in
                Button("Redeem for \(t.cost) points") {
                    do { try Ledger.redeem(ctx, treat: t, at: .now); redeemError = nil; sync.syncSoon() }
                    catch {
                        PhoneSync.log.error("redeem: \(error.localizedDescription, privacy: .public)")
                        redeemError = (error as? LedgerError) == .insufficientPoints ? "Not enough points" : "Couldn't redeem: \(error.localizedDescription)"
                    }
                }
            }
    }
}
