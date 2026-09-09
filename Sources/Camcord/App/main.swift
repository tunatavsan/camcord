import AppKit

// Development and installed bundles share the same global input bindings. Never
// register a second set. The running-app check also recognizes older releases that
// predate the process lock; flock closes the simultaneous-launch race for new builds.
let bundleID = Bundle.main.bundleIdentifier ?? "dev.tavsan.camcord"
let currentApplication = NSRunningApplication.current
let currentLaunch = currentApplication.launchDate ?? .distantPast
if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { candidate in
    guard candidate.processIdentifier != currentApplication.processIdentifier, !candidate.isTerminated else { return false }
    let launch = candidate.launchDate ?? .distantPast
    // Deterministic election: simultaneous launches cannot both see a peer and exit.
    return launch < currentLaunch || (launch == currentLaunch && candidate.processIdentifier < currentApplication.processIdentifier)
}) {
    exit(0)
}
let instanceLock: AppInstanceLock
do {
    instanceLock = try AppInstanceLock(url: AppInstanceLock.defaultURL)
} catch AppInstanceLock.LockError.alreadyRunning {
    exit(0)
} catch {
    FileHandle.standardError.write(Data("Camcord could not acquire its capture session: \(error)\n".utf8))
    exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
withExtendedLifetime(instanceLock) { app.run() }
