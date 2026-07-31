import AppKit

@main
enum AppleMusicBarMain {
    @MainActor
    static func main() {
        guard let instanceLock = AppInstanceLock.acquire() else {
            activateExistingInstance()
            return
        }

        let application = NSApplication.shared
        let applicationDelegate = AppDelegate(instanceLock: instanceLock)

        application.delegate = applicationDelegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    @MainActor
    private static func activateExistingInstance() {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: AppIdentity.bundleIdentifier
        )
        .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?
        .activate()
    }
}
