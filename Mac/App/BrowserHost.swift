import Foundation
import Core

enum BrowserHostError: Error { case automationDenied }

@MainActor
enum BrowserHost {
    static func host(for bundleID: String) -> Result<String?, BrowserHostError> {
        let src: String
        switch bundleID.lowercased() {
        case Browsers.safari: src = #"tell application "Safari" to return URL of current tab of front window"#
        case Browsers.chrome: src = #"tell application "Google Chrome" to return URL of active tab of front window"#
        default: return .success(nil)
        }
        var err: NSDictionary?
        let out = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err {
            return (err[NSAppleScript.errorNumber] as? Int) == -1743 ? .failure(.automationDenied) : .success(nil)
        }
        return .success(out?.stringValue.flatMap { URL(string: $0)?.host() })
    }
}
