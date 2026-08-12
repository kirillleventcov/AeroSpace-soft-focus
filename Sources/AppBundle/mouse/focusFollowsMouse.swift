import AppKit

@MainActor private var focusFollowsMouseMonitor: Any? = nil
@MainActor private var focusFollowsTask: Task<(), any Error>? = nil

@MainActor func syncFocusFollowsMouse(_ config: Config) {
    if config.focusFollowsMouse.enabled == (focusFollowsMouseMonitor != nil) {
        return
    }

    if !config.focusFollowsMouse.enabled {
        NSEvent.removeMonitor(focusFollowsMouseMonitor.orDie())
        focusFollowsMouseMonitor = nil
        focusFollowsTask?.cancel()
        focusFollowsTask = nil
        return
    }

    // Interestingly, this callback seems to not fire when the mouse is down which is good,
    // because this is how I want it to work for windows/tabs/files dragging
    focusFollowsMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { @MainActor event in
        let location = event.locationInWindow.withYAxisFlipped
        focusFollowsTask?.cancel()
        focusFollowsTask = Task.startUnstructured { @MainActor in
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try checkCancellation()
            // The AX hit test respects the real z-order, unlike the model-based lookup below.
            // Ignores macOS menubar dropdown, but, unfortunately, it doesn't ignore non-native menu-like fake windows.
            let hit = await axWindowUnderMouse(location)
            try checkCancellation()
            var hitWindowId: CGWindowID? = nil
            switch hit {
                case .notAWindow: return
                case .window(let id): hitWindowId = id
                case .unknown: break // AX hit test failed. Fall back to pure model-based window resolution
            }
            if let hitWindowId {
                switch MacWindow.allWindowsMap[hitWindowId] {
                    // The topmost window under the mouse is a popup (e.g. Chrome extension popup,
                    // context menu, tooltip). Focusing the window beneath would dismiss the popup
                    case let hitWindow? where hitWindow.parent is MacosPopupWindowsContainer: return
                    case .some: break
                    // The topmost window under the mouse is unknown to the model (a dialog that is not
                    // yet registered, a sheet, an OS overlay). Stealing focus from it would bury it
                    case nil: return
                }
            }
            let workspace = location.monitorApproximation.activeWorkspace
            var window: Window? = nil
            // Floating windows win over tiling windows in overlap areas even if macOS z-order
            // temporarily disagrees. Makes it possible to reach a floating window buried by a tile
            for child in workspace.floatingWindowsContainer.mruChildren {
                try checkCancellation()
                guard let child = child as? Window else { continue }
                guard let rect = try await child.getAxRect(.cancellable) else { continue }
                if rect.contains(location) {
                    window = child
                    break
                }
            }
            if window == nil, let hitWindowId, let hitWindow = MacWindow.allWindowsMap[hitWindowId],
               hitWindow.visualWorkspace == workspace
            {
                window = hitWindow
            }
            if window == nil {
                window = location.findWindowRecursively(in: workspace.rootTilingContainer, virtual: false, fullscreenCoversAll: true)
            }
            guard let window else { return }
            // The window is already natively focused. Re-raising it on every mouse move is not only
            // wasteful, it also dismisses popups of this window because popups don't become
            // lastNativeFocusedWindowId (see updateFocusCache)
            if window.macAppUnsafe.nsApp.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier &&
                window.macAppUnsafe.lastNativeFocusedWindowId == window.windowId
            {
                return
            }
            // While a popup holds the native focus (an open menu, Chrome extension popup, etc.)
            // hovering other windows must not steal focus, otherwise the popup gets dismissed.
            // Similar to popup grabs in Wayland compositors. Clicking still moves the focus
            let nativeFocused = try await getNativeFocusedWindow(.cancellable)
            try checkCancellation()
            if nativeFocused?.parent is MacosPopupWindowsContainer { return }
            try await runLightSession(.focusFollowsMouse, token) {
                _ = window.focusWindow()
                window.nativeFocus()
            }
        }
    }
}

private enum AxHitTestResult {
    /// AX hit test failed. The topmost window under the mouse is unknown
    case unknown
    /// The element under the mouse is not part of any window (desktop, menubar dropdown)
    case notAWindow
    /// The topmost window under the mouse
    case window(CGWindowID)
}

@concurrent
private nonisolated func axWindowUnderMouse(_ location: CGPoint) async -> AxHitTestResult {
    let systemwide = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    if unsafe AXUIElementCopyElementAtPosition(systemwide, Float(location.x), Float(location.y), &element) != .success {
        return .unknown
    }
    guard let element else { return .unknown }
    if element.get(Ax.parentWindowRecursive) == nil && element.get(Ax.roleAttr) != kAXWindowRole {
        return .notAWindow
    }
    return switch element.containingWindowId() {
        case let windowId?: .window(windowId)
        case nil: .unknown
    }
}
