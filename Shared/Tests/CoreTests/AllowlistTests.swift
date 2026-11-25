import Testing
@testable import Core

@Suite struct AllowlistTests {
    let own = "dev.focus.mac"
    func list(_ entries: [AllowEntry]) -> Allowlist { Allowlist(entries: entries, ownBundleID: own) }

    @Test func listedAppIsOnTask() {
        #expect(list([AllowEntry(.app, "com.figma.Desktop")]).isOnTask(bundleID: "com.figma.Desktop", host: nil))
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(list([AllowEntry(.app, "com.figma.desktop")]).isOnTask(bundleID: "COM.FIGMA.DESKTOP", host: nil))
    }

    @Test func unlistedAppIsOffTask() {
        #expect(!list([AllowEntry(.app, "com.figma.Desktop")]).isOnTask(bundleID: "com.spotify.client", host: nil))
    }

    @Test func ownAppAndSystemAreAlwaysOnTask() {
        let l = list([])
        #expect(l.isOnTask(bundleID: own, host: nil))
        #expect(l.isOnTask(bundleID: "com.apple.loginwindow", host: nil))
        #expect(l.isOnTask(bundleID: "com.apple.ScreenSaver.Engine", host: nil))
    }

    @Test func extraAllowedIsOnTask() {
        let l = Allowlist(entries: [], ownBundleID: own, extraAllowed: ["com.apple.systempreferences"])
        #expect(l.isOnTask(bundleID: "com.apple.systempreferences", host: nil))
    }

    @Test func browserOnListedDomainOrSubdomain() {
        let l = list([AllowEntry(.domain, "figma.com")])
        #expect(l.isOnTask(bundleID: Browsers.safari, host: "figma.com"))
        #expect(l.isOnTask(bundleID: Browsers.chrome, host: "www.Figma.com"))
    }

    @Test func lookalikeDomainsAreOffTask() {
        let l = list([AllowEntry(.domain, "figma.com")])
        #expect(!l.isOnTask(bundleID: Browsers.safari, host: "notfigma.com"))
        #expect(!l.isOnTask(bundleID: Browsers.safari, host: "figma.com.evil.io"))
        #expect(!l.isOnTask(bundleID: Browsers.safari, host: "youtube.com"))
    }

    @Test func browserListedAsAppAllowsAnySite() {
        #expect(list([AllowEntry(.app, Browsers.safari)]).isOnTask(bundleID: Browsers.safari, host: "youtube.com"))
    }

    @Test func unreadableHostGetsBenefitOfDoubtOnlyWhenDomainsListed() {
        #expect(list([AllowEntry(.domain, "figma.com")]).isOnTask(bundleID: Browsers.safari, host: nil))
        #expect(!list([AllowEntry(.app, "com.figma.Desktop")]).isOnTask(bundleID: Browsers.safari, host: nil))
    }

    @Test func unsupportedBrowserJudgedAsAppOnly() {
        let l = list([AllowEntry(.domain, "figma.com")])
        #expect(!l.isOnTask(bundleID: "org.mozilla.firefox", host: "figma.com"))
    }

    @Test func domainNormalization() {
        #expect(AllowEntry(.domain, "https://www.Figma.com/file/abc?x=1").value == "figma.com")
        #expect(AllowEntry(.domain, "*.linear.app").value == "linear.app")
        #expect(AllowEntry(.domain, " .notion.so. ").value == "notion.so")
        #expect(AllowEntry(.domain, "localhost:3000").value == "localhost")
        #expect(AllowEntry(.app, "  com.Figma.Desktop ").value == "com.figma.desktop")
    }

    @Test func emptyDomainNeverMatches() {
        let l = list([AllowEntry(.domain, "  ")])
        #expect(!l.isOnTask(bundleID: Browsers.safari, host: "youtube.com."))
    }

    @Test func trailingDotHostMatches() {
        #expect(list([AllowEntry(.domain, "figma.com")]).isOnTask(bundleID: Browsers.safari, host: "www.figma.com."))
    }
}
