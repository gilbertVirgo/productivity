import Foundation
import Testing
@testable import Core

@Suite struct SwitchSuggesterTests {
    let a = UUID(), b = UUID()
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    var projects: [SwitchSuggester.Candidate] {
        [.init(id: a, allowlist: Allowlist(entries: [AllowEntry(.app, "com.apple.Safari"), AllowEntry(.app, "com.microsoft.VSCode"),
                                                       AllowEntry(.app, "com.anthropic.claude")], ownBundleID: "dev.stint.mac")),
         .init(id: b, allowlist: Allowlist(entries: [AllowEntry(.domain, "figma.com"), AllowEntry(.app, "com.anthropic.claude")],
                                           ownBundleID: "dev.stint.mac"))]
    }

    @Test func suggestsTheSingleOwnerAfterDwellOnce() {
        var s = SwitchSuggester()
        #expect(s.observe(bundleID: "com.apple.Safari", host: "www.figma.com", current: a, projects: projects, at: t0) == nil)
        #expect(s.tick(at: t0 + 9) == nil)
        let got = s.tick(at: t0 + 10)
        #expect(got?.projectID == b)
        #expect(got?.since == t0)
        #expect(s.tick(at: t0 + 30) == nil)
    }

    @Test func aGlanceShorterThanDwellIsForgotten() {
        var s = SwitchSuggester()
        _ = s.observe(bundleID: "com.apple.Safari", host: "figma.com", current: a, projects: projects, at: t0)
        _ = s.observe(bundleID: "com.microsoft.VSCode", host: nil, current: a, projects: projects, at: t0 + 5)
        #expect(s.tick(at: t0 + 20) == nil)
        #expect(s.pending == nil)
    }

    @Test func aSharedAppIsSilent() {
        var s = SwitchSuggester()
        _ = s.observe(bundleID: "com.anthropic.claude", host: nil, current: a, projects: projects, at: t0)
        #expect(s.tick(at: t0 + 60) == nil)
    }

    @Test func theCurrentProjectsOwnAppIsSilent() {
        var s = SwitchSuggester()
        _ = s.observe(bundleID: "com.apple.Safari", host: "figma.com", current: b, projects: projects, at: t0)
        #expect(s.tick(at: t0 + 60) == nil)
    }

    @Test func aDomainMatchBeatsAnAppMatch() {
        #expect(SwitchSuggester.owners(bundleID: "com.apple.Safari", host: "www.figma.com", among: projects) == [b])
        #expect(SwitchSuggester.owners(bundleID: "com.apple.Safari", host: "github.com", among: projects) == [a])
        #expect(SwitchSuggester.owners(bundleID: "com.apple.Safari", host: nil, among: projects) == [a])
    }

    @Test func alwaysAllowedAndUnlistedAppsHaveNoOwner() {
        #expect(SwitchSuggester.owners(bundleID: "dev.stint.mac", host: nil, among: projects).isEmpty)
        #expect(SwitchSuggester.owners(bundleID: "com.apple.loginwindow", host: nil, among: projects).isEmpty)
        #expect(SwitchSuggester.owners(bundleID: "com.spotify.client", host: nil, among: projects).isEmpty)
    }

    @Test func stayMutesThatSiteUntilReset() throws {
        var s = SwitchSuggester()
        _ = s.observe(bundleID: "com.apple.Safari", host: "figma.com", current: a, projects: projects, at: t0)
        let due = s.tick(at: t0 + 10)
        let got = try #require(due)
        s.mute(got)
        _ = s.observe(bundleID: "com.microsoft.VSCode", host: nil, current: a, projects: projects, at: t0 + 20)
        _ = s.observe(bundleID: "com.apple.Safari", host: "figma.com", current: a, projects: projects, at: t0 + 30)
        #expect(s.tick(at: t0 + 60) == nil)
        s.reset()
        _ = s.observe(bundleID: "com.apple.Safari", host: "figma.com", current: a, projects: projects, at: t0 + 70)
        #expect(s.tick(at: t0 + 80)?.projectID == b)
    }
}
