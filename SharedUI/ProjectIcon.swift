import SwiftUI

/// "Christian Heritage" → "CH". Used when a project has no icon.
func initials(_ name: String) -> String {
    String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
}

/// A project's SF Symbol (or initials) on its colour (spec 2026-11-26 §6.4).
struct ProjectIcon: View {
    let name: String
    let colorHex: String
    let icon: String?
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25)
            .fill(Color(hex: colorHex))
            .frame(width: size, height: size)
            .overlay {
                if let icon {
                    Image(systemName: icon).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
                } else {
                    Text(initials(name)).font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(.white)
                }
            }
            .accessibilityHidden(true)
    }
}
