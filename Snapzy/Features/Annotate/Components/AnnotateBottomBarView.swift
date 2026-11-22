//
//  AnnotateBottomBarView.swift
//  Snapzy
//
//  Bottom bar with zoom, drag handle, and action buttons
//

import Darwin
import SwiftUI

private enum AnnotateBottomActionRegistration: Equatable {
  case annotateDefault
  case crop
  case cutOut
}

private enum AnnotateBottomBarMeasuredSide: Hashable {
  case left
  case right
}

private struct AnnotateBottomBarWidthPreferenceKey: PreferenceKey {
  static let defaultValue: [AnnotateBottomBarMeasuredSide: CGFloat] = [:]

  static func reduce(
    value: inout [AnnotateBottomBarMeasuredSide: CGFloat],
    nextValue: () -> [AnnotateBottomBarMeasuredSide: CGFloat]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
  }
}

private extension View {
  func measuredBottomBarWidth(_ side: AnnotateBottomBarMeasuredSide) -> some View {
    background(
      GeometryReader { geometry in
        Color.clear.preference(
          key: AnnotateBottomBarWidthPreferenceKey.self,
          value: [side: geometry.size.width]
        )
      }
    )
  }
}

/// Bottom bar containing zoom controls and action buttons
struct AnnotateBottomBarView: View {
  @ObservedObject var state: AnnotateState
  let eventRouter: AnnotateWindowEventRouter
  @ObservedObject private var cloudManager = CloudManager.shared
  @ObservedObject private var preferencesManager = PreferencesManager.shared
  @ObservedObject private var annotateShortcutManager = AnnotateShortcutManager.shared

  @State private var isCloudUploading = false
  @State private var cloudUploadProgress: Double = 0
  @State private var cloudUploadError: String?
  @State private var showCloudNotConfiguredAlert = false
  @State private var showOverwriteConfirmation = false
  @State private var measuredLeftWidth: CGFloat = 0
  @State private var measuredRightWidth: CGFloat = 0
  @State private var isZoomHovered = false
  @Environment(\.liquidGlassRenderMode) private var liquidGlassRenderMode
  @AppStorage(PreferencesKeys.useLiquidGlass) private var isLiquidGlassEnabled = true
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.controlActiveState) private var controlActiveState

  private let centeredDragFullWidth: CGFloat = AnnotateEditorBarMetrics.dragMeSize.width
  private let centeredDragCompactWidth: CGFloat = 44
  private let centeredDragHeight: CGFloat = AnnotateEditorBarMetrics.dragMeSize.height
  private let centeredDragSideGap: CGFloat = 12

  private var usesNativeGlass: Bool {
    LiquidGlassCapabilities.usesNativeGlass(
      for: liquidGlassRenderMode,
      userEnabled: isLiquidGlassEnabled
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      // Mockup preset bar (shown when mockup mode is active)
      if state.editorMode == .mockup {
        MockupPresetBarInline(state: state)
        Divider()
      }

      bottomBarContent
      .padding(.horizontal, 13)
      .padding(.vertical, 9.25)
      .animation(.easeInOut(duration: 0.16), value: activeActionRegistration)
      .onPreferenceChange(AnnotateBottomBarWidthPreferenceKey.self) { widths in
        measuredLeftWidth = widths[.left] ?? 0
        measuredRightWidth = widths[.right] ?? 0
      }

    }
    .background {
      // Фон как у тулбара; за пустое место панели окно перетаскивается (ANN-806, 810).
      ZStack {
        AnnotateEditorBarBackground(movesWindow: true)
        AnnotateEditorBarTint()
      }
      .ignoresSafeArea()
    }
    // Разделитель над панелью рисуется поверх общей линии окна, сдвинутой на 1 pt вверх (ANN-650).
    .overlay(alignment: .top) {
      AnnotateBottomBarSeparator(isActive: controlActiveState != .inactive, colorScheme: colorScheme)
        .offset(y: -1)
    }
    .overlay(alignment: .bottom) {
      ProgressView(value: cloudUploadProgress)
        .progressViewStyle(.linear)
        .frame(height: 3)
        .opacity(isCloudUploading ? 1 : 0)
    }
    .alert(L10n.AnnotateUI.cloudNotConfiguredTitle, isPresented: $showCloudNotConfiguredAlert) {
      Button(L10n.Common.ok, role: .cancel) {}
    } message: {
      Text(L10n.AnnotateUI.cloudNotConfiguredMessage)
    }
    .alert(L10n.AnnotateUI.overwriteCloudFileTitle, isPresented: $showOverwriteConfirmation) {
      Button(L10n.Common.overwrite) {
        handleCloudUpload()
      }
      .keyboardShortcut(.defaultAction)
      Button(L10n.Common.cancel, role: .cancel) {}
    } message: {
      Text(L10n.AnnotateUI.overwriteCloudFileMessage)
    }
    .onReceive(eventRouter.publisher(for: .annotateCloudUpload)) { _ in
      _ = OwnShotFeaturePolicy.allow(.cloud)
    }
  }

  // MARK: - Left Section

  private var bottomBarContent: some View {
    GeometryReader { geometry in
      let dragWidth = centeredDragWidth(for: geometry.size.width)

      ZStack {
        HStack(spacing: 0) {
          // Left section: zoom + mode toggle
          leftSection
            .fixedSize(horizontal: true, vertical: false)
            .measuredBottomBarWidth(.left)

          Spacer(minLength: 0)

          // Right section: registered action surface
          registeredActionSurface
            .fixedSize(horizontal: true, vertical: false)
            .measuredBottomBarWidth(.right)
        }

        // Center: Drag handle pinned to true bar center. If the bar gets too
        // tight, it compacts before hiding so side controls stay clickable.
        if state.hasImage && activeActionRegistration == .annotateDefault && dragWidth > 0 {
          dragHandle(
            width: dragWidth,
            isCompact: dragWidth < centeredDragFullWidth
          )
          .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
      }
    }
    .frame(height: centeredDragHeight)
  }

  private var leftSection: some View {
    HStack(spacing: 10) {
      zoomPicker
      if activeActionRegistration == .crop {
        Toggle("Snap to edges", isOn: $state.isCropEdgeSnappingEnabled)
          .toggleStyle(.checkbox)
          .help(CropEdgeSnapping.commandHint(enabled: state.isCropEdgeSnappingEnabled))
        Text(CropEdgeSnapping.commandHint(enabled: state.isCropEdgeSnappingEnabled))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
      }
    }
  }

  private func centeredDragWidth(for contentWidth: CGFloat) -> CGFloat {
    guard contentWidth > 0 else { return centeredDragFullWidth }

    let halfWidth = contentWidth / 2
    let leftClearance = halfWidth - measuredLeftWidth - centeredDragSideGap
    let rightClearance = halfWidth - measuredRightWidth - centeredDragSideGap
    let availableCenteredWidth = max(0, min(leftClearance, rightClearance) * 2)

    if availableCenteredWidth >= centeredDragFullWidth {
      return centeredDragFullWidth
    }

    if availableCenteredWidth >= centeredDragCompactWidth {
      return centeredDragCompactWidth
    }

    return 0
  }

  // MARK: - Zoom Picker

  private var zoomShape: Capsule {
    Capsule(style: .continuous)
  }

  private var zoomPicker: some View {
    // Состав как у меню масштаба эталона (evidence/spec-051-pairs/reference-dark/editor/editor-popup-zoom-full.png):
    // Zoom In ⌘+, Zoom Out ⌘−, Fit Canvas ⌘1, затем 50%, 100% ⌘0, 200%, 400%. Галочки нет.
    Menu {
      Button(L10n.AnnotateUI.zoomIn) {
        withAnimation(.easeOut(duration: 0.15)) { state.zoomIn() }
      }.keyboardShortcut("+", modifiers: .command)
      Button(L10n.AnnotateUI.zoomOut) {
        withAnimation(.easeOut(duration: 0.15)) { state.zoomOut() }
      }.keyboardShortcut("-", modifiers: .command)

      Divider()

      Button(L10n.AnnotateUI.fitCanvas) {
        withAnimation(.easeOut(duration: 0.15)) {
          state.zoomLevel = 1.0
        }
      }.keyboardShortcut("1", modifiers: .command)

      Divider()

      ForEach(AnnotateState.zoomMenuPercents, id: \.self) { percent in
        if percent == 100 {
          Button("\(percent)%") {
            withAnimation(.easeOut(duration: 0.15)) {
              state.zoomLevel = state.zoomLevel(forDisplayedPercent: percent)
            }
          }.keyboardShortcut("0", modifiers: .command)
        } else {
          Button("\(percent)%") {
            withAnimation(.easeOut(duration: 0.15)) {
              state.zoomLevel = state.zoomLevel(forDisplayedPercent: percent)
            }
          }
        }
      }

      Divider()
      ForEach(AnnotateState.EditorMode.allCases, id: \.self) { mode in
        Button(modeTitle(for: mode)) { state.editorMode = mode }
      }
    } label: {
      HStack(spacing: 9) {
        Text("\(state.currentDisplayedZoomPercent)%")
          .font(.system(size: 13))
        OwnShotSymbols.image("annotateChevron").renderingMode(.template).accessibilityHidden(true)
      }
      .foregroundStyle(controlActiveState == .inactive && colorScheme == .dark
        ? OwnShotEditorChrome.color(0xEEEDED) : Color.primary)
      .frame(width: 70, height: 26)
      .contentShape(zoomShape)
      .modifier(OwnShotEditorCapsule(isActive: isZoomHovered))
      .onHover { hovering in
        withAnimation(LiquidGlassTokens.hoverSpring) {
          isZoomHovered = hovering
        }
      }
      .animation(LiquidGlassTokens.hoverSpring, value: isZoomHovered)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .ownShotNonFocusable()
    .fixedSize(horizontal: true, vertical: false)
  }

  // MARK: - Mode Toggle

  /// Check if any mockup transforms have been applied
  private var hasMockupTransforms: Bool {
    state.mockupRotationX != 0 ||
    state.mockupRotationY != 0 ||
    state.mockupRotationZ != 0
  }

  private var modeToggle: some View {
    LiquidGlassSegmentedControl(
      items: AnnotateState.EditorMode.allCases,
      selection: $state.editorMode,
      activeGlassTint: nil,
      controlHeight: ControlMetrics.bottomBarControl
    ) { mode in
      HStack(spacing: 5) {
        Image(systemName: modeIcon(for: mode))
          .font(.system(size: 11, weight: .medium))
        Text(modeTitle(for: mode))
          .lineLimit(1)
      }
      .help(modeTitle(for: mode))
    }
  }

  private func modeIcon(for mode: AnnotateState.EditorMode) -> String {
    switch mode {
    case .annotate:
      return "pencil.and.outline"
    case .mockup:
      return "cube.transparent"
    case .preview:
      return "eye"
    }
  }

  private func modeTitle(for mode: AnnotateState.EditorMode) -> String {
    switch mode {
    case .annotate:
      return L10n.AnnotateUI.modeAnnotate
    case .mockup:
      return L10n.AnnotateUI.modeMockup
    case .preview:
      return L10n.AnnotateUI.modePreview
    }
  }

  // MARK: - Drag Handle (Liquid Glass)

  @State private var isDragHovering = false

  private func dragHandle(width: CGFloat, isCompact: Bool) -> some View {
    let dragState = state.dragToAppPreparationState
    let isPreparing = dragState == .preparing
    let isReady = dragState == .ready
    let isLit = isPreparing || (isReady && isDragHovering)

    return AnnotateDragHandleView(state: state)
      .frame(width: width, height: centeredDragHeight)
      .overlay {
        HStack(spacing: isCompact ? 8 : 10) {
          if isPreparing {
            ProgressView()
              .controlSize(.small)
              .scaleEffect(0.7)
          } else if isCompact {
            dragGrip
          } else {
            dragGrip

            Text("Drag Me")
              .font(.system(size: 13))

            dragGrip
          }
        }
        .foregroundColor(controlActiveState == .inactive && colorScheme == .dark
          ? OwnShotEditorChrome.color(0xB8B7B7) : dragInk(for: dragState))
        .allowsHitTesting(false)
      }
      .background(dragMeFill(isLit: isLit), in: Capsule())
      .overlay(Capsule().strokeBorder(controlActiveState == .inactive && colorScheme == .dark
        ? OwnShotEditorChrome.color(0x62605F) : Color.primary.opacity(colorScheme == .light ? 0.1 : 0.2), lineWidth: 0.5))
      // Rule 2: scale, not opacity — a transform never detaches the glass backdrop.
      .scaleEffect(isLit ? 1.02 : 1)
      .onHover { hovering in
        withAnimation(LiquidGlassTokens.hoverSpring) {
          isDragHovering = hovering
        }
      }
      .animation(LiquidGlassTokens.hoverSpring, value: dragState)
      .animation(LiquidGlassTokens.hoverSpring, value: isDragHovering)
      .help(L10n.AnnotateUI.dragToAppHelp)
  }

  /// Drag Me эталона: светлая #FDFDFD с тонкой обводкой, в тёмной теме белый 10 % (ANN-811).
  private func dragMeFill(isLit: Bool) -> Color {
    if controlActiveState == .inactive && colorScheme == .dark { return OwnShotEditorChrome.color(0x3A3837) }
    if colorScheme == .dark {
      return Color.white.opacity(AnnotateEditorBarMetrics.darkDragMeWhiteOpacity + (isLit ? 0.06 : 0))
    }
    return isLit ? OwnShotEditorChrome.color(0xF2F2F2) : OwnShotEditorChrome.color(AnnotateEditorBarMetrics.lightDragMeColor)
  }

  private var dragGrip: some View {
    VStack(spacing: 3) {
      ForEach(0..<3, id: \.self) { _ in
        Capsule(style: .continuous)
          .fill(LiquidGlassTokens.inkBody.opacity(0.5))
          .frame(width: 7, height: 1.3)
      }
    }
    .frame(width: 10)
  }

  private func dragInk(for state: AnnotateState.DragToAppPreparationState) -> Color {
    switch state {
    case .ready:
      return isDragHovering ? LiquidGlassTokens.inkPrimary : LiquidGlassTokens.inkBody
    case .preparing:
      return LiquidGlassTokens.inkPrimary
    case .unavailable:
      return LiquidGlassTokens.inkFaint
    }
  }

  // MARK: - Action Buttons

  private var activeActionRegistration: AnnotateBottomActionRegistration {
    // Specialized tools can register a replacement for the default Annotate actions here.
    if state.selectedTool == .crop && state.isCropActive {
      return .crop
    }
    if state.selectedTool == .cutOut && state.isCutOutActive {
      return .cutOut
    }

    return .annotateDefault
  }

  @ViewBuilder
  private var registeredActionSurface: some View {
    switch activeActionRegistration {
    case .annotateDefault:
      annotateActionButtons
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    case .crop:
      HStack(spacing: 12) {
        // У эталона после изменения рамки в footer появляется Revert to Original.
        if state.canRevertCropToOriginal {
          Button(L10n.AnnotateUI.revertToOriginal) { state.revertCropToOriginalBounds() }
            .buttonStyle(.bordered)
            .ownShotNonFocusable()
        }
      }
    case .cutOut:
      CutOutToolbarView(state: state)
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }
  }

  private var annotateActionButtons: some View {
    let togglePinShortcut = annotateShortcutManager.isActionShortcutEnabled(for: .togglePin)
      ? annotateShortcutManager.togglePinShortcut?.displayString : nil
    let copyAndCloseShortcut = annotateShortcutManager.isActionShortcutEnabled(for: .copyAndClose)
      ? annotateShortcutManager.copyAndCloseShortcut?.displayString : nil

    return HStack(spacing: 6) {
      OwnShotEditorBottomButton(icon: "square.and.arrow.up", tooltip: L10n.Common.share) {
        share()
      }

      OwnShotEditorBottomButton(
        icon: "pin",
        tooltip: tooltipText(L10n.AnnotateUI.pinToScreen, shortcut: togglePinShortcut)
      ) {
        pin()
      }

      OwnShotEditorBottomButton(
        icon: "doc.on.doc",
        tooltip: tooltipText(L10n.AnnotateUI.copyToClipboard, shortcut: copyAndCloseShortcut)
      ) {
        copyToClipboard()
      }

      OwnShotEditorBottomButton(icon: "icloud.and.arrow.up", tooltip: "Cloud") {
        _ = OwnShotFeaturePolicy.allow(.cloud)
      }

      // Send to Raycast AI Chat (⌘R): у эталона только при установленном Raycast, здесь заглушка.
      if OwnShotRaycastStub.isMenuVisible {
        OwnShotEditorBottomButton(
          icon: "bubble.left.and.bubble.right",
          tooltip: tooltipText(L10n.PersonalBuildStubs.sendToRaycastAIChat, shortcut: "⌘R")
        ) {
          OwnShotRaycastStub.send()
        }
      }

    }
    .contextMenu {
      Button("New Window") { AnnotateManager.shared.openEmptyAnnotation() }
      Button("Delete", role: .destructive) { confirmAndDeleteImage() }.disabled(state.sourceURL == nil)
    }
    // One effect container for the whole row: the glass is evaluated in a single pass instead of
    // once per button, and neighbours merge when they light up together.
    .liquidGlassGroup(spacing: Spacing.xs)
  }

  private func tooltipText(_ title: String, shortcut: String?) -> String {
    guard let shortcut else { return title }
    return L10n.Common.withShortcut(title, shortcut)
  }

  // MARK: - Actions

  private func share() {
    guard let window = NSApp.keyWindow, let contentView = window.contentView else { return }
    AnnotateExporter.share(state: state, from: contentView)
  }

  /// Кнопка и сочетание идут одним путём: контроллер закрепляет рендер на экране.
  private func pin() {
    guard let window = NSApp.keyWindow else { return }
    NotificationCenter.default.post(name: .annotateTogglePin, object: window)
  }

  private func copyToClipboard() {
    guard let window = NSApp.keyWindow else { return }
    // Post notification so the controller handles save + cache + copy
    // Кнопка остаётся «Copy & Close»: копирует и закрывает редактор.
    NotificationCenter.default.post(
      name: .annotateCopyAndClose,
      object: window,
      userInfo: AnnotateCopyCompletionPolicy.userInfo(for: .bottomBarButton)
    )
  }

  private func confirmAndDeleteImage() {
    guard let sourceURL = state.sourceURL,
          let window = NSApp.keyWindow else { return }

    let fileAccessManager = SandboxFileAccessManager.shared
    let confirmation: DeleteConfirmation
    do {
      confirmation = try fileAccessManager.withScopedAccess(to: sourceURL) {
        try DeleteConfirmation(at: sourceURL)
      }
    } catch {
      reportDeletionFailure(error, for: sourceURL)
      return
    }

    let alert = NSAlert()
    alert.messageText = L10n.AnnotateUI.deleteScreenshotTitle
    alert.informativeText = L10n.AnnotateUI.deleteScreenshotMessage(sourceURL.lastPathComponent)
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.Common.deleteAction)
    alert.addButton(withTitle: L10n.Common.cancel)

    alert.beginSheetModal(for: window) { [state] response in
      guard response == .alertFirstButtonReturn else { return }

      let fileAccess = fileAccessManager.beginAccessingURL(sourceURL)
      let directoryAccess = fileAccessManager.beginAccessingURL(sourceURL.deletingLastPathComponent())
      defer {
        fileAccess.stop()
        directoryAccess.stop()
      }

      do {
        try Self.deleteConfirmedScreenshot(
          confirmation,
          state: state,
          trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
          removeReferences: {
            CaptureHistoryStore.shared.removeByFilePath(sourceURL.path)
            AnnotationSessionStore.shared.deleteSession(for: sourceURL)
            if let itemId = state.quickAccessItemId {
              QuickAccessManager.shared.removeItem(id: itemId)
            }
          },
          close: { window.close() }
        )
      } catch {
        reportDeletionFailure(error, for: sourceURL)
      }
    }
  }

  private func reportDeletionFailure(_ error: Error, for sourceURL: URL) {
    DiagnosticLogger.shared.logError(
      .fileAccess, error, "Annotate Delete failed", context: ["fileName": sourceURL.lastPathComponent]
    )
    AppToastManager.shared.show(message: error.localizedDescription, style: .warning)
  }

  struct DeleteConfirmation: Equatable {
    let sourceURL: URL
    private let device: dev_t
    private let inode: ino_t
    private let createdSeconds: Int
    private let createdNanoseconds: Int

    init(at sourceURL: URL) throws {
      let info = try sourceURL.withUnsafeFileSystemRepresentation { path in
        guard let path else { throw POSIXError(.EINVAL) }
        var info = stat()
        // Trash should act on the approved directory entry, including a leaf symlink.
        guard lstat(path, &info) == 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT != S_IFDIR else { throw POSIXError(.EISDIR) }
        return info
      }
      self.sourceURL = sourceURL
      device = info.st_dev
      inode = info.st_ino
      createdSeconds = info.st_birthtimespec.tv_sec
      createdNanoseconds = info.st_birthtimespec.tv_nsec
    }
  }

  @MainActor
  static func deleteConfirmedScreenshot(
    _ confirmation: DeleteConfirmation,
    state: AnnotateState,
    trash: (URL) throws -> Void,
    removeReferences: () -> Void,
    close: () -> Void
  ) throws {
    let sourceURL = confirmation.sourceURL
    guard state.sourceURL == sourceURL, try DeleteConfirmation(at: sourceURL) == confirmation else { return }

    try trash(sourceURL)
    removeReferences()
    state.hasUnsavedChanges = false
    close()
  }

  // MARK: - Cloud Upload

  /// Write a rendered image to a temporary PNG file inside the sandbox temp directory.
  /// Used to upload manual combine sessions without overwriting the user's source file.
  private func writeRenderedImageToTemporaryFile(_ image: NSImage) -> URL? {
    guard let data = AnnotateExporter.imageData(from: image, for: "png") else { return nil }
    // UUID-suffixed so concurrent uploads from multiple windows never collide on the path
    // (the per-Task defer cleanup would otherwise delete another window's in-flight file).
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("combined-\(UUID().uuidString).png")
    do {
      try data.write(to: tempURL, options: .atomic)
      return tempURL
    } catch {
      DiagnosticLogger.shared.logError(.cloud, error, "Annotate temp render write failed")
      return nil
    }
  }

  private func handleCloudUpload() {
    guard cloudManager.isConfigured else {
      DiagnosticLogger.shared.log(.warning, .cloud, "Annotate cloud upload skipped; cloud not configured")
      showCloudNotConfiguredAlert = true
      return
    }

    guard let sourceURL = state.sourceURL else {
      DiagnosticLogger.shared.log(.warning, .cloud, "Annotate cloud upload skipped; source URL missing")
      return
    }

    // Step 1: Render flattened image with annotations BEFORE uploading
    let sessionSnapshot = AnnotateManager.shared.makeSessionData(for: state)
    let renderedImage = AnnotateExporter.renderFinalImage(state: state)

    // Step 2: Decide the upload target. Manual combine sessions must NOT overwrite the
    // user's picked source file with the stitched render, so upload a temporary rendered
    // copy instead and leave the source untouched.
    let isProtectedManualCombine = state.isCombineMode && state.isManualImportSession
    let uploadURL: URL
    if isProtectedManualCombine {
      guard let renderedImage, let tempURL = writeRenderedImageToTemporaryFile(renderedImage) else {
        DiagnosticLogger.shared.log(.error, .cloud, "Annotate cloud upload skipped; temp render failed")
        cloudUploadError = L10n.AnnotateUI.saveFailedMessage
        return
      }
      uploadURL = tempURL
    } else {
      uploadURL = sourceURL
      // Save rendered image to disk (so the file includes annotations)
      if let renderedImage = renderedImage {
        let didSave = AnnotateExporter.saveToFile(image: renderedImage, state: state)
        if didSave,
           let sessionSnapshot,
           AnnotationSessionStore.shared.shouldPersist(for: sourceURL) {
          AnnotationSessionStore.shared.persist(sessionSnapshot, for: sourceURL)
        }
      }
    }

    isCloudUploading = true
    cloudUploadProgress = 0
    DiagnosticLogger.shared.log(
      .info,
      .cloud,
      "Annotate cloud upload started",
      context: ["fileName": sourceURL.lastPathComponent, "hasOldCloudKey": state.cloudKey == nil ? "false" : "true"]
    )

    // Animate to 80% quickly to show activity
    withAnimation(.easeOut(duration: 0.4)) {
      cloudUploadProgress = 0.8
    }

    let uploadStartTime = Date()
    let oldCloudKey = state.cloudKey  // Save old key for cleanup after successful upload

    Task {
      // Remove the temporary rendered file (manual combine) once the upload finishes,
      // whether it succeeds or fails.
      defer {
        if isProtectedManualCombine {
          try? FileManager.default.removeItem(at: uploadURL)
        }
      }
      do {
        let fileAccess = SandboxFileAccessManager.shared.beginAccessingURL(uploadURL)
        defer { fileAccess.stop() }

        // Always upload with a fresh key (new URL avoids CDN cache issues)
        let result = try await cloudManager.upload(fileURL: uploadURL)

        // Delete the old cloud file in background (no garbage)
        if let oldKey = oldCloudKey {
          Task.detached(priority: .utility) {
            do {
              try await CloudManager.shared.deleteByKey(key: oldKey)
            } catch {
              DiagnosticLogger.shared.logError(.cloud, error, "Annotate old cloud object cleanup failed")
            }
          }
        }

        // Store cloud URL and key on state
        state.cloudURL = result.publicURL
        state.cloudKey = result.key

        // Auto-copy cloud link
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(result.publicURL.absoluteString, forType: .string)

        // Ensure minimum visual duration (~600ms total)
        let elapsed = Date().timeIntervalSince(uploadStartTime)
        let remainingDelay = max(0, 0.6 - elapsed)

        withAnimation(.easeIn(duration: 0.15)) {
          cloudUploadProgress = 1.0
        }

        if remainingDelay > 0 {
          try? await Task.sleep(nanoseconds: UInt64(remainingDelay * 1_000_000_000))
        }

        isCloudUploading = false
        SoundManager.play("Pop")

        // Update QuickAccess thumbnail and mark as saved
        state.markAsSaved()
        state.isCloudStale = false
        if let itemId = state.quickAccessItemId {
          if let renderedImage = renderedImage {
            QuickAccessManager.shared.updateItemThumbnail(id: itemId, image: renderedImage)
          }
          // Set cloud URL AFTER thumbnail update to ensure isCloudStale = false
          QuickAccessManager.shared.setCloudURL(id: itemId, url: result.publicURL, key: result.key)
        }
        DiagnosticLogger.shared.log(
          .info,
          .cloud,
          "Annotate cloud upload completed",
          context: ["fileName": sourceURL.lastPathComponent]
        )

        // Close window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
          NSApp.keyWindow?.close()
        }
      } catch {
        isCloudUploading = false
        cloudUploadProgress = 0
        cloudUploadError = error.localizedDescription
        DiagnosticLogger.shared.logError(
          .cloud,
          error,
          "Annotate cloud upload failed",
          context: ["fileName": sourceURL.lastPathComponent]
        )
      }
    }
  }
}

private struct OwnShotEditorBottomButton: View {
  let icon: String
  let tooltip: String
  let action: () -> Void
  @State private var isHovered = false
  @Environment(\.controlActiveState) private var controlActiveState
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Button(action: action) {
      // Глиф в неактивном окне не тускнеет: #E5E5E5 в тёмной теме в обоих состояниях
      // (R15, spec-050-visual/dark/editor-idle-on-000000.png и
      // spec-051-pairs/reference-dark/editor-inactive-on-000000.png).
      OwnShotSymbols.image(resourceName).renderingMode(.template)
        .foregroundStyle(Color.primary)
        .frame(width: 36, height: 26)
        .modifier(OwnShotEditorCapsule(isActive: isHovered))
    }
    .buttonStyle(.plain)
    .ownShotNonFocusable()
    .onHover { isHovered = $0 }
    .help(tooltip)
    .accessibilityLabel(tooltip)
  }

  private var resourceName: String {
    switch icon {
    case "square.and.arrow.up": "annotateShare"
    case "pin", "pin.fill": "annotatePin"
    case "doc.on.doc": "annotateCopy"
    default: "annotateCloud"
    }
  }
}

/// Разделитель над нижней панелью. У эталона в светлой теме это линия 1 pt цвета 230
/// (#E6E6E6) и под ней волосяная линия в 1 физический пиксель: 205 (#CDCDCD) в активном
/// окне, в неактивном она бледнеет до 230 и сливается с линией (spec-063-live/
/// ref-bottombar-*-on-808080.png). Тёмную тему рисует `AnnotateEditorDivider` (R11).
struct AnnotateBottomBarSeparator: View {
  let isActive: Bool
  let colorScheme: ColorScheme
  @Environment(\.displayScale) private var displayScale

  /// Цвета светлой темы: линия 1 pt и волосяная линия по состоянию окна.
  static func lightColors(isActive: Bool) -> (line: UInt32, hairline: UInt32) {
    (0xE6E6E6, isActive ? 0xCDCDCD : 0xE6E6E6)
  }

  var body: some View {
    let hairline = 1 / max(displayScale, 1)
    ZStack(alignment: .bottom) {
      if colorScheme == .dark {
        // Обе половины тёмного разделителя рисует AnnotateEditorDivider в AnnotateMainView:
        // полупрозрачная половина должна лежать прямо на прозрачном окне, а не на линии.
        Color.clear
      } else {
        let colors = Self.lightColors(isActive: isActive)
        Rectangle().fill(OwnShotEditorChrome.color(colors.line))
        Rectangle().fill(OwnShotEditorChrome.color(colors.hairline)).frame(height: hairline)
      }
    }
    .frame(height: 1)
    .frame(maxWidth: .infinity)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Разделитель между панелью и холстом, 1 pt (spec-066 R11). В тёмной теме это две
/// волосяные линии: со стороны холста непрозрачная #4C4A49, со стороны панели в активном
/// окне – #535251 с alpha панели ≈0,814, она просвечивает как сама панель: #444342 на чёрном
/// и #737271 на белом (spec-050-visual/dark/editor-idle-on-000000.png и -on-FFFFFF.png,
/// строки 221–222 под тулбаром и 1017–1018 над нижней панелью). В неактивном окне обе
/// половины #4C4A49 (spec-051-pairs/reference-dark/editor-inactive-on-000000.png).
/// Светлая тема остаётся системной separatorColor (#E6E6E6, совпадает с эталоном).
struct AnnotateEditorDivider: View {
  /// С какой стороны разделителя панель: сверху для тулбара, снизу для нижней панели.
  enum BarEdge { case top, bottom }

  let barEdge: BarEdge
  let isActive: Bool
  let colorScheme: ColorScheme

  /// Линия окна в тёмной теме – непрозрачная #4C4A49 в обоих состояниях.
  static let darkLineColor: UInt32 = 0x4C4A49
  /// Половина со стороны активной тёмной панели: #535251 с alpha панели.
  static let darkActiveBarHairlineColor: UInt32 = 0x535251
  static let darkActiveBarHairlineAlpha: CGFloat = AnnotateEditorBarMetrics.darkBarAlpha

  /// Тон половины со стороны панели поверх фона `backdrop` (0…255), для сверки с кадрами.
  static func darkBarHairlineValue(isActive: Bool, over backdrop: CGFloat) -> CGFloat {
    guard isActive else { return CGFloat((darkLineColor >> 16) & 255) }
    return AnnotateEditorBarMetrics.composite(barColor: CGFloat((darkActiveBarHairlineColor >> 16) & 255),
      alpha: darkActiveBarHairlineAlpha, over: backdrop)
  }

  var body: some View {
    if colorScheme == .dark {
      VStack(spacing: 0) {
        if barEdge == .top {
          barHairline
          lineHairline
        } else {
          lineHairline
          barHairline
        }
      }
      .frame(height: 1)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    } else {
      Rectangle().fill(Color(nsColor: .separatorColor))
        .frame(height: 1)
    }
  }

  private var lineHairline: some View {
    Rectangle().fill(OwnShotEditorChrome.color(Self.darkLineColor))
  }

  private var barHairline: some View {
    Rectangle().fill(isActive
      ? OwnShotEditorChrome.color(Self.darkActiveBarHairlineColor).opacity(Self.darkActiveBarHairlineAlpha)
      : OwnShotEditorChrome.color(Self.darkLineColor))
  }
}
