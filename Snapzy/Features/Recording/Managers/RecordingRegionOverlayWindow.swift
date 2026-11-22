//
//  RecordingRegionOverlayWindow.swift
//  Snapzy
//
//  Persistent overlay window showing the recording region highlight
//

import AppKit

enum RecordingRegionOverlayGuidanceTone {
  case neutral
  case active
  case warning
  case progress

  var accentColor: NSColor {
    switch self {
    case .neutral:
      return NSColor.white.withAlphaComponent(0.85)
    case .active:
      return NSColor.systemBlue
    case .warning:
      return NSColor.systemOrange
    case .progress:
      return NSColor.systemTeal
    }
  }
}

struct RecordingRegionOverlayGuidance {
  let title: String
  let detail: String?
  let tone: RecordingRegionOverlayGuidanceTone
}

// MARK: - RecordingResizeHandle

/// Resize handle positions for edge and corner resizing
enum RecordingResizeHandle {
  case topLeft, top, topRight
  case left, right
  case bottomLeft, bottom, bottomRight

  var fixedAnchor: CGPoint {
    switch self {
    case .topLeft: CGPoint(x: 1, y: 0)
    case .top: CGPoint(x: 0.5, y: 0)
    case .topRight: CGPoint(x: 0, y: 0)
    case .left: CGPoint(x: 1, y: 0.5)
    case .right: CGPoint(x: 0, y: 0.5)
    case .bottomLeft: CGPoint(x: 1, y: 1)
    case .bottom: CGPoint(x: 0.5, y: 1)
    case .bottomRight: CGPoint(x: 0, y: 1)
    }
  }
}

// MARK: - RecordingRegionOverlayDelegate

/// Delegate protocol for overlay interaction events
@MainActor
protocol RecordingRegionOverlayDelegate: AnyObject {
  func overlayDidRequestReselection(_ overlay: RecordingRegionOverlayWindow)
  func overlay(_ overlay: RecordingRegionOverlayWindow, didMoveRegionTo rect: CGRect)
  func overlayDidFinishMoving(_ overlay: RecordingRegionOverlayWindow)
  func overlay(_ overlay: RecordingRegionOverlayWindow, didReselectWithRect rect: CGRect)
  func overlay(_ overlay: RecordingRegionOverlayWindow, didResizeRegionTo rect: CGRect)
  func overlayDidFinishResizing(_ overlay: RecordingRegionOverlayWindow)
}

// MARK: - RecordingRegionOverlayWindow

/// Overlay panel showing the recording region highlight during recording
/// Uses NSPanel with .nonactivatingPanel to prevent background windows from deactivating
@MainActor
final class RecordingRegionOverlayWindow: NSPanel {

  weak var interactionDelegate: RecordingRegionOverlayDelegate?

  private let overlayView: RecordingRegionOverlayView

  /// - Parameter chromeRole: `.recordingControls` for the recording region (kept out of
  ///   Snapzy's own recordings); scrolling capture passes `.captureOverlay`.
  init(
    screen: NSScreen,
    highlightRect: CGRect,
    chromeRole: CaptureChromeWindowRegistry.Role = .recordingControls
  ) {
    self.overlayView = RecordingRegionOverlayView(
      frame: screen.frame,
      highlightRect: highlightRect
    )

    super.init(
      contentRect: screen.frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    configureWindow(screen: screen, chromeRole: chromeRole)
    contentView = overlayView
  }

  private func configureWindow(screen: NSScreen, chromeRole: CaptureChromeWindowRegistry.Role) {
    isFloatingPanel = true
    isOpaque = false
    backgroundColor = .clear
    CaptureChromeWindowRegistry.configure(self, role: chromeRole)
    // Панели управления и превью должны принимать клики поверх интерактивного слоя.
    level = .floating
    ignoresMouseEvents = true
    hasShadow = false
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    animationBehavior = .none  // Disable window animations for instant appearance
    
    isMovable = false
    isMovableByWindowBackground = false
    minSize = screen.frame.size
    maxSize = screen.frame.size
  }

  override func setFrame(_ frameRect: NSRect, display displayFlag: Bool) {
    self.minSize = frameRect.size
    self.maxSize = frameRect.size
    super.setFrame(frameRect, display: displayFlag)
  }

  func updateHighlightRect(_ rect: CGRect) {
    let oldLocalRect = overlayView.localHighlightRect()
    overlayView.highlightRect = rect
    let newLocalRect = overlayView.localHighlightRect()

    // Dirty-rect invalidation: only redraw the union of old + new positions
    // with padding for resize handles and border width, instead of the entire
    // full-screen view (which can be 15M+ pixels on 4K/5K).
    let handlePadding: CGFloat = 25 // cornerHandleLength + margin
    let dirtyRect = oldLocalRect.insetBy(dx: -handlePadding, dy: -handlePadding)
      .union(newLocalRect.insetBy(dx: -handlePadding, dy: -handlePadding))
    overlayView.setNeedsDisplay(dirtyRect)
  }

  func updateGuidance(_ guidance: RecordingRegionOverlayGuidance?) {
    overlayView.guidance = guidance
  }

  func setAspectRatio(_ ratio: CGFloat?) {
    overlayView.aspectRatio = ratio
  }

  /// Hide the border when recording starts (border would appear in video)
  func hideBorder() {
    overlayView.showBorder = false
    overlayView.needsDisplay = true
  }

  /// Show the border (for pre-record phase)
  func showBorder() {
    overlayView.showBorder = true
    overlayView.needsDisplay = true
  }

  /// Enable or disable the dim fill outside the recording region.
  /// Called at record-start (and on live preference changes) so non-selected
  /// windows stay fully visible and usable during recording.
  func setDimEnabled(_ enabled: Bool) {
    guard overlayView.showDim != enabled else { return }
    overlayView.showDim = enabled
    // Full-view invalidate (not dirty-rect) so any previously drawn dim is fully cleared.
    overlayView.needsDisplay = true
  }

  /// Enable or disable mouse interaction (disabled during recording)
  func setInteractionEnabled(_ enabled: Bool) {
    ignoresMouseEvents = !enabled
    overlayView.isInteractionEnabled = enabled
    if enabled {
      overlayView.overlayWindow = self
    }
    overlayView.refreshCursor()
  }

  /// Only update interaction state when it actually changes, to avoid
  /// redundant invalidateCursorRects calls on every drag event.
  func setInteractionEnabledIfNeeded(_ enabled: Bool) {
    guard overlayView.isInteractionEnabled != enabled else { return }
    setInteractionEnabled(enabled)
  }

  override func close() {
    // Restore cursor to arrow before closing — the overlay may have set
    // a resize, openHand, or crosshair cursor that could persist if the
    // window is dismissed before mouseExited fires.
    NSCursor.arrow.set()
    super.close()
  }

  // Non-activating: prevent stealing focus from other apps
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

// MARK: - RecordingRegionOverlayView

/// View that draws the dimmed overlay with highlighted recording region
final class RecordingRegionOverlayView: NSView {

  var highlightRect: CGRect
  var aspectRatio: CGFloat?
  var showBorder: Bool = true
  var showDim: Bool = true
  var isInteractionEnabled: Bool = false
  var guidance: RecordingRegionOverlayGuidance? {
    didSet {
      needsDisplay = true
    }
  }
  weak var overlayWindow: RecordingRegionOverlayWindow?

  // Drag state
  private var isDragging = false
  private var dragOffset: CGPoint = .zero

  // Resize state
  private var isResizing = false
  private var activeHandle: RecordingResizeHandle?
  private var resizeStartRect: CGRect = .zero
  private var resizeStartPoint: CGPoint = .zero

  // New selection state (for immediate reselection on click outside)
  private var isNewSelecting = false
  private var newSelectionStart: CGPoint = .zero
  private var newSelectionEnd: CGPoint = .zero

  // Cross-display event monitors — allow drag/resize/reselect gestures to continue
  // seamlessly when the pointer crosses screen boundaries. Without these, per-view
  // mouse events stop once the pointer exits this window's frame.
  private var crossDisplayLocalMonitor: Any?
  private var crossDisplayGlobalMonitor: Any?

  // Constants
  /// Затемнение вне выделения – чёрный 50 % (R24): яркость падает вдвое, 38 → 19
  /// (audit-020/reference-recording-panel-desktop.png, x1279/1280 y1300).
  private let dimColor = NSColor.black.withAlphaComponent(RecordingSelectionBrackets.dimAlpha)
  private let handleHitSize: CGFloat = 10.0
  private let minimumSelectionSize: CGFloat = 50.0

  init(frame: CGRect, highlightRect: CGRect) {
    self.highlightRect = highlightRect
    super.init(frame: frame)
    setupTrackingArea()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupTrackingArea() {
    let trackingArea = NSTrackingArea(
      rect: bounds,
      options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .cursorUpdate],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(trackingArea)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas {
      removeTrackingArea(area)
    }
    setupTrackingArea()
  }

  override func cursorUpdate(with event: NSEvent) {
    guard isInteractionEnabled else {
      NSCursor.arrow.set()
      return
    }
    updateCursorFor(point: convert(event.locationInWindow, from: nil))
  }

  override func mouseEntered(with event: NSEvent) {
    guard isInteractionEnabled else {
      NSCursor.arrow.set()
      return
    }
    updateCursorFor(point: convert(event.locationInWindow, from: nil))
  }

  override func mouseExited(with event: NSEvent) {
    NSCursor.arrow.set()
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: isInteractionEnabled ? .crosshair : .arrow)
  }

  func refreshCursor() {
    window?.invalidateCursorRects(for: self)

    guard isInteractionEnabled, let window else {
      NSCursor.arrow.set()
      return
    }

    let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
    let point = convert(windowPoint, from: nil)
    if bounds.contains(point) {
      updateCursorFor(point: point)
    }
  }

  // Accept first mouse click without requiring window activation
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    return true
  }

  // MARK: - Coordinate Conversion

  func localHighlightRect() -> CGRect {
    guard let window = window else { return .zero }
    let windowFrame = window.frame
    return CGRect(
      x: highlightRect.origin.x - windowFrame.origin.x,
      y: highlightRect.origin.y - windowFrame.origin.y,
      width: highlightRect.width,
      height: highlightRect.height
    )
  }

  private func convertToScreenCoords(_ localPoint: CGPoint) -> CGPoint {
    guard let window = window else { return localPoint }
    return CGPoint(
      x: localPoint.x + window.frame.origin.x,
      y: localPoint.y + window.frame.origin.y
    )
  }

  // MARK: - Resize Handle Detection

  private func handleAt(point: CGPoint) -> RecordingResizeHandle? {
    let rect = localHighlightRect()
    let hs = handleHitSize

    // Corner handles (check first, higher priority)
    if CGRect(x: rect.minX - hs, y: rect.maxY - hs, width: hs * 2, height: hs * 2).contains(point) {
      return .topLeft
    }
    if CGRect(x: rect.maxX - hs, y: rect.maxY - hs, width: hs * 2, height: hs * 2).contains(point) {
      return .topRight
    }
    if CGRect(x: rect.minX - hs, y: rect.minY - hs, width: hs * 2, height: hs * 2).contains(point) {
      return .bottomLeft
    }
    if CGRect(x: rect.maxX - hs, y: rect.minY - hs, width: hs * 2, height: hs * 2).contains(point) {
      return .bottomRight
    }

    // Edge handles
    if CGRect(x: rect.midX - hs, y: rect.maxY - hs, width: hs * 2, height: hs * 2).contains(point) {
      return .top
    }
    if CGRect(x: rect.midX - hs, y: rect.minY - hs, width: hs * 2, height: hs * 2).contains(point) {
      return .bottom
    }
    if CGRect(x: rect.minX - hs, y: rect.midY - hs, width: hs * 2, height: hs * 2).contains(point) {
      return .left
    }
    if CGRect(x: rect.maxX - hs, y: rect.midY - hs, width: hs * 2, height: hs * 2).contains(point) {
      return .right
    }

    return nil
  }

  private func cursorFor(handle: RecordingResizeHandle) -> NSCursor {
    switch handle {
    case .topLeft, .bottomRight:
      // NW-SE diagonal resize (↖↘)
      return NSCursor(image: diagonalResizeCursorImage(nwse: true), hotSpot: NSPoint(x: 8, y: 8))
    case .topRight, .bottomLeft:
      // NE-SW diagonal resize (↗↙)
      return NSCursor(image: diagonalResizeCursorImage(nwse: false), hotSpot: NSPoint(x: 8, y: 8))
    case .top, .bottom:
      return NSCursor.resizeUpDown
    case .left, .right:
      return NSCursor.resizeLeftRight
    }
  }

  /// Generate diagonal resize cursor image (matches Annotate crop cursors)
  private func diagonalResizeCursorImage(nwse: Bool) -> NSImage {
    let size = NSSize(width: 16, height: 16)
    let image = NSImage(size: size)
    image.lockFocus()

    let path = NSBezierPath()
    path.lineWidth = 1.5
    path.lineCapStyle = .round

    if nwse {
      // NW-SE diagonal (↖↘)
      // Arrow pointing to top-left
      path.move(to: NSPoint(x: 3, y: 13))
      path.line(to: NSPoint(x: 3, y: 8))
      path.move(to: NSPoint(x: 3, y: 13))
      path.line(to: NSPoint(x: 8, y: 13))
      // Main diagonal line
      path.move(to: NSPoint(x: 3, y: 13))
      path.line(to: NSPoint(x: 13, y: 3))
      // Arrow pointing to bottom-right
      path.move(to: NSPoint(x: 13, y: 3))
      path.line(to: NSPoint(x: 13, y: 8))
      path.move(to: NSPoint(x: 13, y: 3))
      path.line(to: NSPoint(x: 8, y: 3))
    } else {
      // NE-SW diagonal (↗↙)
      // Arrow pointing to top-right
      path.move(to: NSPoint(x: 13, y: 13))
      path.line(to: NSPoint(x: 13, y: 8))
      path.move(to: NSPoint(x: 13, y: 13))
      path.line(to: NSPoint(x: 8, y: 13))
      // Main diagonal line
      path.move(to: NSPoint(x: 13, y: 13))
      path.line(to: NSPoint(x: 3, y: 3))
      // Arrow pointing to bottom-left
      path.move(to: NSPoint(x: 3, y: 3))
      path.line(to: NSPoint(x: 3, y: 8))
      path.move(to: NSPoint(x: 3, y: 3))
      path.line(to: NSPoint(x: 8, y: 3))
    }

    // Draw white outline for visibility on dark backgrounds
    NSColor.white.withAlphaComponent(0.5).setStroke()
    path.lineWidth = 2.5
    path.stroke()

    // Draw black arrow
    NSColor.black.setStroke()
    path.lineWidth = 1.5
    path.stroke()

    image.unlockFocus()
    return image
  }

  private func calculateResizedRect(handle: RecordingResizeHandle, delta: CGPoint) -> CGRect {
    var rect = resizeStartRect
    let minSize = minimumSelectionSize

    switch handle {
    case .topLeft:
      rect.origin.x += delta.x
      rect.size.width -= delta.x
      rect.size.height += delta.y
    case .top:
      rect.size.height += delta.y
    case .topRight:
      rect.size.width += delta.x
      rect.size.height += delta.y
    case .left:
      rect.origin.x += delta.x
      rect.size.width -= delta.x
    case .right:
      rect.size.width += delta.x
    case .bottomLeft:
      rect.origin.x += delta.x
      rect.origin.y += delta.y
      rect.size.width -= delta.x
      rect.size.height -= delta.y
    case .bottom:
      rect.origin.y += delta.y
      rect.size.height -= delta.y
    case .bottomRight:
      rect.origin.y += delta.y
      rect.size.width += delta.x
      rect.size.height -= delta.y
    }

    // Enforce minimum size with origin adjustment
    if rect.width < minSize {
      if handle == .left || handle == .topLeft || handle == .bottomLeft {
        rect.origin.x = resizeStartRect.maxX - minSize
      }
      rect.size.width = minSize
    }
    if rect.height < minSize {
      if handle == .bottom || handle == .bottomLeft || handle == .bottomRight {
        rect.origin.y = resizeStartRect.maxY - minSize
      }
      rect.size.height = minSize
    }

    if let aspectRatio {
      return OwnShotCaptureGeometry.constrainedResize(rect, from: resizeStartRect, aspectRatio: aspectRatio, within: Self.unifiedDesktopFrame, fixedAnchor: handle.fixedAnchor)
    }
    return rect
  }

  // MARK: - Unified Desktop Frame

  /// Union of all connected screen frames — used as the outer boundary for
  /// cross-display drag/resize/reselect so the selection can move freely
  /// between displays but not drift outside the physical display area.
  private static var unifiedDesktopFrame: CGRect {
    NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
  }

  // MARK: - Cross-Display Event Monitors

  /// Install local + global event monitors so drag/resize/reselect gestures
  /// continue seamlessly when the pointer crosses a screen boundary.
  /// Each per-screen `NSView` stops receiving `mouseDragged`/`mouseUp` once
  /// the pointer exits its window's frame; these monitors fill that gap by
  /// using `NSEvent.mouseLocation` (global screen coordinates).
  private func installCrossDisplayMonitorIfNeeded() {
    guard crossDisplayLocalMonitor == nil else { return }

    crossDisplayLocalMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDragged, .leftMouseUp]
    ) { [weak self] event in
      guard let self else { return event }
      let screenPoint = NSEvent.mouseLocation
      switch event.type {
      case .leftMouseDragged:
        self.handleCrossDisplayDrag(screenPoint: screenPoint)
      case .leftMouseUp:
        self.handleCrossDisplayMouseUp(screenPoint: screenPoint)
      default:
        break
      }
      // Consume the event so the per-view handler doesn't double-process.
      return nil
    }

    crossDisplayGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDragged, .leftMouseUp]
    ) { [weak self] event in
      let screenPoint = NSEvent.mouseLocation
      switch event.type {
      case .leftMouseDragged:
        self?.handleCrossDisplayDrag(screenPoint: screenPoint)
      case .leftMouseUp:
        self?.handleCrossDisplayMouseUp(screenPoint: screenPoint)
      default:
        break
      }
    }
  }

  private func removeCrossDisplayMonitor() {
    if let monitor = crossDisplayLocalMonitor {
      NSEvent.removeMonitor(monitor)
      crossDisplayLocalMonitor = nil
    }
    if let monitor = crossDisplayGlobalMonitor {
      NSEvent.removeMonitor(monitor)
      crossDisplayGlobalMonitor = nil
    }
  }

  override func removeFromSuperview() {
    removeCrossDisplayMonitor()
    super.removeFromSuperview()
  }

  // MARK: - Cross-Display Drag/Resize/Reselect Handlers

  /// Clamp `rect` so it stays fully within the unified desktop frame.
  private func clampRectToDesktop(_ rect: CGRect) -> CGRect {
    let desktop = Self.unifiedDesktopFrame
    var origin = rect.origin
    origin.x = max(desktop.minX, min(origin.x, desktop.maxX - rect.width))
    origin.y = max(desktop.minY, min(origin.y, desktop.maxY - rect.height))
    return CGRect(origin: origin, size: rect.size)
  }

  /// Clamp resize result so edges stay within the unified desktop frame
  /// while enforcing minimum selection size.
  private func clampResizedRectToDesktop(_ rect: CGRect) -> CGRect {
    if aspectRatio != nil { return rect }
    let desktop = Self.unifiedDesktopFrame
    var r = rect
    // Clamp left edge
    if r.minX < desktop.minX { r.size.width -= (desktop.minX - r.minX); r.origin.x = desktop.minX }
    // Clamp bottom edge
    if r.minY < desktop.minY { r.size.height -= (desktop.minY - r.minY); r.origin.y = desktop.minY }
    // Clamp right edge
    if r.maxX > desktop.maxX { r.size.width = desktop.maxX - r.origin.x }
    // Clamp top edge
    if r.maxY > desktop.maxY { r.size.height = desktop.maxY - r.origin.y }
    // Re-enforce minimum size after clamping
    r.size.width = max(r.width, minimumSelectionSize)
    r.size.height = max(r.height, minimumSelectionSize)
    return r
  }

  private func handleCrossDisplayDrag(screenPoint: CGPoint) {
    guard let overlayWindow else { return }

    if isResizing, let handle = activeHandle {
      // Resize: compute delta in screen coordinates relative to the start point.
      let screenStartPoint = convertToScreenCoords(resizeStartPoint)
      let delta = CGPoint(x: screenPoint.x - screenStartPoint.x, y: screenPoint.y - screenStartPoint.y)
      var resized = calculateResizedRect(handle: handle, delta: delta)
      // Option: размер меняется симметрично от центра. С заданной пропорцией не действует.
      if aspectRatio == nil, NSEvent.modifierFlags.contains(.option) {
        resized = RecordingRegionGeometry.centeredResize(
          resized, from: resizeStartRect, handle: handle, minimumSize: minimumSelectionSize
        )
      }
      let newRect = clampResizedRectToDesktop(resized)
      overlayWindow.interactionDelegate?.overlay(overlayWindow, didResizeRegionTo: newRect)
      return
    }

    if isNewSelecting {
      // Reselect: track in screen coordinates.
      newSelectionEnd = screenPoint
      // Trigger redraw on all overlay windows via the delegate's highlight update.
      let rect = calculateNewSelectionScreenRect()
      if rect.width > 0, rect.height > 0 {
        overlayWindow.interactionDelegate?.overlay(overlayWindow, didResizeRegionTo: rect)
      }
      return
    }

    if isDragging {
      // Drag: compute new origin in screen coordinates and clamp to desktop.
      let newScreenOrigin = CGPoint(
        x: screenPoint.x - dragOffset.x,
        y: screenPoint.y - dragOffset.y
      )
      let newRect = clampRectToDesktop(
        CGRect(origin: newScreenOrigin, size: highlightRect.size)
      )
      overlayWindow.interactionDelegate?.overlay(overlayWindow, didMoveRegionTo: newRect)
    }
  }

  private func handleCrossDisplayMouseUp(screenPoint: CGPoint) {
    guard let overlayWindow else {
      removeCrossDisplayMonitor()
      return
    }

    if isResizing {
      isResizing = false
      activeHandle = nil
      removeCrossDisplayMonitor()
      overlayWindow.interactionDelegate?.overlayDidFinishResizing(overlayWindow)
      let localPoint = convertFromScreenCoords(screenPoint)
      updateCursorFor(point: localPoint)
      return
    }

    if isNewSelecting {
      isNewSelecting = false
      removeCrossDisplayMonitor()
      let rect = calculateNewSelectionScreenRect()
      if rect.width > 5, rect.height > 5 {
        overlayWindow.interactionDelegate?.overlay(overlayWindow, didReselectWithRect: rect)
      }
      needsDisplay = true
      return
    }

    if isDragging {
      isDragging = false
      removeCrossDisplayMonitor()
      NSCursor.openHand.set()
      overlayWindow.interactionDelegate?.overlayDidFinishMoving(overlayWindow)
    }
  }

  // MARK: - Mouse Events

  override func mouseDown(with event: NSEvent) {
    guard isInteractionEnabled, overlayWindow != nil else { return }

    let point = convert(event.locationInWindow, from: nil)
    let localRect = localHighlightRect()

    // Check for resize handle first
    if let handle = handleAt(point: point) {
      isResizing = true
      activeHandle = handle
      resizeStartRect = highlightRect
      resizeStartPoint = point
      cursorFor(handle: handle).set()
      installCrossDisplayMonitorIfNeeded()
      return
    }

    if localRect.contains(point) {
      // Start dragging existing selection — store offset in screen coordinates
      // so the drag tracks correctly across display boundaries.
      isDragging = true
      let screenPoint = NSEvent.mouseLocation
      dragOffset = CGPoint(
        x: screenPoint.x - highlightRect.origin.x,
        y: screenPoint.y - highlightRect.origin.y
      )
      NSCursor.closedHand.set()
      installCrossDisplayMonitorIfNeeded()
    } else {
      // Click outside - start new selection. Track in screen coordinates
      // so the gesture can span multiple displays.
      isNewSelecting = true
      let screenPoint = NSEvent.mouseLocation
      newSelectionStart = screenPoint
      newSelectionEnd = screenPoint
      NSCursor.crosshair.set()
      installCrossDisplayMonitorIfNeeded()
    }
  }

  override func mouseDragged(with event: NSEvent) {
    // Cross-display monitors handle drag events via handleCrossDisplayDrag().
    // This override is kept as a no-op guard so the gesture doesn't double-fire
    // when the pointer is still inside this view's window.
  }

  override func mouseUp(with event: NSEvent) {
    // Cross-display monitors handle mouseUp via handleCrossDisplayMouseUp().
    // This override is kept as a no-op guard.
  }

  /// Calculate new selection rect from screen-coordinate start/end points.
  private func calculateNewSelectionScreenRect() -> CGRect {
    // Option: точка нажатия – центр новой области.
    RecordingRegionGeometry.selectionRect(
      start: newSelectionStart,
      end: newSelectionEnd,
      fromCenter: NSEvent.modifierFlags.contains(.option)
    )
  }

  /// Convert a screen-space point to this view's local coordinate space.
  private func convertFromScreenCoords(_ screenPoint: CGPoint) -> CGPoint {
    guard let window = window else { return screenPoint }
    return CGPoint(
      x: screenPoint.x - window.frame.origin.x,
      y: screenPoint.y - window.frame.origin.y
    )
  }

  override func mouseMoved(with event: NSEvent) {
    guard isInteractionEnabled else { return }
    let point = convert(event.locationInWindow, from: nil)
    updateCursorFor(point: point)
  }

  private func updateCursorFor(point: CGPoint) {
    // Check for resize handle first
    if let handle = handleAt(point: point) {
      cursorFor(handle: handle).set()
      return
    }

    let localRect = localHighlightRect()
    if localRect.contains(point) {
      NSCursor.openHand.set()
    } else {
      NSCursor.crosshair.set()
    }
  }

  // MARK: - Drawing

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    // Draw dim overlay — only the dirty region (skipped when dimming is disabled)
    if showDim {
      dimColor.setFill()
      dirtyRect.fill()
    }

    // If actively making new selection, draw that instead
    if isNewSelecting {
      drawNewSelection()
      return
    }

    // Convert screen coords to view coords
    guard let window = window else { return }
    let windowFrame = window.frame
    let localRect = CGRect(
      x: highlightRect.origin.x - windowFrame.origin.x,
      y: highlightRect.origin.y - windowFrame.origin.y,
      width: highlightRect.width,
      height: highlightRect.height
    )

    // Only draw highlight if rect intersects this screen
    guard localRect.intersects(bounds) else { return }

    // Clamp to bounds
    let clampedRect = localRect.intersection(bounds)

    // Clear the highlight area (only meaningful when a dim fill was drawn)
    if showDim {
      let clearRect = clampedRect.intersection(dirtyRect)
      if !clearRect.isNull {
        NSColor.clear.setFill()
        clearRect.fill(using: .copy)
      }
    }

    // Draw border around highlight (only in pre-record phase)
    if showBorder {
      // Only draw border and handles if they intersect the dirty rect
      let handlePadding: CGFloat = 25
      let borderArea = clampedRect.insetBy(dx: -handlePadding, dy: -handlePadding)
      if borderArea.intersects(dirtyRect) {
        // Сплошного контура у эталона нет: только скобки углов и метки середин сторон (R27).
        drawSelectionBrackets(for: clampedRect)
      }
    }

    if let guidance, bounds.contains(CGPoint(x: localRect.midX, y: localRect.midY)) {
      drawGuidance(guidance, in: clampedRect)
    }
  }

  private func drawGuidance(_ guidance: RecordingRegionOverlayGuidance, in rect: CGRect) {
    let horizontalInset = min(max(16, rect.width * 0.08), 28)
    let availableWidth = rect.width - horizontalInset * 2
    guard availableWidth >= 120 else { return }

    let prefersCompactLayout = rect.width < 230 || rect.height < 110
    let showsDetail = !prefersCompactLayout && guidance.detail != nil
    let titleFont = NSFont.systemFont(ofSize: prefersCompactLayout ? 15 : 17, weight: .semibold)
    let detailFont = NSFont.systemFont(ofSize: prefersCompactLayout ? 11 : 12, weight: .medium)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center
    paragraphStyle.lineBreakMode = .byWordWrapping

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = 8
    shadow.shadowOffset = .zero

    let titleAttributes: [NSAttributedString.Key: Any] = [
      .font: titleFont,
      .foregroundColor: NSColor.white,
      .paragraphStyle: paragraphStyle,
      .shadow: shadow
    ]
    let detailAttributes: [NSAttributedString.Key: Any] = [
      .font: detailFont,
      .foregroundColor: NSColor.white.withAlphaComponent(0.84),
      .paragraphStyle: paragraphStyle
    ]

    let textWidth = min(availableWidth - 24, 336)
    let titleString = NSAttributedString(string: guidance.title, attributes: titleAttributes)
    let titleBounds = titleString.boundingRect(
      with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    )

    let detailString = showsDetail
      ? NSAttributedString(string: guidance.detail ?? "", attributes: detailAttributes)
      : nil
    let detailBounds = detailString?.boundingRect(
      with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    ) ?? .zero

    let cardWidth = min(max(160, textWidth + 24), availableWidth)
    let cardHeight = max(
      prefersCompactLayout ? 38 : 44,
      ceil(titleBounds.height) + (showsDetail ? ceil(detailBounds.height) + 6 : 0) + 22
    )
    let defaultY = rect.maxY - cardHeight - 18
    let cardY = max(rect.minY + 12, defaultY)
    let cardRect = CGRect(
      x: rect.midX - cardWidth / 2,
      y: cardY,
      width: cardWidth,
      height: cardHeight
    )

    let fillPath = NSBezierPath(
      roundedRect: cardRect,
      xRadius: prefersCompactLayout ? 12 : 14,
      yRadius: prefersCompactLayout ? 12 : 14
    )
    NSColor.black.withAlphaComponent(prefersCompactLayout ? 0.74 : 0.8).setFill()
    fillPath.fill()

    let strokePath = NSBezierPath(
      roundedRect: cardRect,
      xRadius: prefersCompactLayout ? 12 : 14,
      yRadius: prefersCompactLayout ? 12 : 14
    )
    strokePath.lineWidth = 1
    guidance.tone.accentColor.withAlphaComponent(0.5).setStroke()
    strokePath.stroke()

    let accentRect = CGRect(
      x: cardRect.midX - min(cardRect.width * 0.22, 44) / 2,
      y: cardRect.maxY - 6,
      width: min(cardRect.width * 0.22, 44),
      height: 3
    )
    let accentPath = NSBezierPath(
      roundedRect: accentRect,
      xRadius: 1.5,
      yRadius: 1.5
    )
    guidance.tone.accentColor.withAlphaComponent(0.95).setFill()
    accentPath.fill()

    let titleRect = CGRect(
      x: cardRect.minX + 12,
      y: cardRect.maxY - ceil(titleBounds.height) - (showsDetail ? 12 : (cardHeight - ceil(titleBounds.height)) / 2),
      width: cardRect.width - 24,
      height: ceil(titleBounds.height)
    )
    titleString.draw(with: titleRect, options: [.usesLineFragmentOrigin, .usesFontLeading])

    if let detailString, showsDetail {
      let detailRect = CGRect(
        x: cardRect.minX + 12,
        y: cardRect.minY + 10,
        width: cardRect.width - 24,
        height: ceil(detailBounds.height)
      )
      detailString.draw(with: detailRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
  }

  /// Белые скобки 4 pt по центру края: углы с плечом 17,5 pt и метки 17×4 pt по серединам
  /// сторон, внешний радиус ≈1 pt. Под белым – тонкая тёмная кайма 1 pt, как у эталона, чтобы
  /// скобка читалась и на белом содержимом (spec-039-live/all-in-one-overlay-initial.png).
  private func drawSelectionBrackets(for rect: CGRect) {
    let radius = RecordingSelectionBrackets.outerCornerRadius
    let paths = RecordingSelectionBrackets.rects(for: rect).map {
      NSBezierPath(roundedRect: $0, xRadius: radius, yRadius: radius)
    }
    RecordingSelectionBrackets.edgeShadowColor.setStroke()
    for path in paths {
      path.lineWidth = RecordingSelectionBrackets.edgeShadowWidth * 2
      path.stroke()
    }
    NSColor.white.setFill()
    paths.forEach { $0.fill() }
  }

  private func drawNewSelection() {
    // New selection is now tracked in screen coordinates. Convert to local
    // for rendering, then clip to this view's bounds.
    let screenRect = calculateNewSelectionScreenRect()
    guard screenRect.width > 0, screenRect.height > 0 else { return }

    let localOrigin = convertFromScreenCoords(screenRect.origin)
    let localRect = CGRect(origin: localOrigin, size: screenRect.size)
      .intersection(bounds)
    guard !localRect.isEmpty else { return }

    // Clear the selection area
    NSColor.clear.setFill()
    localRect.fill(using: .copy)

    // Та же рамка из скобок, что и у готового выделения (R27).
    drawSelectionBrackets(for: localRect)

    // Draw size indicator (show full screen-space dimensions, not clipped)
    let sizeText = "\(Int(screenRect.width)) x \(Int(screenRect.height))"
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 12, weight: .medium),
      .foregroundColor: NSColor.white,
    ]
    let textSize = sizeText.size(withAttributes: attributes)
    var textRect = CGRect(
      x: localRect.maxX - textSize.width - 8,
      y: localRect.minY - textSize.height - 8,
      width: textSize.width + 8,
      height: textSize.height + 4
    )
    if textRect.minY < 0 { textRect.origin.y = localRect.maxY + 4 }
    if textRect.maxX > bounds.maxX { textRect.origin.x = localRect.minX }

    NSColor.black.withAlphaComponent(0.7).setFill()
    NSBezierPath(roundedRect: textRect, xRadius: 4, yRadius: 4).fill()
    sizeText.draw(at: CGPoint(x: textRect.minX + 4, y: textRect.minY + 2), withAttributes: attributes)
  }
}

/// Геометрия рамки выделения записи и All-In-One по кадрам эталона (R27, R24):
/// audit-020/reference-recording-panel-desktop.png и spec-039-live/all-in-one-overlay-initial.png.
/// Толщина 8 px = 4 pt (2 pt наружу, 2 pt внутрь), плечо угла 35 px = 17,5 pt от внешнего края,
/// метка середины 34×8 px = 17×4 pt.
nonisolated enum RecordingSelectionBrackets {
  static let dimAlpha: CGFloat = 0.5
  static let thickness: CGFloat = 4
  static let cornerArmLength: CGFloat = 17.5
  static let edgeTickLength: CGFloat = 17
  static let outerCornerRadius: CGFloat = 1
  /// Тёмная кайма вокруг скобок: 2 px #080808 поверх 50 % затемнения.
  static let edgeShadowWidth: CGFloat = 1
  static let edgeShadowColor = NSColor.black.withAlphaComponent(0.3)

  /// Прямоугольники скобок: по два на угол и по одному на середину каждой стороны.
  static func rects(for rect: CGRect) -> [CGRect] {
    let half = thickness / 2
    let arm = cornerArmLength
    let outer = rect.insetBy(dx: -half, dy: -half)
    var result: [CGRect] = []
    for (x, alignRight) in [(outer.minX, false), (outer.maxX, true)] {
      for (y, alignTop) in [(outer.minY, false), (outer.maxY, true)] {
        let originX = alignRight ? x - arm : x
        let originY = alignTop ? y - arm : y
        // Горизонтальное плечо вдоль верхнего или нижнего края.
        result.append(CGRect(x: originX, y: alignTop ? y - thickness : y, width: arm, height: thickness))
        // Вертикальное плечо вдоль левого или правого края.
        result.append(CGRect(x: alignRight ? x - thickness : x, y: originY, width: thickness, height: arm))
      }
    }
    let tick = edgeTickLength
    result.append(CGRect(x: rect.midX - tick / 2, y: rect.maxY - half, width: tick, height: thickness))
    result.append(CGRect(x: rect.midX - tick / 2, y: rect.minY - half, width: tick, height: thickness))
    result.append(CGRect(x: rect.minX - half, y: rect.midY - tick / 2, width: thickness, height: tick))
    result.append(CGRect(x: rect.maxX - half, y: rect.midY - tick / 2, width: thickness, height: tick))
    return result
  }
}
