//
//  HistoryCardView.swift
//  Snapzy
//
//  Refined preview card for the floating history panel
//

import AppKit
import SwiftUI

enum HistoryCardEmphasis {
  static let activeBorderWidth: CGFloat = 3
  static let inactiveBorderWidth: CGFloat = 1.2
  static let activeScale: CGFloat = 1.02
  static let focusedLiftOffset: CGFloat = -12
  static let expandedHoverScale: CGFloat = 1.005
  static let springResponse: Double = 0.24
  static let springDampingFraction: Double = 0.88
  static let activeShadowRadius: CGFloat = 18
  static let inactiveShadowRadius: CGFloat = 3
  static let activeShadowYOffset: CGFloat = 8
  static let inactiveShadowYOffset: CGFloat = 2

  static func activeShadowColor(for colorScheme: ColorScheme) -> Color {
    Color.black.opacity(colorScheme == .dark ? 0.28 : 0.12)
  }

  static func shadowColor(
    isActive: Bool,
    isHovering: Bool,
    backgroundStyle: HistoryBackgroundStyle,
    colorScheme: ColorScheme
  ) -> Color {
    if isActive {
      return activeShadowColor(for: colorScheme)
    }

    if isHovering {
      return Color.black.opacity(colorScheme == .dark ? 0.18 : 0.08)
    }

    if backgroundStyle == .solid {
      return Color.black.opacity(colorScheme == .dark ? 0.16 : 0.07)
    }

    return .clear
  }
}

struct HistoryCardView: View, Equatable {
  let record: CaptureHistoryRecord
  let isSelected: Bool
  let onTap: () -> Void
  let reservedScrollAxis: QuickAccessDragScrollAxis?

  let backgroundStyle: HistoryBackgroundStyle

  static func == (lhs: HistoryCardView, rhs: HistoryCardView) -> Bool {
    lhs.record == rhs.record &&
    lhs.isSelected == rhs.isSelected &&
    lhs.reservedScrollAxis == rhs.reservedScrollAxis &&
    lhs.backgroundStyle == rhs.backgroundStyle &&
    HistoryFloatingManager.shared.cloudUploadState(for: lhs.record) == HistoryFloatingManager.shared.cloudUploadState(for: rhs.record)
  }

  @ObservedObject private var manager = HistoryFloatingManager.shared
  @Environment(\.colorScheme) private var colorScheme
  @State private var thumbnailImage: NSImage?
  @State private var isHovering = false
  @State private var fileExists = true
  @State private var isVisible = false
  @State private var thumbnailReloadToken = 0

  var body: some View {
    // Плитка эталона 255 × 210: миниатюра 185 × 130 на 25 pt от верха, под ней подпись
    // времени, у выбранной плитки вместо подписи – Restore.
    VStack(spacing: 0) {
      preview
        .frame(
          width: HistoryFloatingLayout.compactThumbnailSize.width,
          height: HistoryFloatingLayout.compactThumbnailSize.height
        )
        .overlay(alignment: .bottomTrailing) {
          sourceBadge
            .offset(
              x: HistoryFloatingLayout.compactBadgeOverhang,
              y: HistoryFloatingLayout.compactBadgeOverhang
            )
        }

      Group {
        if isSelected && fileExists {
          restoreButton
        } else {
          Text(relativeTimeString(from: record.capturedAt))
            .font(.system(size: 12.5, weight: .medium))
            .foregroundColor(timeLabelColor)
        }
      }
      .frame(maxWidth: .infinity, minHeight: HistoryFloatingLayout.compactLabelHeight)
      .padding(.top, HistoryFloatingLayout.compactLabelSpacing)

      Spacer(minLength: 0)
    }
    .padding(.top, HistoryFloatingLayout.compactThumbnailTopInset)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .contentShape(Rectangle())
    .overlay(historyDragInteractionBridge)
    .scaleEffect(isSelected ? HistoryCardEmphasis.activeScale : (isHovering ? 1.01 : 1))
    .animation(
      .spring(
        response: HistoryCardEmphasis.springResponse,
        dampingFraction: HistoryCardEmphasis.springDampingFraction
      ),
      value: isSelected
    )
    .animation(.easeOut(duration: 0.18), value: isHovering)
    .onHover { hovering in
      isHovering = hovering
    }
    .onTapGesture {
      onTap()
    }
    .simultaneousGesture(
      TapGesture(count: 2).onEnded {
        openDefaultEditor()
      }
    )
    .onAppear {
      isVisible = true
      checkFileExistence()
    }
    .onDisappear {
      isVisible = false
    }
    .task(id: thumbnailTaskID, priority: .utility) {
      guard isVisible else { return }
      await loadThumbnail()
    }
    .onReceive(NotificationCenter.default.publisher(for: .captureHistoryFileDidChange)) { notification in
      guard matchesHistoryFileChange(notification) else { return }
      thumbnailImage = nil
      checkFileExistence()
      thumbnailReloadToken += 1
    }
  }

  private var preview: some View {
    ZStack(alignment: .bottomTrailing) {
      cardShape
        .fill(cardBackground)

      if isVisible, let image = thumbnailImage {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
          .frame(
            width: HistoryFloatingLayout.compactThumbnailSize.width,
            height: HistoryFloatingLayout.compactThumbnailSize.height
          )
      } else {
        Image(systemName: iconName)
          .font(.system(size: 30, weight: .medium))
          .foregroundColor(.secondary.opacity(0.55))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      if !fileExists {
        Rectangle()
          .fill(Color.black.opacity(0.4))

        VStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 16))
          Text(L10n.PreferencesHistory.fileMissing)
            .font(.caption2.weight(.semibold))
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      if let duration = record.formattedDuration, record.captureType != .screenshot {
        VStack {
          HStack {
            Text(duration)
              .font(.caption2.weight(.semibold))
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(Color.black.opacity(0.68))
              .foregroundColor(.white)
              .clipShape(Capsule())
            Spacer()
          }
          Spacer()
        }
        .padding(10)
      }

      if let uploadState = manager.cloudUploadState(for: record) {
        HistoryCloudUploadOverlayView(state: uploadState)
      }

      // У эталона удаление – из контекстного меню; корзина видна только при наведении.
      if isHovering {
        HistoryCardRemoveButton(record: record, size: 26)
          .padding(8)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
          .transition(.opacity)
      }
    }
    .clipShape(cardShape)
    .overlay(
      cardShape.stroke(
        cardBorderColor,
        lineWidth: isSelected
          ? HistoryCardEmphasis.activeBorderWidth
          : HistoryCardEmphasis.inactiveBorderWidth
      )
    )
    .shadow(
      color: cardShadowColor,
      radius: isSelected
        ? HistoryCardEmphasis.activeShadowRadius
        : HistoryCardEmphasis.inactiveShadowRadius,
      x: 0,
      y: isSelected
        ? HistoryCardEmphasis.activeShadowYOffset
        : HistoryCardEmphasis.inactiveShadowYOffset
    )
  }

  /// Бейдж приложения-источника 42 pt, как у эталона. Значок типа захвата
  /// (когда приложение неизвестно) появляется только при наведении.
  @ViewBuilder private var sourceBadge: some View {
    if HistorySourceAppIconCache.icon(for: record.sourceAppBundleID) != nil {
      HistorySourceAppBadge(
        bundleID: record.sourceAppBundleID,
        size: HistoryFloatingLayout.compactBadgeSize
      ) { EmptyView() }
      .allowsHitTesting(false)
    } else if isHovering {
      typeBadge
        .padding(HistoryFloatingLayout.compactBadgeOverhang + 10)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
  }

  private var historyDragInteractionBridge: some View {
    HistoryCardDragInteractionView(
      record: record,
      thumbnail: thumbnailImage,
      isEnabled: fileExists,
      reservedScrollAxis: reservedScrollAxis
    )
  }

  private var restoreButton: some View {
    // Restore возвращает запись в Quick Access без редактора, History остаётся открытой.
    Button(action: { if fileExists { HistoryWindowController.shared.restoreItem(record, hidesHistory: false) } }) {
      HStack(spacing: HistoryChrome.restoreIconSpacing) {
        Image(systemName: "arrow.uturn.backward")
        Text(L10n.Common.restore)
      }
      .font(.system(size: HistoryChrome.restoreFontSize, weight: .semibold))
    }
    .buttonStyle(.plain)
    .foregroundColor(.white)
    .padding(.horizontal, HistoryChrome.restoreHorizontalPadding)
    .frame(height: HistoryChrome.restoreButtonHeight)
    // Restore у эталона залит акцентом темы, как рамка выбранной карточки
    .background(Capsule(style: .continuous).fill(HistoryChrome.selectionAccent))
  }

  private var cardShape: RoundedRectangle {
    Radius.rect(Radius.card)
  }

  private var cardBackground: some ShapeStyle {
    if backgroundStyle == .solid {
      return colorScheme == .dark
        ? AnyShapeStyle(Color.white.opacity(0.1))
        : AnyShapeStyle(Color.white.opacity(0.96))
    }

    return colorScheme == .dark
      ? AnyShapeStyle(Color.white.opacity(0.08))
      : AnyShapeStyle(Color.white.opacity(0.88))
  }

  private var cardBorderColor: Color {
    if isSelected {
      // Рамка выбранной карточки – чистый акцент #CE4745 (ref-history-full.png)
      return HistoryChrome.selectionAccent
    }

    if isHovering {
      return colorScheme == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.08)
    }

    if backgroundStyle == .solid {
      return colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.06)
    }

    return Color.clear
  }

  private var cardShadowColor: Color {
    HistoryCardEmphasis.shadowColor(
      isActive: isSelected,
      isHovering: isHovering,
      backgroundStyle: backgroundStyle,
      colorScheme: colorScheme
    )
  }

  private var timeLabelColor: Color {
    colorScheme == .dark ? .white.opacity(0.82) : .primary.opacity(0.7)
  }

  private var typeBadge: some View {
    Image(systemName: iconName)
      .font(.system(size: 11, weight: .semibold))
      .foregroundColor(.primary.opacity(0.78))
      .frame(width: 30, height: 30)
      .background(.regularMaterial)
      .clipShape(Circle())
      .overlay(
        Circle()
          .stroke(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.6), lineWidth: 1)
      )
  }

  private var iconName: String {
    record.captureType.systemIconName
  }

  @MainActor
  private func loadThumbnail() async {
    let image = await HistoryThumbnailGenerator.shared.loadThumbnailImage(for: record)
    guard !Task.isCancelled else { return }
    thumbnailImage = image
  }

  private var thumbnailTaskID: String {
    let id = record.thumbnailPath ?? record.id.uuidString
    return isVisible ? "\(id)-\(thumbnailReloadToken)" : "hidden-\(record.id.uuidString)"
  }

  private func matchesHistoryFileChange(_ notification: Notification) -> Bool {
    if let recordIDs = notification.userInfo?["recordIDs"] as? [UUID],
       recordIDs.contains(record.id) {
      return true
    }

    return (notification.userInfo?["filePath"] as? String) == record.filePath
  }

  private func checkFileExistence() {
    let url = record.fileURL
    let path = record.filePath
    let access = SandboxFileAccessManager.shared.beginAccessingURL(url)
    Task { @MainActor in
      let exists = await Task.detached(priority: .utility) {
        defer { access.stop() }
        return FileManager.default.fileExists(atPath: path)
      }.value
      guard !Task.isCancelled else { return }
      fileExists = exists
      // Карточку без файла эталон молча убирает из ленты.
      if !exists { CaptureHistoryStore.shared.hideRecordWithMissingFile(id: record.id) }
    }
  }

  private func relativeTimeString(from date: Date) -> String {
    HistoryFormatterCache.relativeFull.localizedString(for: date, relativeTo: Date())
  }

  private func openDefaultEditor() {
    guard fileExists else { return }
    HistoryWindowController.shared.openItem(record)
  }
}

/// Small liquid-glass trash button pinned to a history card's top-trailing corner.
/// Removes the single capture (moves the file to Trash), matching the context-menu Delete.
struct HistoryCardRemoveButton: View {
  let record: CaptureHistoryRecord
  var size: CGFloat = 24

  var body: some View {
    Button {
      HistoryWindowController.shared.deleteRecordsConfirmingIfNeeded([record])
    } label: {
      Image(systemName: "trash")
        .font(.system(size: size * 0.42, weight: .semibold))
        .foregroundColor(LiquidGlassTokens.inkOverlay)
        .frame(width: size, height: size)
        .liquidGlassControl(
          isActive: false,
          in: Circle(),
          emphasis: .overlay,
          showsRestingSurface: true
        )
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help(L10n.Common.deleteAction)
    .accessibilityLabel(L10n.Common.deleteAction)
  }
}

/// Adds the shared AppKit file-drag behavior to a history card without taking
/// ownership of SwiftUI's tap, selection, or double-click gestures.
struct HistoryCardDragInteractionView: View {
  let record: CaptureHistoryRecord
  let thumbnail: NSImage?
  let isEnabled: Bool
  let reservedScrollAxis: QuickAccessDragScrollAxis?

  var body: some View {
    QuickAccessDraggableView(
      fileURL: record.fileURL,
      thumbnail: thumbnail ?? fallbackThumbnail,
      dismissDirection: 0,
      dragDropEnabled: isEnabled,
      twoFingerSwipeToDismissEnabled: false,
      swipeMode: .natural,
      onDragStarted: {},
      onDragEnded: { _ in },
      onSwipeChanged: { _ in },
      onSwipeEnded: { _, _ in },
      swipeSensitivity: 1,
      dragOnly: true,
      reservedScrollAxis: reservedScrollAxis
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var fallbackThumbnail: NSImage {
    NSImage(
      systemSymbolName: record.captureType.systemIconName,
      accessibilityDescription: nil
    ) ?? NSImage(size: CGSize(width: 120, height: 75))
  }
}
