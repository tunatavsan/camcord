import AppKit

extension NSScreen {
    /// The `CGDirectDisplayID` AppKit hides in `deviceDescription` -- the join key
    /// between `NSScreen` (AppKit) and `SCDisplay` (ScreenCaptureKit).
    var cgDirectDisplayID: CGDirectDisplayID? {
        guard let value = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(value.uint32Value)
    }
}
