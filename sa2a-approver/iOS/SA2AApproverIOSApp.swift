// iOS app shell. Add this file to an Xcode iOS App target that depends on the local package
// products SA2AApproverCore and SA2AApproverUI. See docs/how-to/approver-apps.md.
import SA2AApproverUI
import SwiftUI

@main
struct SA2AApproverIOSApp: App {
    var body: some Scene { WindowGroup { ApproverView() } }
}
