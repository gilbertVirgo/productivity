import SwiftUI

enum ProjectSymbols {
    /// Spec 2026-11-26 §6.4.
    static let all = ["building.columns", "briefcase", "book", "hammer", "paintbrush", "laptopcomputer", "music.note", "cross",
                      "house", "graduationcap", "camera", "chart.bar", "doc.text", "envelope", "globe", "heart", "leaf",
                      "lightbulb", "megaphone", "person.2", "star", "terminal", "timer", "wrench"]
}

struct IconPicker: View {
    @Binding var selection: String?
    let colorHex: String

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 9), alignment: .leading, spacing: 6) {
            cell(nil)
            ForEach(ProjectSymbols.all, id: \.self) { cell($0) }
        }
    }

    private func cell(_ name: String?) -> some View {
        Button { selection = name } label: {
            Group {
                if let name { Image(systemName: name) } else { Text("Aa").font(.caption.bold()) }
            }
            .frame(width: 30, height: 30)
            .foregroundStyle(selection == name ? .white : .primary)
            .background(selection == name ? Color(hex: colorHex) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name ?? "Initials")
    }
}
