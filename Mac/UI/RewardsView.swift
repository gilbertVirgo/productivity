import SwiftUI
import SwiftData
import Core

struct RewardsView: View {
    @Environment(\.modelContext) private var ctx
    @Query(filter: #Predicate<Treat> { $0.archivedAt == nil }, sort: \Treat.cost) private var treats: [Treat]
    @Query(sort: \PointEvent.at, order: .reverse) private var events: [PointEvent]
    @State private var addSheet = false
    @State private var pending: Treat?
    @State private var errorText: String?

    private var balance: Int { Ledger.balance(ctx) }
    private var todayStart: Date { PeriodCalendar(timeZone: .current).dayInterval(containing: .now).start }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading) {
                    Text("\(balance)").font(.system(size: 56, weight: .bold).monospacedDigit())
                    Text("points").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Your treats").font(.title3.bold())
                        Spacer()
                        Button("Add treat") { addSheet = true }
                    }
                    if treats.isEmpty { Text("No treats yet.").foregroundStyle(.secondary) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                        ForEach(treats) { t in
                            GroupBox {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(t.name).font(.headline)
                                    Text("\(t.cost) points").foregroundStyle(.secondary)
                                    Button("Redeem") { pending = t }.disabled(!canRedeem(cost: t.cost, balance: balance))
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                            }
                        }
                    }
                }
                pointsTable
                ledger("Today", events.filter { $0.at >= todayStart })
                ledger("Recently", Array(events.prefix(20)))
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $addSheet) { AddTreatSheet { addSheet = false } }
        .confirmationDialog(pending.map { "Redeem \($0.name) for \($0.cost) points?" } ?? "", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { t in
            Button("Redeem") { redeem(t) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Can't redeem", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") {}
        } message: { Text(errorText ?? "") }
    }

    private func redeem(_ t: Treat) {
        do { try Ledger.redeem(ctx, treat: t, at: .now) }
        catch LedgerError.insufficientPoints { errorText = "You don't have enough points for \(t.name)." }
        catch { errorText = "Couldn't save the redemption." }
    }

    private var pointsTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How points work").font(.title3.bold())
            row("Each focused minute", PointRules.perFocusedMinute)
            row("Session completed", PointRules.sessionComplete)
            row("Daily goal met", PointRules.dailyGoalMet)
            row("Weekly goal met", PointRules.weeklyGoalMet)
            row("Each off-task minute", PointRules.perOfftaskMinute)
            row("Each minute over the break allowance", PointRules.perOverBreakMinute)
        }.frame(maxWidth: 420)
    }

    private func row(_ label: String, _ v: Int) -> some View {
        HStack { Text(label); Spacer(); delta(v) }
    }

    private func delta(_ v: Int) -> some View {
        Text(v > 0 ? "+\(v)" : "\(v)").monospacedDigit().foregroundStyle(v < 0 ? Theme.warn : .primary)
    }

    private func ledger(_ title: String, _ rows: [PointEvent]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3.bold())
            if rows.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
            ForEach(rows) { e in
                HStack {
                    Text(kindLabel(e.kind)); Text(e.note).foregroundStyle(.secondary)
                    Spacer()
                    Text(e.at, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    delta(e.delta).frame(width: 60, alignment: .trailing)
                }
            }
        }.frame(maxWidth: 520)
    }

    private func kindLabel(_ raw: String) -> String {
        switch PointKind(rawValue: raw) {
        case .focus: "Focus"
        case .offtask: "Off task"
        case .redeem: "Redeemed"
        case .sessionComplete: "Session complete"
        case .dailyGoal: "Daily goal"
        case .weeklyGoal: "Weekly goal"
        case .breakOver: "Over break"
        case nil: raw
        }
    }
}

private struct AddTreatSheet: View {
    @Environment(\.modelContext) private var ctx
    let done: () -> Void
    @State private var name = ""
    @State private var cost = ""

    private var parsed: GoalInput { GoalInput.parse(cost, wholeNumber: true) }
    private var valid: Bool { if case .value = parsed, !name.trimmingCharacters(in: .whitespaces).isEmpty { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a treat").font(.headline)
            TextField("Name", text: $name)
            TextField("Cost in points", text: $cost)
            if case let .invalid(msg) = parsed { Text(msg).font(.caption).foregroundStyle(Theme.warn) }
            HStack {
                Spacer()
                Button("Cancel", action: done)
                Button("Add") {
                    if case let .value(v) = parsed {
                        ctx.insert(Treat(name: name.trimmingCharacters(in: .whitespaces), cost: Int(v)))
                        ctx.saveLogged()
                        done()
                    }
                }.buttonStyle(.borderedProminent).disabled(!valid)
            }
        }.textFieldStyle(.roundedBorder).padding(20).frame(width: 320)
    }
}
