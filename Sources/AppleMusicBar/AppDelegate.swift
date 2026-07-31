import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let instanceLock: AppInstanceLock
    private var statusBarController: StatusBarController?

    init(instanceLock: AppInstanceLock) {
        self.instanceLock = instanceLock
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusBarController()
        statusBarController = controller
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController?.stop()
        statusBarController = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
