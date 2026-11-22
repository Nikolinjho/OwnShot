//
//  ShortcutRecorderView.swift
//  Snapzy
//
//  SwiftUI view for recording custom keyboard shortcuts
//

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// A view that allows users to record custom keyboard shortcuts
struct ShortcutRecorderView: View {
  let label: String
  let description: String
  let footnote: String?
  @Binding var shortcut: ShortcutConfig?
  let defaultShortcut: ShortcutConfig?
  let isEnabled: Binding<Bool>?
  let validationIssue: ShortcutValidationIssue?
  /// Swaps shortcuts with the action that owns the rejected combination.
  /// Shown in the validation popover only when the issue carries a swap proposal.
  let onSwap: (() -> Void)?
  let onShortcutChanged: (ShortcutConfig?) -> Bool
  /// Разрешить клавишу без модификаторов (для команд внутри редактора и оверлея записи).
  let allowsSingleKey: Bool

  @Environment(\.ownShotWideShortcutRecorder) private var wideRecorder
  @StateObject private var recorder = ShortcutRecordingController()

  init(
    label: String,
    description: String = "",
    footnote: String? = nil,
    shortcut: Binding<ShortcutConfig?>,
    defaultShortcut: ShortcutConfig? = nil,
    isEnabled: Binding<Bool>? = nil,
    validationIssue: ShortcutValidationIssue? = nil,
    onSwap: (() -> Void)? = nil,
    allowsSingleKey: Bool = false,
    onShortcutChanged: @escaping (ShortcutConfig?) -> Bool
  ) {
    self.label = label
    self.description = description
    self.footnote = footnote
    self._shortcut = shortcut
    self.defaultShortcut = defaultShortcut
    self.isEnabled = isEnabled
    self.validationIssue = validationIssue
    self.onSwap = onSwap
    self.onShortcutChanged = onShortcutChanged
    self.allowsSingleKey = allowsSingleKey
  }

  var body: some View {
    HStack(spacing: 12) {
      titleLabel

      Spacer()

      HStack(spacing: 6) {
        Button {
          startRecording()
        } label: {
          Group {
            if recorder.isRecording {
              KeyCapRecordingView(minWidth: 100, heldModifiers: recorder.heldModifiers)
            } else if wideRecorder {
              // Поле эталона: «⇧⌘1» одной строкой в белом поле, пустое – серое «Record shortcut».
              ShortcutFieldView(shortcut: shortcut?.menuSymbolString)
            } else if let shortcut {
              KeyCapGroupView(parts: shortcut.displayParts)
            } else {
              KeyCapPlaceholderView(title: L10n.PreferencesShortcuts.setShortcut, minWidth: 104)
            }
          }
          .frame(
            width: wideRecorder ? ShortcutFieldView.size.width : nil,
            height: wideRecorder ? ShortcutFieldView.size.height : nil
          )
        }
        .buttonStyle(ShortcutKeycapButtonStyle(isRecording: recorder.isRecording))
        .shortcutValidationHighlight(issue: validationIssue, onSwap: onSwap)
        .disabled(!isInteractionEnabled)
        .help(isInteractionEnabled ? L10n.ShortcutRecorder.clickToRecord : L10n.ShortcutRecorder.turnOnToEdit)
        .accessibilityValue(shortcut.map { L10n.ShortcutRecorder.setNewHotkey($0.menuSymbolString) } ?? "")

        if recorder.isRecording {
          let buttons = ShortcutRecordingRules.recordingButtons(current: shortcut, defaultShortcut: defaultShortcut)
          ShortcutRecordingAuxButtons(
            canUseOld: buttons.useOld,
            canReset: buttons.reset,
            onUseOld: { recorder.stop() },
            onReset: {
              recorder.stop()
              resetToDefault()
            },
            // (x) эталона: «Delete shortcut» останавливает запись и очищает сочетание.
            onDelete: buttons.delete ? {
              recorder.stop()
              if onShortcutChanged(nil) {
                shortcut = nil
              }
            } : nil
          )
        }
      }
      .background(ShortcutRecorderAnchor(controller: recorder))
      // Поле не раздувает строку: у эталона строка сочетания 42 pt.
      .settingsRowHeight(wideRecorder ? SettingsRowMetrics.shortcutRecorderHeight : .infinity)

      // В Settings эталона у строки нет шестерёнки: те же действия – в контекстном меню строки.
      if !wideRecorder {
        ShortcutOptionsMenuButton(
          isEnabled: toggleBinding,
          isDefault: shortcut == defaultShortcut,
          isBusy: recorder.isRecording,
          onReset: resetToDefault
        )
      }
    }
    .contentShape(Rectangle())
    .contextMenu {
      if wideRecorder {
        ShortcutOptionsMenuItems(
          isEnabled: toggleBinding,
          isDefault: shortcut == defaultShortcut,
          onReset: resetToDefault
        )
        .disabled(recorder.isRecording)
      }
    }
    .opacity(rowOpacity)
    .onChange(of: isInteractionEnabled) { newValue in
      if !newValue {
        recorder.stop()
      }
    }
    .onDisappear {
      recorder.stop()
    }
    .shortcutSearchable(label)
  }

  private var toggleBinding: Binding<Bool>? {
    guard let isEnabled else { return nil }
    return Binding(
      get: { isEnabled.wrappedValue },
      set: { isEnabled.wrappedValue = $0 }
    )
  }

  /// В Settings эталона у строки нет значка ⓘ: описание – во всплывающей подсказке заголовка.
  @ViewBuilder private var titleLabel: some View {
    if rowHelpText.isEmpty {
      Text(label)
    } else if wideRecorder {
      Text(label).help(rowHelpText)
    } else {
      Text(label)
        .hint(rowHelpText, variant: .icon(.info))
    }
  }

  /// Description + footnote, shown from the ⓘ beside the title like `SettingRow`.
  private var rowHelpText: String {
    var parts: [String] = []
    if !description.isEmpty { parts.append(description) }
    if let footnote { parts.append(footnote) }
    return parts.joined(separator: "\n")
  }

  private var rowOpacity: Double {
    guard let isEnabled else { return 1 }
    return isEnabled.wrappedValue ? 1 : 0.62
  }

  private var isInteractionEnabled: Bool {
    isEnabled?.wrappedValue ?? true
  }

  private func resetToDefault() {
    if onShortcutChanged(defaultShortcut) {
      shortcut = defaultShortcut
    }
  }

  private func startRecording() {
    guard isInteractionEnabled else { return }
    let allowsSingleKey = allowsSingleKey
    recorder.start { [recorder] event in
      // ⌫ эталон не назначает и не очищает им сочетание: лист «Shortcut is reserved for macOS», запись идёт дальше.
      if let symbol = ShortcutRecordingRules.reservedKeySymbol(keyCode: event.keyCode, modifiers: event.modifierFlags) {
        recorder.presentReservedKeySheet(symbol: symbol)
        return
      }
      switch ShortcutRecordingRules.decisionDroppingFn(
        keyCode: event.keyCode,
        modifiers: event.modifierFlags,
        allowsSingleKey: allowsSingleKey
      ) {
      case .cancel:
        recorder.stop()
      case .clear:
        recorder.stop()
        _ = onShortcutChanged(nil)
      case .record(let config):
        // Запись завершается при любом исходе проверки, иначе поле молча остаётся в режиме записи.
        recorder.stop()
        _ = onShortcutChanged(config)
      case .ignore:
        // Сочетание без модификатора: ждём дальше, как эталон.
        NSSound.beep()
      }
    }
  }
}

// MARK: - Fn

extension ShortcutRecordingRules {
  /// Решение для рекордера Settings: эталон молча отбрасывает Fn и записывает остаток
  /// (fn+⌃⌥K → «⌃⌥K»). Если без Fn сочетание не набирается (одна клавиша без модификаторов,
  /// например F5 или fn+K), решение прежнее – с Fn.
  static func decisionDroppingFn(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags,
    allowsSingleKey: Bool
  ) -> ShortcutRecordingDecision {
    let withoutFn = decision(keyCode: keyCode, modifiers: modifiers.subtracting(.function), allowsSingleKey: allowsSingleKey)
    if case .ignore = withoutFn, modifiers.contains(.function) {
      return decision(keyCode: keyCode, modifiers: modifiers, allowsSingleKey: allowsSingleKey)
    }
    return withoutFn
  }
}

// MARK: - Recording Session

/// Сессия записи сочетания, общая для рекордеров страницы Shortcuts.
/// Пока идёт запись: глобальные сочетания приостановлены, нажатия уходят в обработчик,
/// удерживаемые модификаторы видны в поле, клик мимо поля или уход из окна отменяют запись.
@MainActor
final class ShortcutRecordingController: ObservableObject {
  @Published private(set) var isRecording = false
  @Published private(set) var heldModifiers = ""

  /// Невидимая подложка под полем и его кнопками: по ней определяется «клик мимо».
  weak var anchorView: NSView?

  /// Открыт лист «Shortcut is reserved for macOS»: запись не прерывается, нажатия и клики идут в лист.
  private(set) var isShowingReservedKeySheet = false

  private var monitors: [Any] = []
  private var observers: [NSObjectProtocol] = []
  private var didSuspendGlobalShortcuts = false
  private var keyHandler: ((NSEvent) -> Void)?

  func start(onKeyDown: @escaping (NSEvent) -> Void) {
    guard !isRecording else { return }
    isRecording = true
    heldModifiers = ""
    keyHandler = onKeyDown
    KeyboardShortcutManager.shared.beginTemporaryShortcutSuppression()
    didSuspendGlobalShortcuts = true

    if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
      guard let self, self.isRecording, !self.isShowingReservedKeySheet else { return event }
      self.keyHandler?(event)
      return nil
    }) {
      monitors.append(monitor)
    }

    if let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
      self?.heldModifiers = ShortcutRecordingRules.heldModifierSymbols(event.modifierFlags)
      return event
    }) {
      monitors.append(monitor)
    }

    // Клик мимо поля отменяет запись; сам клик проходит дальше.
    if let monitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
      handler: { [weak self] event in
        guard let self, self.isRecording, !self.isShowingReservedKeySheet else { return event }
        if self.shouldCancel(for: event) { self.stop() }
        return event
      }
    ) {
      monitors.append(monitor)
    }

    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.stop() }
    })
    observers.append(center.addObserver(
      forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
    ) { [weak self] notification in
      MainActor.assumeIsolated {
        guard let self, !self.isShowingReservedKeySheet, let window = notification.object as? NSWindow,
              window === self.anchorView?.window else { return }
        self.stop()
      }
    })
  }

  func stop() {
    guard isRecording || !monitors.isEmpty else { return }
    isRecording = false
    heldModifiers = ""
    keyHandler = nil
    monitors.forEach(NSEvent.removeMonitor)
    monitors.removeAll()
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
    if didSuspendGlobalShortcuts {
      KeyboardShortcutManager.shared.endTemporaryShortcutSuppression()
      didSuspendGlobalShortcuts = false
    }
  }

  /// Лист эталона на окне настроек: заголовок, текст «⌫ is used by macOS and cannot be assigned.»
  /// и одна кнопка OK. После OK запись продолжается. В тестовом хосте лист не показывается.
  func presentReservedKeySheet(symbol: String) {
    guard isRecording, !isShowingReservedKeySheet,
          AppLaunchPolicy().shouldStartInteractiveApplication,
          let window = anchorView?.window else { return }
    let alert = Self.makeReservedKeyAlert(symbol: symbol)
    isShowingReservedKeySheet = true
    alert.beginSheetModal(for: window) { [weak self] _ in
      MainActor.assumeIsolated { self?.isShowingReservedKeySheet = false }
    }
  }

  static func makeReservedKeyAlert(symbol: String) -> NSAlert {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = L10n.ShortcutValidation.reservedForMacOSTitle
    alert.informativeText = L10n.ShortcutValidation.usedByMacOS(symbol)
    alert.addButton(withTitle: L10n.Common.ok)
    return alert
  }

  private func shouldCancel(for event: NSEvent) -> Bool {
    guard let anchorView, let window = anchorView.window, event.window === window else { return true }
    let location = anchorView.convert(event.locationInWindow, from: nil)
    return ShortcutRecordingRules.shouldCancelOnClick(at: location, recorderFrame: anchorView.bounds)
  }
}

/// Подложка рекордера: прозрачная, клики не перехватывает.
struct ShortcutRecorderAnchor: NSViewRepresentable {
  let controller: ShortcutRecordingController

  func makeNSView(context: Context) -> NSView {
    let view = PassthroughAnchorView()
    controller.anchorView = view
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    controller.anchorView = nsView
  }

  private final class PassthroughAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}

/// Кнопки поля во время записи, как у рекордера эталона: «Use old shortcut», «Reset to default» и (x) «Delete shortcut».
struct ShortcutRecordingAuxButtons: View {
  let canUseOld: Bool
  let canReset: Bool
  let onUseOld: () -> Void
  let onReset: () -> Void
  /// (x) «Delete shortcut» эталона, последняя кнопка поля; nil – кнопки нет.
  var onDelete: (() -> Void)? = nil

  var body: some View {
    HStack(spacing: 2) {
      if canUseOld {
        auxButton(symbol: "arrow.uturn.backward.circle.fill", title: L10n.ShortcutRecorder.useOldShortcut, action: onUseOld)
      }
      if canReset {
        auxButton(symbol: "arrow.counterclockwise.circle.fill", title: L10n.ShortcutRecorder.resetToDefault, action: onReset)
      }
      if let onDelete {
        auxButton(symbol: "xmark.circle.fill", title: L10n.ShortcutRecorder.deleteShortcut, action: onDelete)
      }
    }
  }

  private func auxButton(symbol: String, title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 14, weight: .regular))
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
  }
}

/// Compact gear menu combining per-row shortcut options: enable/disable + reset to default.
/// Stays interactive while the row's shortcut is disabled so it can be re-enabled.
struct ShortcutOptionsMenuButton: View {
  /// nil when the row has no enable/disable concept (menu then only offers reset)
  var isEnabled: Binding<Bool>? = nil
  let isDefault: Bool
  let isBusy: Bool
  let onReset: () -> Void

  var body: some View {
    Menu {
      if let isEnabled {
        Toggle(L10n.Common.enabled, isOn: isEnabled)
        Divider()
      }
      Button {
        onReset()
      } label: {
        Label(L10n.Common.resetToDefault, systemImage: "arrow.counterclockwise")
      }
      .disabled(isDefault)
    } label: {
      Image(systemName: "gearshape")
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(.secondary)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(isBusy)
    .help(L10n.Common.options)
    .accessibilityLabel(L10n.Common.options)
  }
}

/// Пункты меню строки сочетания (Enabled, Reset to Default): в Settings – контекстное меню строки.
struct ShortcutOptionsMenuItems: View {
  var isEnabled: Binding<Bool>? = nil
  let isDefault: Bool
  let onReset: () -> Void

  var body: some View {
    if let isEnabled {
      Toggle(L10n.Common.enabled, isOn: isEnabled)
      Divider()
    }
    Button {
      onReset()
    } label: {
      Label(L10n.Common.resetToDefault, systemImage: "arrow.counterclockwise")
    }
    .disabled(isDefault)
  }
}

/// Geometry shared by the recorder field, its validation highlight and the legacy button style.
/// All three draw the same rectangle on top of each other, so they must agree on the radius.
enum ShortcutRecorderMetrics {
  /// A `KeyCapView` is 26pt tall and the styles add 4pt of vertical padding either side.
  static let fieldHeight: CGFloat = 34
  static var fieldRadius: CGFloat { Radius.control(forHeight: fieldHeight) }
}

/// Transparent button style for keycap-based shortcut recorder; the keycap pills themselves
/// carry the resting and recording visuals, this only adds press feedback.
struct ShortcutKeycapButtonStyle: ButtonStyle {
  let isRecording: Bool
  /// No inset by default: the keycap's own height sets the row, so recorder rows match
  /// `SettingRow` rows, and the row's 12pt spacing separates it from the options menu.
  var horizontalPadding: CGFloat = 0
  var verticalPadding: CGFloat = 0

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, verticalPadding)
      .contentShape(Radius.rect(ShortcutRecorderMetrics.fieldRadius))
      .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
      .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
  }
}

// MARK: - Validation Highlight + Popover

/// Lightweight coordinator ensuring only one validation popover is visible at a time.
/// Uses a closure callback to dismiss the previous popover — no Combine import needed.
@MainActor
enum ShortcutValidationPopoverCoordinator {
  private static var activeDismiss: (() -> Void)?
  private static var activeID: String?

  static func show(id: String, dismiss: @escaping () -> Void) {
    // Dismiss previous if different
    if activeID != id {
      activeDismiss?()
    }
    activeID = id
    activeDismiss = dismiss
  }

  static func clear(id: String) {
    guard activeID == id else { return }
    activeID = nil
    activeDismiss = nil
  }
}

/// Popover content for validation messages — styled for macOS popover chrome.
private struct ShortcutValidationPopoverContent: View {
  let issue: ShortcutValidationIssue
  /// Non-nil when the conflict can be resolved by swapping with the owning action.
  let onSwap: (() -> Void)?

  var body: some View {
    HStack(spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: iconName)
          .font(.system(size: 11, weight: .semibold))
          .foregroundColor(accentColor)

        VStack(alignment: .leading, spacing: 2) {
          if let title = issue.title {
            Text(title)
              .font(.system(size: 12, weight: .semibold))
              .foregroundColor(.primary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Text(issue.message)
            .font(.system(size: issue.title == nil ? 12 : 11, weight: issue.title == nil ? .medium : .regular))
            .foregroundColor(issue.title == nil ? .primary : .secondary)
            .lineLimit(issue.title == nil ? 2 : 3)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      if let onSwap {
        Button(L10n.ShortcutRecorder.swap, action: onSwap)
          .buttonStyle(.liquidGlass(emphasis: .secondary, capsule: true))
          .fixedSize()
          .keyboardShortcut(.defaultAction)
        .help(L10n.ShortcutRecorder.swapHelp)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .frame(minWidth: 160, maxWidth: onSwap == nil ? 260 : 340)
  }

  private var accentColor: Color {
    issue.severity == .error ? .red : .orange
  }

  private var iconName: String {
    issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
  }
}

/// ViewModifier: red/orange pill highlight on keycap + macOS popover tooltip.
struct ShortcutValidationHighlightModifier: ViewModifier {
  let issue: ShortcutValidationIssue?
  var onSwap: (() -> Void)? = nil

  @State private var showPopover = false
  @State private var dismissTask: DispatchWorkItem?
  @State private var instanceID = UUID().uuidString

  func body(content: Content) -> some View {
    content
      .background(
        Radius.rect(ShortcutRecorderMetrics.fieldRadius)
          .fill(pillFill)
          .animation(.easeOut(duration: 0.2), value: issue)
      )
      .overlay(
        Radius.rect(ShortcutRecorderMetrics.fieldRadius)
          .strokeBorder(pillBorder, lineWidth: 1)
          .animation(.easeOut(duration: 0.2), value: issue)
      )
      .popover(
        isPresented: $showPopover,
        attachmentAnchor: .rect(.bounds),
        arrowEdge: .bottom
      ) {
        if let issue {
          ShortcutValidationPopoverContent(issue: issue, onSwap: swapAction(for: issue))
        }
      }
      .onChange(of: issue) { newIssue in
        dismissTask?.cancel()
        if newIssue != nil {
          // Dismiss any other active popover first
          ShortcutValidationPopoverCoordinator.show(id: instanceID) { [self] in
            dismissTask?.cancel()
            showPopover = false
          }
          withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showPopover = true
          }
          let task = DispatchWorkItem { [self] in
            showPopover = false
            ShortcutValidationPopoverCoordinator.clear(id: instanceID)
          }
          dismissTask = task
          // A swap offer stays until the user acts or clicks away; plain messages auto-hide.
          if swapAction(for: newIssue) == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: task)
          }
        } else {
          showPopover = false
          ShortcutValidationPopoverCoordinator.clear(id: instanceID)
        }
      }
      .onChange(of: showPopover) { isShowing in
        if !isShowing {
          ShortcutValidationPopoverCoordinator.clear(id: instanceID)
        }
      }
  }

  private func swapAction(for issue: ShortcutValidationIssue?) -> (() -> Void)? {
    guard issue?.swapProposal != nil, let onSwap else { return nil }
    return {
      dismissTask?.cancel()
      showPopover = false
      onSwap()
    }
  }

  private var pillFill: Color {
    guard let issue else { return .clear }
    return issue.severity == .error
      ? Color.red.opacity(0.12)
      : Color.orange.opacity(0.12)
  }

  private var pillBorder: Color {
    guard let issue else { return .clear }
    return issue.severity == .error
      ? Color.red.opacity(0.35)
      : Color.orange.opacity(0.35)
  }
}

extension View {
  func shortcutValidationHighlight(
    issue: ShortcutValidationIssue?,
    onSwap: (() -> Void)? = nil
  ) -> some View {
    modifier(ShortcutValidationHighlightModifier(issue: issue, onSwap: onSwap))
  }
}

/// Legacy button style kept for backward compatibility (e.g. if referenced elsewhere)
struct ShortcutButtonStyle: ButtonStyle {
  let isRecording: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(Radius.rect(ShortcutRecorderMetrics.fieldRadius))
      .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
      .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
  }
}

// Поиск действует только внутри страницы сочетаний и не меняет другие формы.
enum OwnShotShortcutSearch {
  static func matches(_ query: String, title: String) -> Bool {
    let terms = query.split(whereSeparator: \.isWhitespace)
    return terms.allSatisfy { title.localizedStandardContains(String($0)) }
  }
}

private struct OwnShotShortcutSearchKey: EnvironmentKey {
  static let defaultValue = ""
}

private struct OwnShotWideShortcutRecorderKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var ownShotShortcutSearch: String {
    get { self[OwnShotShortcutSearchKey.self] }
    set { self[OwnShotShortcutSearchKey.self] = newValue }
  }
  var ownShotWideShortcutRecorder: Bool {
    get { self[OwnShotWideShortcutRecorderKey.self] }
    set { self[OwnShotWideShortcutRecorderKey.self] = newValue }
  }
}

private struct OwnShotShortcutSearchModifier: ViewModifier {
  @Environment(\.ownShotShortcutSearch) private var query
  let title: String

  func body(content: Content) -> some View {
    if OwnShotShortcutSearch.matches(query, title: title) { content }
  }
}

extension View {
  func shortcutSearchable(_ title: String) -> some View {
    modifier(OwnShotShortcutSearchModifier(title: title))
  }
}
