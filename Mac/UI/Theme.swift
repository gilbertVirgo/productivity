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
    static let all = ["#0F7B6C", "#D9730D", "#6940A5", "#0B6E99", "#AD1A72"]
}
