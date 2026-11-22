//
//  QuickAccessCardView.swift
//  Snapzy
//
//  Single quick access card with swipe-to-dismiss and drag-to-external-app
//  Direction-based gesture handling: swipe toward edge = dismiss, drag away = external app
//

import AppKit
import SwiftUI

/// Displays a single item preview with hover-activated actions and swipe gestures
struct QuickAccessCardView: View {
  let item: QuickAccessItem
  let manager: QuickAccessManager
  var onHover: ((Bool) -> Void)? = nil

  @ObservedObject private var preferencesManager = PreferencesManager.shared
  @ObservedObject private var actionConfiguration = QuickAccessActionConfigurationStore.shared
  @ObservedObject private var actionShortcuts = QuickAccessActionShortcutStore.shared
  @ObservedObject private var trackpadSwipeModeStore = QuickAccessTrackpadSwipeModeStore.shared
  @ObservedObject private var swipeActionStore = QuickAccessSwipeActionStore.shared
  @ObservedObject private var cloudManager = CloudManager.shared
  @State private var isHovering = false
  @State private var isDragging = false
  @State private var isSwiping = false
  @State private var isDismissing = false
  @State private var isDeleting = false
  @State private var swipeOffset: CGFloat = 0
  @State private var isCloudUploading = false
  @State private var cloudUploadProgress: Double = 0
  /// Есть ли в записи звуковая дорожка (значок popupWithSound у эталона)
  @State private var hasSound = false
  /// Множитель Retina файла для пункта Scale Retina to 1x, читается один раз на версию снимка
  @State private var retinaScale: CGFloat?
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) var reduceMotion

  private let cornerRadius = QuickAccessLayout.cardCornerRadius

  /// Scaled card dimensions based on overlay scale setting
  private var scaledWidth: CGFloat { QuickAccessLayout.scaledCardWidth(CGFloat(manager.overlayScale)) }
  private var scaledHeight: CGFloat { QuickAccessLayout.scaledCardHeight(CGFloat(manager.overlayScale)) }

  /// Dismiss direction based on panel position
  /// Right side panel: swipe right to dismiss (+1)
  /// Left side panel: swipe left to dismiss (-1)
  private var dismissDirection: CGFloat {
    manager.position.isLeftSide ? -1 : 1
  }

  private var previewContent: some View {
    ZStack(alignment: .center) {
      thumbnailLayer

      // Pin indicator (pinned items when pin action is NOT assigned to a slot)
      if item.isPinned, !isPinActionOnCard {
        pinIndicator
      }

      // Инфо-плашка записи: тип файла, звук и длительность (videos only, bottom-right)
      if item.isVideo, !(isHovering && canPerformCardActions) {
        videoInfoPlate
      }

      // Processing progress overlay
      if item.processingState != .idle {
        QuickAccessProgressView(
          state: item.processingState,
          onCancel: manager.canCancelProcessing(id: item.id) ? { manager.cancelProcessing(id: item.id) } : nil
        )
          .transition(.opacity)
      }

      // Cloud upload progress overlay
      if isCloudUploading {
        QuickAccessProgressView(state: .processing(progress: cloudUploadProgress))
          .transition(.opacity)
      }

      // Hover overlay with staggered buttons (hidden while swiping so it does not
      // visually fight the swipe gesture).
      if showsHoverChrome {
        hoverOverlay
          .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95)))
      }

      // Corner buttons (only visible on hover, hidden during cloud upload and swipe).
      if showsHoverChrome && !cornerOverlayActions.isEmpty {
        cornerButtons
      }
    }
  }

  var body: some View {
    Group {
      if item.isVideo, case .processing(let progress) = item.processingState {
        QuickAccessGIFProgressView(progress: progress,
          onCancel: manager.canCancelProcessing(id: item.id) ? { manager.cancelProcessing(id: item.id) } : nil)
      } else {
        previewContent
      }
    }
    .frame(width: scaledWidth, height: scaledHeight)
    .clipShape(cardShape)
    .contentShape(cardShape)
    .background(
      cardShape
        .fill(Color.black.opacity(0.1))
    )
    // GPU-cached drop shadow (furthest back). Replaces per-frame SwiftUI `.shadow()`
    // blur that lagged when many stacked cards recomposited during capture-area mode.
    .background(QuickAccessCardShadowView(cornerRadius: cornerRadius))
    .overlay(
      cardShape
        .stroke(Color.white.opacity(0.2), lineWidth: 1)
    )
    .opacity(cardOpacity)
    .offset(x: reduceMotion ? 0 : swipeOffset)
    .onHover { hovering in
      withAnimation(QuickAccessAnimations.hoverOverlay) {
        isHovering = hovering
      }
      onHover?(hovering)

      // Arms/disarms the card action shortcuts for this card.
      manager.setHoveredItem(id: item.id, hovering: hovering)

      // Pause/resume countdown on hover if enabled
      if manager.pauseCountdownOnHover {
        if hovering {
          manager.pauseCountdown(for: item.id)
        } else {
          manager.resumeCountdown(for: item.id)
        }
      }
    }
    .onTapGesture(count: 2) {
      handleDoubleClick()
    }
    .background(
      QuickAccessContextMenuPresenter(entries: quickAccessContextMenuEntries)
        .frame(width: scaledWidth, height: scaledHeight)
    )
    .overlay {
      if !item.processingState.isProcessing && !isDeleting {
        dragInteractionBridge.frame(width: scaledWidth, height: scaledHeight)
      }
    }
    .onDisappear {
      isDragging = false
      isHovering = false
      // A card can be pulled out from under the pointer (editor opened, countdown
      // fired) without SwiftUI reporting hover-exit.
      manager.setHoveredItem(id: item.id, hovering: false)
    }
    .onAppear {
      isDismissing = false
      swipeOffset = 0
      isSwiping = false
      isDragging = false
      isHovering = false
    }
    .onReceive(manager.$items) { updatedItems in
      guard let currentItem = updatedItems.first(where: { $0.id == item.id }) else { return }
      if !currentItem.isWindowOpen && swipeOffset != 0 && !isSwiping && !isDismissing {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
          swipeOffset = 0
        }
      }
    }
    .task(id: item.thumbnailVersion) {
      retinaScale = item.isVideo ? nil : QuickAccessImageFileTransform.retinaScale(of: item.url)
    }
    .task(id: item.url) {
      guard item.isVideo, !QuickAccessCardChrome.isGIF(item.url) else { return }
      hasSound = await QuickAccessMediaInfo.hasAudioTrack(item.url)
    }
    .onReceive(manager.cardShortcutTrigger) { trigger in
      guard trigger.itemID == item.id, canPerformCardActions else { return }
      performAction(trigger.action)
    }
    .animation(QuickAccessAnimations.hoverOverlay, value: isHovering)
  }

  // MARK: - Computed Properties

  private var cardOpacity: Double {
    if isDragging { return 0.6 }
    return 1.0
  }

  private var captureType: CaptureType {
    item.isVideo ? .recording : .screenshot
  }

  private var isTempFile: Bool {
    TempCaptureManager.shared.isTempFile(item.url)
  }

  private var saveOrOpenActionTitle: String {
    L10n.Common.save
  }

  private var editActionTitle: String {
    item.isVideo ? L10n.QuickAccess.editVideo : L10n.AnnotateUI.modeAnnotate
  }

  private var deleteActionTitle: String {
    isTempFile ? L10n.Common.deleteAction : L10n.Common.moveToTrash
  }

  private var alreadyUploadedToCloud: Bool {
    item.cloudURL != nil && !item.isCloudStale
  }

  private var cloudActionTitle: String {
    if alreadyUploadedToCloud {
      return L10n.AnnotateUI.uploadedToCloud
    }
    return item.isCloudStale ? L10n.AnnotateUI.reuploadToCloud : L10n.AnnotateUI.uploadToCloud
  }

  private var cloudActionIcon: String {
    alreadyUploadedToCloud ? "checkmark.icloud" : "icloud.and.arrow.up"
  }

  private var canPerformCardActions: Bool {
    item.processingState == .idle && !isCloudUploading && !isDeleting
  }

  private var cardShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
  }

  private var primaryOverlayActions: [QuickAccessActionKind] {
    QuickAccessActionSlot.centerSlots.compactMap(overlayAction)
  }

  private var cornerOverlayActions: [QuickAccessActionKind] {
    QuickAccessActionSlot.cornerSlots.compactMap(overlayAction)
  }

  private var hasVisibleOverlayActions: Bool {
    !primaryOverlayActions.isEmpty || !cornerOverlayActions.isEmpty
  }

  private func overlayAction(in slot: QuickAccessActionSlot) -> QuickAccessActionKind? {
    guard let action = actionConfiguration.action(in: slot),
          actionConfiguration.isEnabled(action),
          isActionAvailable(action, on: .overlay) else {
      return nil
    }
    return action
  }

  // MARK: - Gestures

  private var dragInteractionBridge: some View {
    QuickAccessDraggableView(
      fileURL: item.url,
      thumbnail: item.cardThumbnail ?? item.thumbnail,
      dismissDirection: dismissDirection,
      dragDropEnabled: manager.dragDropEnabled,
      twoFingerSwipeToDismissEnabled: manager.twoFingerSwipeToDismissEnabled,
      swipeMode: trackpadSwipeModeStore.mode,
      onDragStarted: {
        isDragging = true
      },
      onDragEnded: { _ in isDragging = false },
      onDragEndedWithModifiers: { success, modifiers in
        isDragging = false
        let closeAfterDragging = UserDefaults.standard.object(forKey: "ownshot.quickAccess.closeAfterDragging") as? Bool ?? true
        if QuickAccessCompletionPolicy.shouldCloseAfterDrag(
          success: success, closeAfterDragging: closeAfterDragging, optionHeld: modifiers.contains(.option)
        ) {
          manager.dismissCard(id: item.id)
        }
      },
      onSwipeChanged: { translation in
        guard !reduceMotion else { return }
        var finalTranslation = QuickAccessCardDragPolicy(dismissDirection: dismissDirection).swipeTranslation(translation)
        if finalTranslation > 0 && swipeActionStore.action(for: .right) == nil {
          finalTranslation = 0
        } else if finalTranslation < 0 && swipeActionStore.action(for: .left) == nil {
          finalTranslation = 0
        }

        guard finalTranslation != 0 else {
          swipeOffset = 0
          isSwiping = false
          return
        }

        swipeOffset = finalTranslation
        isSwiping = true
      },
      onSwipeEnded: { translation, velocity in
        isSwiping = false
        var finalTranslation = translation
        var finalVelocity = velocity
        if finalTranslation > 0 && swipeActionStore.action(for: .right) == nil {
          finalTranslation = 0
          finalVelocity = 0
        } else if finalTranslation < 0 && swipeActionStore.action(for: .left) == nil {
          finalTranslation = 0
          finalVelocity = 0
        }

        handleSwipeEnded(translation: finalTranslation, velocity: finalVelocity)
      },
      swipeSensitivity: CGFloat(manager.swipeSensitivity),
      dragOnly: false,
      reservedScrollAxis: nil,
      onSwipeDown: { [manager] in manager.temporarilyHide() },
      onTrackpadSwipe: { direction in
        guard !isDismissing, let action = swipeActionStore.action(for: direction),
              isActionEnabled(action) else { return }
        performAction(action)
      }
    )
  }

  private func handleSwipeEnded(translation: CGFloat, velocity: CGFloat) {
    guard translation * dismissDirection > 0,
          QuickAccessCardDragPolicy(dismissDirection: dismissDirection).shouldDismiss(
            horizontalTranslation: translation, horizontalVelocity: velocity) else {
      withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
        swipeOffset = 0
      }
      return
    }

    let direction: QuickAccessSwipeDirection = translation > 0 ? .right : .left
    guard let configuredAction = swipeActionStore.action(for: direction),
          isActionEnabled(configuredAction) else {
      withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
        swipeOffset = 0
      }
      return
    }

    let willHideCard = configuredAction == .dismiss || configuredAction == .delete ||
      (configuredAction == .edit && QuickAccessCompletionPolicy.hidesCardWhenOpening(
        pin: false, hideCardWhenWindowOpen: manager.hideCardWhenWindowOpen
      ))

    if willHideCard {
      // Удаление из стека или уход последней панели продолжает текущее смещение.
      // Вторая анимация offset здесь давала наклон, исчезновение и повторный уход.
      performAction(configuredAction)
    } else {
      withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
        swipeOffset = 0
      }
      performAction(configuredAction)
    }
  }

  // MARK: - Actions

  private func actionTitle(for action: QuickAccessActionKind) -> String {
    switch action {
    case .copy:
      return L10n.Common.copy
    case .saveOrOpen:
      return saveOrOpenActionTitle
    case .dismiss:
      return L10n.Common.close
    case .delete:
      return deleteActionTitle
    case .edit:
      return editActionTitle
    case .uploadToCloud:
      return cloudActionTitle
    case .pinToScreen:
      return item.isPinned ? L10n.PreferencesQuickAccess.unpinAction : L10n.PreferencesQuickAccess.pinToScreenAction
    }
  }

  /// Tooltip text with the card action shortcut appended, so the binding is
  /// discoverable without opening Settings.
  private func actionHelpText(for action: QuickAccessActionKind) -> String {
    let title = actionTitle(for: action)
    guard actionShortcuts.isEnabled,
          actionShortcuts.isEnabled(for: action),
          let shortcut = actionShortcuts.shortcut(for: action),
          !QuickAccessActionShortcutStore.containsFunctionModifier(shortcut) else {
      return title
    }
    return "\(title)  \(shortcut.displayString)"
  }

  private func actionIcon(for action: QuickAccessActionKind) -> String {
    QuickAccessCardChrome.cornerSymbol(
      for: action,
      isVideo: item.isVideo,
      isPinned: item.isPinned,
      uploadedToCloud: alreadyUploadedToCloud
    )
  }

  private func actionAsset(for action: QuickAccessActionKind) -> QuickAccessCardChrome.CornerAsset? {
    QuickAccessCardChrome.cornerAsset(
      for: action,
      isVideo: item.isVideo,
      isPinned: item.isPinned,
      uploadedToCloud: alreadyUploadedToCloud
    )
  }

  private func isActionAvailable(
    _ action: QuickAccessActionKind,
    on _: QuickAccessActionSurface
  ) -> Bool {
    switch action {
    case .copy, .dismiss, .edit:
      return true
    case .pinToScreen:
      return true
    case .saveOrOpen:
      return true
    case .uploadToCloud:
      return shouldShowCloudButton
    case .delete:
      return true
    }
  }

  private func isActionEnabled(_ action: QuickAccessActionKind) -> Bool {
    switch action {
    case .pinToScreen:
      return !item.isVideo
    case .uploadToCloud:
      return shouldShowCloudButton && !alreadyUploadedToCloud && !isCloudUploading
    case .copy, .saveOrOpen, .dismiss, .delete, .edit:
      return true
    }
  }

  private func performAction(_ action: QuickAccessActionKind) {
    guard !isDeleting, isActionEnabled(action) else { return }

    switch action {
    case .copy:
      copyItem()
    case .saveOrOpen:
      saveOrOpenItem()
    case .dismiss:
      dismissItem()
    case .delete:
      deleteItem()
    case .edit:
      handleDoubleClick()
    case .uploadToCloud:
      uploadToCloud()
    case .pinToScreen:
      guard !item.isVideo else { return }
      manager.togglePin(id: item.id)
    }
  }

  private func handleDoubleClick() {
    guard !isDeleting else { return }
    if item.isVideo {
      openVideoEditor()
    } else {
      openAnnotation()
    }
  }

  private func openAnnotation() {
    Task { @MainActor in
      await Task.yield()
      guard canOpenCurrentItem else { return }
      AnnotateManager.shared.openAnnotation(for: item)
    }
  }

  private func openVideoEditor() {
    Task { @MainActor in
      guard canOpenCurrentItem else { return }
      VideoEditorManager.shared.openEditor(for: item)
    }
  }

  private var canOpenCurrentItem: Bool {
    !isDeleting && manager.items.contains { $0.id == item.id && $0.url == item.url }
  }

  private func copyItem() {
    manager.copyToClipboard(id: item.id, reduceMotion: reduceMotion)
  }

  private func saveOrOpenItem() {
    QuickAccessSound.save.play(reduceMotion: reduceMotion)
    manager.saveItem(id: item.id)
  }

  private func dismissItem() {
    // Несохранённая запись закрывается только после подтверждения, как в эталоне
    if QuickAccessCompletionPolicy.shouldConfirmClose(isVideo: item.isVideo, isTempFile: isTempFile),
       !confirmCloseRecording() {
      withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
        swipeOffset = 0
      }
      return
    }
    isDismissing = true
    QuickAccessSound.dismiss.play(reduceMotion: reduceMotion)
    manager.removeScreenshot(id: item.id)
  }

  private func confirmCloseRecording() -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = L10n.QuickAccess.closeRecordingTitle
    alert.informativeText = L10n.QuickAccess.closeRecordingMessage
    alert.addButton(withTitle: L10n.Common.close)
    alert.addButton(withTitle: L10n.Common.cancel)
    alert.window.level = NSWindow.Level(rawValue: QuickAccessLayout.alertWindowLevel)
    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertFirstButtonReturn
  }

  private func deleteItem() {
    guard !isDeleting else { return }
    isDeleting = true
    manager.requestDeleteItem(id: item.id, expectedURL: item.url) { deleted in
      defer { isDeleting = false }
      if deleted {
        isDismissing = true
      } else {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
          swipeOffset = 0
        }
      }
    }
  }

  // MARK: - Subviews

  private var thumbnailLayer: some View {
    // Clipped scaled-to-fill images can still expose their hidden area to hit
    // testing, so the thumbnail stays decorative and the card owns interaction.
    ZStack {
      // Шахматка под прозрачными снимками (popupCheckerboardDark/Light у эталона)
      if !item.isVideo {
        QuickAccessCheckerboard(isDark: colorScheme == .dark)
      }
      Image(nsImage: item.cardThumbnail ?? item.thumbnail)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: scaledWidth, height: scaledHeight)
        .clipped()
        // При наведении превью размывается под кнопками
        .blur(radius: showsHoverChrome ? QuickAccessLayout.hoverBlurRadius : 0, opaque: true)
    }
    .frame(width: scaledWidth, height: scaledHeight)
    .clipped()
    .contentShape(Rectangle())
    .allowsHitTesting(false)
  }

  private var showsHoverChrome: Bool {
    isHovering && !isSwiping && !isDismissing && canPerformCardActions && hasVisibleOverlayActions
  }

  /// Инфо-плашка записи: значок GIF или видео, значок звука, длительность и Quick Look.
  private var videoInfoPlate: some View {
    VStack {
      Spacer()
      HStack(spacing: 4) {
        if QuickAccessCardChrome.showsQuickLookButton(isVideo: item.isVideo, url: item.url) {
          Button {
            QuickAccessQuickLookController.shared.toggle(item.url)
          } label: {
            Image(systemName: "eye.fill")
              .font(.system(size: 9, weight: .semibold))
              .foregroundColor(.white)
              .frame(width: 20, height: 16)
              .background(Capsule().fill(Color.black.opacity(0.7)))
          }
          .buttonStyle(.plain)
          .help(L10n.QuickAccessMenu.quickLook)
          .accessibilityLabel(L10n.QuickAccessMenu.quickLook)
        }
        Spacer()
        HStack(spacing: 4) {
          ForEach(QuickAccessCardChrome.infoBadges(isVideo: item.isVideo, url: item.url, hasSound: hasSound), id: \.self) { badge in
            infoBadgeView(badge)
          }
          if let duration = item.formattedDuration {
            Text(duration)
              .font(.system(size: 10, weight: .semibold, design: .monospaced))
              .foregroundColor(.white)
          }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.black.opacity(0.7)))
      }
      .padding(6)
    }
  }

  @ViewBuilder
  private func infoBadgeView(_ badge: QuickAccessCardChrome.InfoBadge) -> some View {
    switch badge {
    case .gif:
      Text(verbatim: "GIF")
        .font(.system(size: 8, weight: .heavy))
        .foregroundColor(.black)
        .padding(.horizontal, 3)
        .background(RoundedRectangle(cornerRadius: 2).fill(Color.white))
        .accessibilityLabel(L10n.QuickAccess.gifFileBadge)
    case .video:
      Image(systemName: "video.fill")
        .font(.system(size: 9))
        .foregroundColor(.white)
        .accessibilityLabel(L10n.QuickAccess.videoFileBadge)
    case .sound:
      Image(systemName: "speaker.wave.2.fill")
        .font(.system(size: 9))
        .foregroundColor(.white)
        .accessibilityLabel(L10n.QuickAccess.withSoundBadge)
    }
  }

  private var isPinActionOnCard: Bool {
    actionConfiguration.assignedSlot(for: .pinToScreen) != nil
      && actionConfiguration.isEnabled(.pinToScreen)
  }

  private var pinIndicator: some View {
    Image(systemName: "pin.fill")
      .font(.system(size: 10, weight: .bold))
      .foregroundColor(.white)
      .frame(width: 20, height: 20)
      .background(Circle().fill(Color.black.opacity(0.6)))
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(6)
      .contentShape(Circle())
      .onTapGesture {
        manager.togglePin(id: item.id)
      }
      .help(item.isPinned ? L10n.PreferencesQuickAccess.unpinAction : L10n.PreferencesQuickAccess.pinToScreenAction)
  }

  private var hoverOverlay: some View {
    ZStack {
      // Dimming overlay
      RoundedRectangle(cornerRadius: cornerRadius)
        .fill(Color.black.opacity(QuickAccessLayout.hoverDimOpacity))

      // Action buttons with stagger effect
      VStack(spacing: QuickAccessLayout.textButtonSpacing) {
        ForEach(Array(QuickAccessActionSlot.centerSlots.enumerated()), id: \.element) { index, slot in
          if let action = overlayAction(in: slot) {
            staggeredButton(action: action, delay: index)
          } else {
            Color.clear.frame(height: QuickAccessLayout.textButtonHitHeight)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func staggeredButton(action: QuickAccessActionKind, delay: Int) -> some View {
    QuickAccessTextButton(label: actionTitle(for: action)) {
      performAction(action)
    }
      .help(actionHelpText(for: action))
      .disabled(!isActionEnabled(action))
      .opacity(isActionEnabled(action) ? 1 : 0.6)
      .transition(buttonTransition(delay: delay))
  }

  private func buttonTransition(delay: Int) -> AnyTransition {
    if reduceMotion {
      return .opacity
    }
    let stagger = Double(delay) * QuickAccessAnimations.buttonStaggerDelay
    return .scale(scale: 0.6)
      .combined(with: .opacity)
      .animation(QuickAccessAnimations.buttonReveal.delay(stagger))
  }

  private var cornerButtons: some View {
    ZStack {
      if let action = overlayAction(in: .topTrailing) {
        cornerButton(action, delay: 2)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      }
      if let action = overlayAction(in: .topLeading) {
        cornerButton(action, delay: 3)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      if let action = overlayAction(in: .bottomLeading) {
        cornerButton(action, delay: 4)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
      }
      if let action = overlayAction(in: .bottomTrailing) {
        cornerButton(action, delay: 5)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
      }
    }
  }

  private func cornerButton(_ action: QuickAccessActionKind, delay: Int) -> some View {
    QuickAccessIconButton(
      icon: actionIcon(for: action),
      asset: actionAsset(for: action),
      action: { performAction(action) },
      helpText: actionHelpText(for: action)
    )
    .transition(cornerButtonTransition(delay: delay))
    .padding(QuickAccessLayout.cornerButtonInset)
    .disabled(!isActionEnabled(action))
    .opacity(isActionEnabled(action) ? 1 : 0.6)
  }

  private func cornerButtonTransition(delay: Int) -> AnyTransition {
    if reduceMotion {
      return .opacity
    }
    let stagger = Double(delay) * QuickAccessAnimations.buttonStaggerDelay
    return .scale(scale: 0.5)
      .combined(with: .opacity)
      .animation(QuickAccessAnimations.buttonReveal.delay(stagger))
  }

  /// Creates drag preview for the card
  private var dragPreview: some View {
    Image(nsImage: item.cardThumbnail ?? item.thumbnail)
      .resizable()
      .aspectRatio(contentMode: .fill)
      .frame(width: scaledWidth * 0.8, height: scaledHeight * 0.8)
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
      .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
  }

  /// Меню в составе и порядке CleanShot X: открыть, pin, OCR, преобразования, облако и экспорт,
  /// системные Open With и Share, корзина, Finder, скрытие и закрытие.
  private var quickAccessContextMenuEntries: [QuickAccessContextMenuEntry] {
    guard canPerformCardActions else { return [] }

    let groups = QuickAccessCardMenuLayout.groups(
      isVideo: item.isVideo,
      includesCloud: shouldShowCloudButton,
      isRetina: retinaScale != nil,
      includesRaycast: OwnShotRaycastStub.isMenuVisible
    )
    var entries: [QuickAccessContextMenuEntry] = []
    for group in groups {
      if !entries.isEmpty {
        entries.append(.separator)
      }
      for command in group {
        if command == .close {
          // Как в CleanShot X: Save All и Close All стоят перед Close.
          entries.append(bulkActionEntries)
        }
        entries.append(menuEntry(for: command))
        if command == .openAnnotation, item.isVideo {
          entries.append(audioMixerEntry)
        }
      }
    }
    return entries
  }

  /// Audio Mixer записи с двумя дорожками: состав проверяется при открытии меню.
  private var audioMixerEntry: QuickAccessContextMenuEntry {
    .deferred { [url = item.url] in
      guard RecordingAudioMixerWindowController.canMix(url) else { return [] }
      return [.action(
        title: L10n.RecordingParity.audioMixerMenuItem,
        systemImage: "slider.horizontal.3",
        // Меню закрывается раньше окна.
        action: { DispatchQueue.main.async { RecordingAudioMixerWindowController.present(for: url) } }
      )]
    }
  }

  private func menuEntry(for command: QuickAccessCardMenuCommand) -> QuickAccessContextMenuEntry {
    let url = item.url
    switch command {
    case .openAnnotation:
      return .action(
        title: item.isVideo ? L10n.QuickAccess.editVideo : L10n.QuickAccessMenu.openAnnotationTool,
        systemImage: item.isVideo ? "film" : "pencil.tip.crop.circle",
        action: { handleDoubleClick() }
      )
    case .pinToScreen:
      return .action(
        title: item.isPinned ? L10n.PreferencesQuickAccess.unpinAction : L10n.QuickAccessMenu.pinToTheScreen,
        systemImage: item.isPinned ? "pin.slash" : "pin",
        action: { manager.togglePin(id: item.id) }
      )
    case .extractText:
      return .action(
        title: L10n.QuickAccessMenu.extractText,
        systemImage: "text.viewfinder",
        action: { QuickAccessFileActions.extractText(from: url) }
      )
    case .rotateLeft:
      return .action(
        title: L10n.QuickAccessMenu.rotateLeft,
        systemImage: "rotate.left",
        action: { [manager, id = item.id] in manager.transformImage(id: id, .rotateLeft) }
      )
    case .flipHorizontal:
      return .action(
        title: L10n.QuickAccessMenu.flipHorizontal,
        systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right",
        action: { [manager, id = item.id] in manager.transformImage(id: id, .flipHorizontal) }
      )
    case .resize:
      return .action(
        title: L10n.QuickAccessMenu.resize,
        systemImage: "arrow.up.left.and.arrow.down.right",
        // Меню закрывается раньше модального диалога.
        action: { [manager, id = item.id] in DispatchQueue.main.async { manager.resizeImage(id: id) } }
      )
    case .scaleRetina:
      let scale = retinaScale ?? 2
      return .action(
        title: L10n.QuickAccessMenu.scaleRetinaTo1x,
        systemImage: "arrow.down.right.and.arrow.up.left",
        action: { [manager, id = item.id] in manager.transformImage(id: id, .scaleRetinaTo1x(scale)) }
      )
    case .sendToRaycastAIChat:
      return .action(
        title: L10n.PersonalBuildStubs.sendToRaycastAIChatMenuItem,
        systemImage: "bubble.left.and.bubble.right",
        action: { OwnShotRaycastStub.send() }
      )
    case .uploadToCloud:
      return .action(
        title: cloudActionTitle,
        systemImage: cloudActionIcon,
        isEnabled: isActionEnabled(.uploadToCloud),
        action: { performAction(.uploadToCloud) }
      )
    case .quickLook:
      return .action(
        title: L10n.QuickAccessMenu.quickLook,
        systemImage: "eye",
        action: { QuickAccessQuickLookController.shared.toggle(url) }
      )
    case .print:
      return .action(
        title: L10n.QuickAccessMenu.print,
        systemImage: "printer",
        action: { DispatchQueue.main.async { QuickAccessFileActions.printImage(at: url) } }
      )
    case .saveAs:
      return .action(
        title: L10n.QuickAccessMenu.saveAs,
        systemImage: "square.and.arrow.down.on.square",
        action: { [manager, id = item.id] in
          DispatchQueue.main.async { manager.saveItem(id: id, useSavePanel: true) }
        }
      )
    case .openWith:
      return .submenu(
        title: L10n.QuickAccessMenu.openWith,
        systemImage: "arrow.up.forward.app",
        build: { QuickAccessFileActions.openWithMenu(for: url) }
      )
    case .openInMail:
      return .action(
        title: L10n.QuickAccessMenu.openInMail,
        systemImage: "envelope",
        action: { QuickAccessFileActions.openInMail(url) }
      )
    case .moveToTrash:
      return .action(
        title: deleteActionTitle,
        systemImage: "trash",
        action: { performAction(.delete) }
      )
    case .showInFinder:
      return .action(
        title: L10n.QuickAccessMenu.showInFinder,
        systemImage: "folder",
        action: { QuickAccessFileActions.showInFinder(url) }
      )
    case .share:
      return .native { QuickAccessFileActions.shareMenuItem(for: url) }
    case .temporarilyHide:
      return .action(
        title: L10n.QuickAccessMenu.temporarilyHide,
        systemImage: "chevron.down",
        action: { [manager] in manager.temporarilyHide() }
      )
    case .close:
      return .action(
        title: L10n.Common.close,
        systemImage: "xmark",
        action: { performAction(.dismiss) }
      )
    }
  }

  /// Число карточек проверяется в момент открытия меню, а не при последнем рендере карточки.
  private var bulkActionEntries: QuickAccessContextMenuEntry {
    .deferred { [manager] in
      guard manager.isBulkActionAvailable else { return [] }
      return Self.bulkActionItems(manager: manager)
    }
  }

  private static func bulkActionItems(manager: QuickAccessManager) -> [QuickAccessContextMenuEntry] {
    [
      .action(
        title: L10n.QuickAccess.saveAll,
        systemImage: "square.and.arrow.down.on.square",
        action: { manager.saveAll() }
      ),
      .action(
        title: L10n.QuickAccess.closeAll,
        systemImage: "xmark.square",
        // Меню закрывается раньше alert, иначе runModal блокирует трекинг меню.
        action: { DispatchQueue.main.async { manager.requestCloseAll() } }
      ),
    ]
  }

  // MARK: - Cloud Upload

  /// Whether to show the cloud upload button
  private var shouldShowCloudButton: Bool {
    true
  }

  /// Upload the current item to cloud storage
  private func uploadToCloud() {
    guard OwnShotFeaturePolicy.allow(.cloud) else { return }
    guard !isCloudUploading, !alreadyUploadedToCloud else {
      DiagnosticLogger.shared.log(
        .debug,
        .cloud,
        "Quick access cloud upload skipped",
        context: [
          "fileName": item.url.lastPathComponent,
          "isUploading": isCloudUploading ? "true" : "false",
          "alreadyUploaded": alreadyUploadedToCloud ? "true" : "false",
        ]
      )
      return
    }

    isCloudUploading = true
    cloudUploadProgress = 0
    manager.pauseCountdownForActivity(item.id)
    let uploadStartTime = Date()
    let oldCloudKey = item.cloudKey  // Save old key for cleanup
    DiagnosticLogger.shared.log(
      .info,
      .cloud,
      "Quick access cloud upload started",
      context: [
        "fileName": item.url.lastPathComponent,
        "hasOldCloudKey": oldCloudKey == nil ? "false" : "true",
      ]
    )

    // Animate to 80% quickly to show activity
    withAnimation(.easeOut(duration: 0.4)) {
      cloudUploadProgress = 0.8
    }

    Task {
      defer {
        manager.resumeCountdownForActivity(item.id)
      }

      do {
        let fileAccess = SandboxFileAccessManager.shared.beginAccessingURL(item.url)
        defer { fileAccess.stop() }

        // Always upload with a fresh key (new URL avoids CDN cache)
        let result = try await cloudManager.upload(fileURL: item.url)

        // Delete old cloud file in background (no garbage)
        if let oldKey = oldCloudKey {
          Task.detached(priority: .utility) {
            do {
              try await CloudManager.shared.deleteByKey(key: oldKey)
            } catch {
              DiagnosticLogger.shared.logError(.cloud, error, "Quick access old cloud object cleanup failed")
            }
          }
        }

        // Update item with new cloud URL and key
        manager.setCloudURL(id: item.id, url: result.publicURL, key: result.key)

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
        QuickAccessSound.copy.play(reduceMotion: reduceMotion)
        DiagnosticLogger.shared.log(
          .info,
          .cloud,
          "Quick access cloud upload completed",
          context: ["fileName": item.url.lastPathComponent]
        )
      } catch {
        isCloudUploading = false
        cloudUploadProgress = 0
        DiagnosticLogger.shared.logError(
          .cloud,
          error,
          "Quick access cloud upload failed",
          context: ["fileName": item.url.lastPathComponent]
        )
      }
    }
  }
}

// MARK: - Context Menu

private enum QuickAccessContextMenuEntry {
  case action(
    title: String,
    systemImage: String,
    isEnabled: Bool = true,
    action: () -> Void
  )
  case separator
  /// Пункт с подменю, которое собирается при открытии меню (Open With).
  case submenu(title: String, systemImage: String, build: () -> NSMenu)
  /// Готовый системный пункт (Share со службами macOS).
  case native(() -> NSMenuItem)
  /// Пункты, которые собираются при открытии меню.
  case deferred(() -> [QuickAccessContextMenuEntry])

  /// Раскрывает отложенные пункты и убирает лишние разделители.
  static func resolved(_ entries: [QuickAccessContextMenuEntry]) -> [QuickAccessContextMenuEntry] {
    let flat = entries.flatMap { entry -> [QuickAccessContextMenuEntry] in
      if case .deferred(let build) = entry { return resolved(build()) }
      return [entry]
    }
    var result: [QuickAccessContextMenuEntry] = []
    for entry in flat {
      if case .separator = entry {
        if result.isEmpty { continue }
        if case .separator = result.last! { continue }
      }
      result.append(entry)
    }
    if case .separator? = result.last { result.removeLast() }
    return result
  }
}

private struct QuickAccessContextMenuPresenter: NSViewRepresentable {
  let entries: [QuickAccessContextMenuEntry]

  func makeCoordinator() -> Coordinator {
    Coordinator(entries: entries)
  }

  func makeNSView(context: Context) -> ContextMenuHostView {
    let view = ContextMenuHostView()
    view.coordinator = context.coordinator
    return view
  }

  func updateNSView(_ nsView: ContextMenuHostView, context: Context) {
    context.coordinator.entries = entries
    nsView.coordinator = context.coordinator
  }

  final class Coordinator: NSObject {
    var entries: [QuickAccessContextMenuEntry]

    init(entries: [QuickAccessContextMenuEntry]) {
      self.entries = entries
    }

    var hasMenuItems: Bool {
      entries.contains { entry in
        switch entry {
        case .action, .submenu, .native: return true
        case .separator, .deferred: return false
        }
      }
    }

    func showMenu(for event: NSEvent, in view: NSView) {
      guard hasMenuItems else { return }
      guard let window = view.window else { return }

      let menu = NSMenu()
      menu.autoenablesItems = false

      for entry in QuickAccessContextMenuEntry.resolved(entries) {
        switch entry {
        case .action(let title, let systemImage, let isEnabled, let action):
          let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
          item.target = self
          item.isEnabled = isEnabled
          item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
          item.representedObject = QuickAccessContextMenuAction(action)

          menu.addItem(item)
        case .submenu(let title, let systemImage, let build):
          let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
          item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
          let submenu = build()
          item.submenu = submenu
          item.isEnabled = !submenu.items.isEmpty
          menu.addItem(item)
        case .native(let build):
          menu.addItem(build())
        case .separator:
          menu.addItem(.separator())
        case .deferred:
          break
        }
      }

      menu.update()

      let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
      let menuLocation = menuTopLeftLocationWithCursorNearTailItem(
        from: screenPoint,
        menu: menu,
        window: window
      )
      menu.popUp(positioning: nil, at: menuLocation, in: nil)
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
      guard let action = sender.representedObject as? QuickAccessContextMenuAction else { return }
      action.perform()
    }

    private func menuTopLeftLocationWithCursorNearTailItem(
      from point: NSPoint,
      menu: NSMenu,
      window: NSWindow
    ) -> NSPoint {
      let targetIndex = menuItemIndexNearCursor(in: menu)
      let targetCenterY = verticalOffsetToItemCenter(at: targetIndex, in: menu)
      let menuSize = menuSize(for: menu)
      let preferredPoint = NSPoint(
        x: point.x - 28,
        y: point.y + targetCenterY
      )
      let screen = window.screen ?? NSScreen.screens.first

      guard let visibleFrame = screen?.visibleFrame else {
        return preferredPoint
      }

      return NSPoint(
        x: min(max(preferredPoint.x, visibleFrame.minX + 8), visibleFrame.maxX - menuSize.width - 8),
        y: min(max(preferredPoint.y, visibleFrame.minY + menuSize.height + 8), visibleFrame.maxY - 8)
      )
    }

    private func menuItemIndexNearCursor(in menu: NSMenu) -> Int {
      let candidateIndex = max(0, menu.items.count - 2)
      if !menu.items[candidateIndex].isSeparatorItem {
        return candidateIndex
      }

      return menu.items.lastIndex { !$0.isSeparatorItem } ?? 0
    }

    private func verticalOffsetToItemCenter(at targetIndex: Int, in menu: NSMenu) -> CGFloat {
      let rowsAbove = menu.items.prefix(targetIndex).reduce(6) { partial, item in
        partial + menuItemHeight(item)
      }
      return rowsAbove + menuItemHeight(menu.items[targetIndex]) / 2
    }

    private func menuItemHeight(_ item: NSMenuItem) -> CGFloat {
      item.isSeparatorItem ? 9 : 22
    }

    private func menuSize(for menu: NSMenu) -> NSSize {
      let measured = menu.size
      guard measured.width > 0, measured.height > 0 else {
        let height = menu.items.reduce(12) { partial, item in
          partial + menuItemHeight(item)
        }
        return NSSize(width: 220, height: height)
      }
      return measured
    }
  }

  final class ContextMenuHostView: NSView {
    weak var coordinator: Coordinator?
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      updateEventMonitor()
    }

    deinit {
      if let eventMonitor {
        NSEvent.removeMonitor(eventMonitor)
      }
    }

    private func updateEventMonitor() {
      if let eventMonitor {
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
      }

      guard window != nil else { return }

      eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
        guard let self else { return event }
        return self.handleMouseDown(event)
      }
    }

    private func handleMouseDown(_ event: NSEvent) -> NSEvent? {
      guard event.window === window else { return event }
      guard isContextClick(event) else { return event }
      guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return event }
      guard coordinator?.hasMenuItems == true else { return event }

      coordinator?.showMenu(for: event, in: self)
      return nil
    }

    private func isContextClick(_ event: NSEvent) -> Bool {
      event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }
  }
}

private final class QuickAccessContextMenuAction: NSObject {
  private let action: () -> Void

  init(_ action: @escaping () -> Void) {
    self.action = action
    super.init()
  }

  func perform() {
    action()
  }
}

// MARK: - QuickAccessItem Drag Support

extension QuickAccessItem {
  /// Creates NSItemProvider for drag & drop to external apps
  func dragItemProvider() -> NSItemProvider {
    let fileURL = self.url
    let provider = NSItemProvider(contentsOf: fileURL) ?? NSItemProvider()
    provider.suggestedName = fileURL.lastPathComponent
    return provider
  }
}

// MARK: - Conditional View Extension

extension View {
  /// Conditionally applies a transformation to the view
  @ViewBuilder
  func `if`<Transform: View>(
    _ condition: Bool,
    transform: (Self) -> Transform
  ) -> some View {
    if condition {
      transform(self)
    } else {
      self
    }
  }
}
