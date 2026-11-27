import SwiftUI
import SwiftData
import StintData

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

extension Project {
    /// Menu bar / chip name: the short name, else the name cut to 12 characters.
    var menuTitle: String {
        if let s = shortName?.trimmingCharacters(in: .whitespaces), !s.isEmpty { return s }
        return name.count > 12 ? String(name.prefix(11)) + "…" : name
    }

    /// A new project with the next default colour and share alias. The caller saves.
    static func makeNew(in ctx: ModelContext, now: Date = .now) -> Project {
        let total = (try? ctx.fetchCount(FetchDescriptor<Project>())) ?? 0
        let p = Project(name: "Untitled", shareAlias: "Project \(total + 1)", colorHex: ProjectColor.all[total % ProjectColor.all.count], now: now)
        ctx.insert(p)
        return p
    }
}

/// A card's project: icon (or initials) and short name on a tint of the project colour.
struct ProjectChip: View {
    let project: Project?
    var size: CGFloat = 18
    var body: some View {
        HStack(spacing: 5) {
            ProjectIcon(name: project?.name ?? "?", colorHex: project?.colorHex ?? "#8E8E93", icon: project?.icon, size: size)
            Text(project?.menuTitle ?? "No project").font(.caption.weight(.semibold)).lineLimit(1)
        }
        .padding(.leading, 2).padding(.trailing, 8).padding(.vertical, 2)
        .background(Color(hex: project?.colorHex ?? "#8E8E93").opacity(0.16), in: Capsule())
    }
}
