import AppKit

/// The single bridge from AppKit and CoreGraphics to `DisplayDescriptor`.
///
/// Every other file in the multi-display layer works on descriptors, so this is
/// the only code that has to run on a Mac with the right hardware attached.
/// Keeping it this small is what makes the rest of the layer testable.
@MainActor
enum ScreenDisplaySource {
    static func descriptors() -> [DisplayDescriptor] {
        // Read once: `NSStatusBar.system.thickness` is the same for every
        // display, and asking per screen inside the loop would be the same
        // answer bought several times.
        let menuBarHeight = max(NSStatusBar.system.thickness, 24)
        return NSScreen.screens.compactMap { screen in
            guard let id = screen.impulsDisplayID else { return nil }
            return DisplayDescriptor(
                id: id,
                name: screen.localizedName,
                frame: screen.frame,
                safeAreaTop: screen.safeAreaInsets.top,
                auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
                auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width,
                menuBarHeight: menuBarHeight,
                backingScale: screen.backingScaleFactor,
                // The primary display defines the origin of the global
                // coordinate space, so it is the one sitting at exactly zero —
                // no other display can, since none may overlap it.
                isPrimary: screen.frame.origin == .zero,
                mirrorSourceID: mirrorSource(of: id)
            )
        }
    }

    /// The display macOS currently treats as active — the one with the key
    /// window, or failing that the one the pointer is on. Used only as a
    /// fallback when the pointer is not over a display Impuls may use.
    static var mainDisplayID: UInt32? { NSScreen.main?.impulsDisplayID }

    /// Public CoreGraphics. `CGDisplayMirrorsDisplay` answers with the display
    /// being mirrored, or `kCGNullDirectDisplay` when this one stands alone.
    private static func mirrorSource(of id: UInt32) -> UInt32? {
        let source = CGDisplayMirrorsDisplay(id)
        return source == kCGNullDirectDisplay ? nil : source
    }
}
