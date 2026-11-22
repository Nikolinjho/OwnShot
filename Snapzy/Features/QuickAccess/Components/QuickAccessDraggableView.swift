//
//  QuickAccessDraggableView.swift
//  Snapzy
//
//  Shared AppKit bridge for Quick Access gestures and History drag-to-app behavior.
//

import AppKit
import SwiftUI

enum QuickAccessCardDragIntent: Equatable {
  case undetermined
  case swipeToDismiss
  case dragToApp
  case reservedForScroll
}

enum QuickAccessDragScrollAxis: Equatable {
  case horizontal
  case vertical
}

struct QuickAccessCardDragPolicy {
  static let directionThreshold: CGFloat = 30
  static let directDragDistanceThreshold: CGFloat = 6
  static let scrollAxisDominanceRatio: CGFloat = 1.35
  static let dismissDistanceThreshold: CGFloat = 80
  static let dismissVelocityThreshold: CGFloat = 300

  static func shouldBeginDirectDrag(
    horizontalTranslation: CGFloat,
    verticalTranslation: CGFloat,
    reservedScrollAxis: QuickAccessDragScrollAxis? = nil
  ) -> Bool {
    guard horizontalTranslation.isFinite, verticalTranslation.isFinite else {
      return false
    }

    let distanceSquared =
      horizontalTranslation * horizontalTranslation + verticalTranslation * verticalTranslation
    guard distanceSquared >= directDragDistanceThreshold * directDragDistanceThreshold else {
      return false
    }

    return !isPrimaryScrollGesture(
      horizontalTranslation: horizontalTranslation,
      verticalTranslation: verticalTranslation,
      reservedScrollAxis: reservedScrollAxis
    )
  }

  static func isPrimaryScrollGesture(
    horizontalTranslation: CGFloat,
    verticalTranslation: CGFloat,
    reservedScrollAxis: QuickAccessDragScrollAxis?
  ) -> Bool {
    guard horizontalTranslation.isFinite,
          verticalTranslation.isFinite,
          let reservedScrollAxis else {
      return false
    }

    let distanceSquared =
      horizontalTranslation * horizontalTranslation + verticalTranslation * verticalTranslation
    guard distanceSquared >= directDragDistanceThreshold * directDragDistanceThreshold else {
      return false
    }

    let scrollTranslation: CGFloat
    let crossAxisTranslation: CGFloat
    switch reservedScrollAxis {
    case .horizontal:
      scrollTranslation = abs(horizontalTranslation)
      crossAxisTranslation = abs(verticalTranslation)
    case .vertical:
      scrollTranslation = abs(verticalTranslation)
      crossAxisTranslation = abs(horizontalTranslation)
    }

    // Let the containing list keep an unambiguous primary-axis drag. A
    // diagonal or cross-axis movement remains eligible for direct export.
    return scrollTranslation > crossAxisTranslation * Self.scrollAxisDominanceRatio
  }

  let dismissDirection: CGFloat

  func swipeTranslation(_ translation: CGFloat) -> CGFloat {
    guard translation.isFinite else { return 0 }
    return max(0, translation * dismissDirection) * dismissDirection
  }

  func intent(forHorizontalTranslation translation: CGFloat) -> QuickAccessCardDragIntent {
    guard abs(translation) > Self.directionThreshold else {
      return .undetermined
    }

    return translation * dismissDirection > 0 ? .swipeToDismiss : .dragToApp
  }

  func shouldDismiss(
    horizontalTranslation translation: CGFloat,
    horizontalVelocity velocity: CGFloat
  ) -> Bool {
    guard translation.isFinite, velocity.isFinite, translation * dismissDirection >= 0 else { return false }
    return translation * dismissDirection > Self.dismissDistanceThreshold
      || velocity * dismissDirection > Self.dismissVelocityThreshold
  }
}

nonisolated enum QuickAccessTrackpadSwipeHelpers {
  static let minimumHorizontalDelta: CGFloat = 0.5
  static let horizontalDominanceRatio: CGFloat = 1.35
  static let dismissDistanceThreshold: CGFloat = 80
  static let dismissVelocityThreshold: CGFloat = 300

  static func horizontalDelta(
    scrollingDeltaX deltaX: CGFloat,
    scrollingDeltaY deltaY: CGFloat,
    hasPreciseScrollingDeltas: Bool,
    sensitivityMultiplier: CGFloat
  ) -> CGFloat? {
    guard hasPreciseScrollingDeltas,
          deltaX.isFinite,
          deltaY.isFinite else {
      return nil
    }

    let horizontalMagnitude = abs(deltaX)
    let verticalMagnitude = abs(deltaY)
    guard horizontalMagnitude >= Self.minimumHorizontalDelta,
          horizontalMagnitude > verticalMagnitude * Self.horizontalDominanceRatio else {
      return nil
    }

    return deltaX * sensitivityMultiplier
  }

  /// Порог жеста двумя пальцами вниз, который временно прячет стек (swipe down у эталона)
  static let hideDistanceThreshold: CGFloat = 60

  /// Смещение пальцев вниз за событие или nil, если жест не вертикальный.
  /// С естественной прокруткой движение пальцев вниз даёт положительный scrollingDeltaY.
  static func downwardDelta(
    scrollingDeltaX deltaX: CGFloat,
    scrollingDeltaY deltaY: CGFloat,
    hasPreciseScrollingDeltas: Bool,
    isDirectionInverted: Bool
  ) -> CGFloat? {
    guard hasPreciseScrollingDeltas, deltaX.isFinite, deltaY.isFinite,
          abs(deltaY) >= Self.minimumHorizontalDelta,
          abs(deltaY) > abs(deltaX) * Self.horizontalDominanceRatio else {
      return nil
    }
    return isDirectionInverted ? deltaY : -deltaY
  }

  static func shouldDismiss(
    horizontalTranslation translation: CGFloat,
    horizontalVelocity velocity: CGFloat
  ) -> Bool {
    abs(translation) > Self.dismissDistanceThreshold || abs(velocity) > Self.dismissVelocityThreshold
  }
}

/// Transparent monitor view that lets SwiftUI keep normal hit testing while
/// AppKit owns the native drag session.
struct QuickAccessDraggableView: NSViewRepresentable {
  let fileURL: URL
  let thumbnail: NSImage
  let dismissDirection: CGFloat
  let dragDropEnabled: Bool
  let twoFingerSwipeToDismissEnabled: Bool
  let swipeMode: QuickAccessTrackpadSwipeMode
  let onDragStarted: () -> Void
  let onDragEnded: (Bool) -> Void
  var onDragEndedWithModifiers: ((Bool, NSEvent.ModifierFlags) -> Void)? = nil
  let onSwipeChanged: (CGFloat) -> Void
  let onSwipeEnded: (CGFloat, CGFloat) -> Void
  let swipeSensitivity: CGFloat
  let dragOnly: Bool
  let reservedScrollAxis: QuickAccessDragScrollAxis?
  /// Жест двумя пальцами вниз временно прячет стек
  var onSwipeDown: (() -> Void)? = nil
  var onTrackpadSwipe: ((QuickAccessSwipeDirection) -> Void)? = nil

  func makeNSView(context: Context) -> QuickAccessDragMonitorView {
    let view = QuickAccessDragMonitorView(
      fileURL: fileURL,
      thumbnail: thumbnail,
      dismissDirection: dismissDirection,
      dragDropEnabled: dragDropEnabled,
      twoFingerSwipeToDismissEnabled: twoFingerSwipeToDismissEnabled,
      swipeMode: swipeMode,
      swipeSensitivity: swipeSensitivity,
      onDragStarted: onDragStarted,
      onDragEnded: onDragEnded,
      onSwipeChanged: onSwipeChanged,
      onSwipeEnded: onSwipeEnded,
      dragOnly: dragOnly,
      reservedScrollAxis: reservedScrollAxis
    )
    view.onDragEndedWithModifiers = onDragEndedWithModifiers
    view.onSwipeDown = onSwipeDown
    view.onTrackpadSwipe = onTrackpadSwipe
    return view
  }

  func updateNSView(_ nsView: QuickAccessDragMonitorView, context: Context) {
    nsView.fileURL = fileURL
    nsView.thumbnail = thumbnail
    nsView.dismissDirection = dismissDirection
    nsView.dragDropEnabled = dragDropEnabled
    nsView.dragOnly = dragOnly
    nsView.reservedScrollAxis = reservedScrollAxis
    nsView.twoFingerSwipeToDismissEnabled = twoFingerSwipeToDismissEnabled
    nsView.swipeMode = swipeMode
    nsView.swipeSensitivity = swipeSensitivity
    nsView.onDragStarted = onDragStarted
    nsView.onDragEndedWithModifiers = onDragEndedWithModifiers
    nsView.onDragEnded = onDragEnded
    nsView.onSwipeChanged = onSwipeChanged
    nsView.onSwipeEnded = onSwipeEnded
    nsView.onSwipeDown = onSwipeDown
    nsView.onTrackpadSwipe = onTrackpadSwipe
  }
}

final class QuickAccessDragMonitorView: NSView, NSDraggingSource {
  var fileURL: URL
  var thumbnail: NSImage
  var dismissDirection: CGFloat
  var dragDropEnabled: Bool
  var dragOnly: Bool
  var reservedScrollAxis: QuickAccessDragScrollAxis?
  var twoFingerSwipeToDismissEnabled: Bool
  var swipeMode: QuickAccessTrackpadSwipeMode
  var swipeSensitivity: CGFloat
  var onDragStarted: () -> Void
  var onDragEnded: (Bool) -> Void
  var onDragEndedWithModifiers: ((Bool, NSEvent.ModifierFlags) -> Void)?
  var onSwipeChanged: (CGFloat) -> Void
  var onSwipeEnded: (CGFloat, CGFloat) -> Void
  var onSwipeDown: (() -> Void)?
  var onTrackpadSwipe: ((QuickAccessSwipeDirection) -> Void)?

  private var isDragging = false
  private var accumulatedSwipeDown: CGFloat = 0
  private var eventMonitor: Any?
  private var mouseDownLocation: NSPoint?
  private var mouseDownEvent: NSEvent?
  private var gestureIntent: QuickAccessCardDragIntent = .undetermined
  private var lastDragSample: (timestamp: TimeInterval, translation: CGFloat)?
  private var latestVelocity: CGFloat = 0
  private var didTriggerTrackpadSwipe = false
  private var ownsTrackpadGesture = false
  private var sourceAccess: SandboxFileAccessManager.ScopedAccess?

  init(
    fileURL: URL,
    thumbnail: NSImage,
    dismissDirection: CGFloat,
    dragDropEnabled: Bool,
    twoFingerSwipeToDismissEnabled: Bool,
    swipeMode: QuickAccessTrackpadSwipeMode,
    swipeSensitivity: CGFloat,
    onDragStarted: @escaping () -> Void,
    onDragEnded: @escaping (Bool) -> Void,
    onSwipeChanged: @escaping (CGFloat) -> Void,
    onSwipeEnded: @escaping (CGFloat, CGFloat) -> Void,
    dragOnly: Bool = false,
    reservedScrollAxis: QuickAccessDragScrollAxis? = nil
  ) {
    self.fileURL = fileURL
    self.thumbnail = thumbnail
    self.dismissDirection = dismissDirection
    self.dragDropEnabled = dragDropEnabled
    self.dragOnly = dragOnly
    self.reservedScrollAxis = reservedScrollAxis
    self.twoFingerSwipeToDismissEnabled = twoFingerSwipeToDismissEnabled
    self.swipeMode = swipeMode
    self.swipeSensitivity = swipeSensitivity
    self.onDragStarted = onDragStarted
    self.onDragEnded = onDragEnded
    self.onSwipeChanged = onSwipeChanged
    self.onSwipeEnded = onSwipeEnded

    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateEventMonitor()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  deinit {
    removeEventMonitor()
    sourceAccess?.stop()
  }

  // MARK: - Event Monitoring

  private func updateEventMonitor() {
    removeEventMonitor()
    guard window != nil else { return }

    eventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel]
    ) { [weak self] event in
      self?.handle(event) ?? event
    }
  }

  private func removeEventMonitor() {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
  }

  private func handle(_ event: NSEvent) -> NSEvent {
    guard event.window === window else { return event }

    switch event.type {
    case .leftMouseDown:
      beginTrackingIfNeeded(event)
    case .leftMouseDragged:
      continueTracking(event)
    case .leftMouseUp:
      endTracking(event)
    case .scrollWheel:
      handleScrollWheel(event)
    default:
      break
    }

    return event
  }

  private func beginTrackingIfNeeded(_ event: NSEvent) {
    guard !event.modifierFlags.contains(.control) else {
      resetTracking()
      return
    }

    let location = convert(event.locationInWindow, from: nil)
    guard bounds.contains(location) else { return }

    mouseDownLocation = location
    mouseDownEvent = event
    gestureIntent = .undetermined
    latestVelocity = 0
    lastDragSample = (event.timestamp, 0)
  }

  private func continueTracking(_ event: NSEvent) {
    guard let mouseDownLocation, !isDragging else { return }

    let location = convert(event.locationInWindow, from: nil)
    let translation = location.x - mouseDownLocation.x
    let verticalTranslation = location.y - mouseDownLocation.y
    updateVelocity(translation: translation, timestamp: event.timestamp)

    let policy = QuickAccessCardDragPolicy(dismissDirection: dismissDirection)
    if gestureIntent == .undetermined {
      if dragOnly {
        guard dragDropEnabled else {
          return
        }

        if QuickAccessCardDragPolicy.isPrimaryScrollGesture(
          horizontalTranslation: translation,
          verticalTranslation: verticalTranslation,
          reservedScrollAxis: reservedScrollAxis
        ) {
          gestureIntent = .reservedForScroll
          return
        }

        guard QuickAccessCardDragPolicy.shouldBeginDirectDrag(
          horizontalTranslation: translation,
          verticalTranslation: verticalTranslation,
          reservedScrollAxis: reservedScrollAxis
        ) else {
          return
        }

        gestureIntent = .dragToApp
        beginFileDrag()
        return
      }

      gestureIntent = policy.intent(forHorizontalTranslation: translation)

      if gestureIntent == .dragToApp {
        guard dragDropEnabled else { return }
        beginFileDrag()
        return
      }
    }

    guard gestureIntent != .reservedForScroll else { return }

    if gestureIntent == .swipeToDismiss {
      onSwipeChanged(policy.swipeTranslation(translation))
    }
  }

  private func endTracking(_ event: NSEvent) {
    guard let mouseDownLocation else {
      resetTracking()
      return
    }

    if gestureIntent == .swipeToDismiss {
      let location = convert(event.locationInWindow, from: nil)
      let translation = location.x - mouseDownLocation.x
      let policy = QuickAccessCardDragPolicy(dismissDirection: dismissDirection)
      if policy.shouldDismiss(horizontalTranslation: translation, horizontalVelocity: latestVelocity) {
        onSwipeEnded(policy.swipeTranslation(translation), latestVelocity)
      } else {
        onSwipeEnded(0, 0)
      }
    }

    resetTracking()
  }

  private func resetTracking() {
    mouseDownLocation = nil
    mouseDownEvent = nil
    gestureIntent = .undetermined
    lastDragSample = nil
    latestVelocity = 0
  }

  func handleScrollWheel(_ event: NSEvent) {
    if event.phase.contains(.began) {
      didTriggerTrackpadSwipe = false
      accumulatedSwipeDown = 0
      // После удаления карточки следующая может попасть под тот же указатель.
      // Продолжение жеста принадлежит только карточке, на которой он начался.
      ownsTrackpadGesture = containsEventLocation(event)
    }
    guard ownsTrackpadGesture, containsEventLocation(event), twoFingerSwipeToDismissEnabled, !isDragging,
          !event.phase.isEmpty, event.momentumPhase.isEmpty else { return }
    let disallowedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    guard event.modifierFlags.intersection(disallowedModifiers).isEmpty else { return }
    if event.phase.contains(.cancelled) {
      ownsTrackpadGesture = false
      accumulatedSwipeDown = 0
      return
    }
    if event.phase.contains(.ended) {
      ownsTrackpadGesture = false
      if !didTriggerTrackpadSwipe { finishSwipeDown() }
      return
    }
    guard !didTriggerTrackpadSwipe else { return }

    // В эталоне порог применяется к deltaX одного события, а не к накопленному
    // scrollingDeltaX. Уход начинается сразу и больше не следует за пальцем.
    let physicalDelta = event.deltaX * (event.isDirectionInvertedFromDevice ? 1 : -1)
    let delta = physicalDelta * (swipeMode == .natural ? 1 : -1) * swipeSensitivity
    if delta.isFinite, delta * dismissDirection > 0.5 {
      didTriggerTrackpadSwipe = true
      accumulatedSwipeDown = 0
      onTrackpadSwipe?(dismissDirection > 0 ? .right : .left)
      return
    }
    if abs(event.deltaX) < 0.5, onSwipeDown != nil,
       let down = QuickAccessTrackpadSwipeHelpers.downwardDelta(
         scrollingDeltaX: event.scrollingDeltaX,
         scrollingDeltaY: event.scrollingDeltaY,
         hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
         isDirectionInverted: event.isDirectionInvertedFromDevice) {
      accumulatedSwipeDown += down
    }
  }

  func containsEventLocation(_ event: NSEvent) -> Bool {
    let location = convert(event.locationInWindow, from: nil)
    return bounds.contains(location)
  }

  private func finishSwipeDown() {
    defer { accumulatedSwipeDown = 0 }
    guard accumulatedSwipeDown > QuickAccessTrackpadSwipeHelpers.hideDistanceThreshold else { return }
    onSwipeDown?()
  }

  private func updateVelocity(translation: CGFloat, timestamp: TimeInterval) {
    defer {
      lastDragSample = (timestamp, translation)
    }

    guard let lastDragSample else { return }
    let elapsed = timestamp - lastDragSample.timestamp
    guard elapsed > 0 else { return }

    latestVelocity = (translation - lastDragSample.translation) / CGFloat(elapsed)
  }

  // MARK: - Drag Initiation

  private func beginFileDrag() {
    guard !isDragging, fileURL.isFileURL, let mouseDownEvent, let mouseDownLocation else { return }

    sourceAccess = SandboxFileAccessManager.shared.beginAccessingURL(fileURL)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      sourceAccess?.stop()
      sourceAccess = nil
      resetTracking()
      return
    }

    isDragging = true
    onDragStarted()

    let dragItem = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
    let imageSize = NSSize(width: 120, height: 75)
    let dragImage = NSImage(size: imageSize)
    dragImage.lockFocus()
    thumbnail.draw(
      in: NSRect(origin: .zero, size: imageSize),
      from: .zero,
      operation: .sourceOver,
      fraction: 0.8
    )
    dragImage.unlockFocus()

    dragItem.setDraggingFrame(
      NSRect(
        x: mouseDownLocation.x - imageSize.width / 2,
        y: mouseDownLocation.y - imageSize.height / 2,
        width: imageSize.width,
        height: imageSize.height
      ),
      contents: dragImage
    )

    let session = beginDraggingSession(with: [dragItem], event: mouseDownEvent, source: self)
    session.animatesToStartingPositionsOnCancelOrFail = true
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Native file drag started",
      context: ["fileName": fileURL.lastPathComponent]
    )
  }

  // MARK: - NSDraggingSource

  func draggingSession(
    _ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    .copy
  }

  func draggingSession(
    _ session: NSDraggingSession,
    endedAt screenPoint: NSPoint,
    operation: NSDragOperation
  ) {
    isDragging = false
    let success = operation != []
    sourceAccess?.stop()
    sourceAccess = nil
    resetTracking()
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Native file drag ended",
      context: [
        "operation": "\(operation.rawValue)",
        "success": success ? "true" : "false",
      ]
    )
    if let onDragEndedWithModifiers {
      onDragEndedWithModifiers(success, NSEvent.modifierFlags)
    } else {
      onDragEnded(success)
    }
  }
}
