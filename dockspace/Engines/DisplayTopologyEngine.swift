import AppKit
import Foundation

final class DisplayTopologyEngine {
    static let shared = DisplayTopologyEngine()

    func currentTopology() -> DisplayTopology {
        let screens = NSScreen.screens.map { screen -> DisplayTopology.ScreenInfo in
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) ?? 0
            let name = screen.localizedName
            return DisplayTopology.ScreenInfo(
                displayID: displayID,
                name: name,
                frame: CodableRect(screen.frame),
                visibleFrame: CodableRect(screen.visibleFrame)
            )
        }
        return DisplayTopology(screens: screens)
    }

    func adaptFrame(
        _ frame: CGRect,
        from originalTopology: DisplayTopology,
        to currentTopology: DisplayTopology,
        screenName: String?,
        displayID: UInt32?
    ) -> CGRect {
        // 1. Try to find the exact same display ID or screen name in the current topology
        var targetScreen: DisplayTopology.ScreenInfo?
        if let displayID {
            targetScreen = currentTopology.screens.first { $0.displayID == displayID }
        }
        if targetScreen == nil, let screenName {
            targetScreen = currentTopology.screens.first { $0.name == screenName }
        }

        // 2. If target screen not found, pick the closest screen or fallback to the main screen
        let currentScreens = currentTopology.screens
        guard !currentScreens.isEmpty else { return frame }

        let actualScreen: DisplayTopology.ScreenInfo
        if let matched = targetScreen {
            actualScreen = matched
        } else {
            // Fallback: Try to map based on screen order/index, or default to first (main) screen
            var matchedIndex = 0
            if let originalIndex = originalTopology.screens.firstIndex(where: { $0.displayID == displayID || $0.name == screenName }) {
                matchedIndex = min(originalIndex, currentScreens.count - 1)
            }
            actualScreen = currentScreens[matchedIndex]
        }

        // 3. Resolve original screen
        let originalScreen = originalTopology.screens.first { $0.displayID == displayID || $0.name == screenName }
            ?? originalTopology.screens.first // fallback

        guard let origScreen = originalScreen else {
            // No original screen to scale relative to, just clamp to actual screen visible frame
            return clampFrame(frame, to: actualScreen.visibleFrame.cgRect)
        }

        // 4. Scale and shift relative to original visible frame to target visible frame
        let origVis = origScreen.visibleFrame.cgRect
        let targetVis = actualScreen.visibleFrame.cgRect

        // Calculate relative position and size
        let relX = (frame.minX - origVis.minX) / (origVis.width > 0 ? origVis.width : 1)
        let relY = (frame.minY - origVis.minY) / (origVis.height > 0 ? origVis.height : 1)
        let relW = frame.width / (origVis.width > 0 ? origVis.width : 1)
        let relH = frame.height / (origVis.height > 0 ? origVis.height : 1)

        // Apply to target screen visible frame
        var newW = relW * targetVis.width
        var newH = relH * targetVis.height
        // Cap size to not exceed target screen visible bounds
        newW = min(newW, targetVis.width)
        newH = min(newH, targetVis.height)

        var newX = targetVis.minX + relX * targetVis.width
        var newY = targetVis.minY + relY * targetVis.height

        // Ensure it is fully contained inside target visible frame
        if newX + newW > targetVis.maxX {
            newX = targetVis.maxX - newW
        }
        if newX < targetVis.minX {
            newX = targetVis.minX
        }
        if newY + newH > targetVis.maxY {
            newY = targetVis.maxY - newH
        }
        if newY < targetVis.minY {
            newY = targetVis.minY
        }

        return CGRect(x: newX, y: newY, width: newW, height: newH)
    }

    private func clampFrame(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        let w = min(frame.width, bounds.width)
        let h = min(frame.height, bounds.height)
        let x = max(bounds.minX, min(frame.minX, bounds.maxX - w))
        let y = max(bounds.minY, min(frame.minY, bounds.maxY - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
