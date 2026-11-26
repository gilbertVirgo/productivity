import SwiftUI

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt64(s, radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

enum Theme {
    static let accent = Color(hex: "#0064D2")
    static let warn = Color(hex: "#A84F00")
}

enum ProjectColor {
    // teal, amber, purple, blue, rose
    static let all = ["#0F7B6C", "#B7671F", "#6E56CF", "#2F6FB5", "#B5476A"]
}

func remainingText(_ sec: Int) -> String {
    let s = max(0, sec)
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// "3.5" (hours, one decimal) from seconds.
func hours(_ sec: Int) -> String { String(format: "%.1f", Double(sec) / 3600) }

/// "1:42": hours and minutes, for time-on-project labels.
func hoursMinutes(_ sec: Int) -> String { String(format: "%d:%02d", max(0, sec) / 3600, max(0, sec) / 60 % 60) }
