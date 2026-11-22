import AppKit

/// Параметры относятся к завершённому захвату, а не к моменту обработки файла.
@MainActor
final class OwnShotScreenshotCaptureMetadata {
  static let shared = OwnShotScreenshotCaptureMetadata()
  private var bypassed: Set<URL> = []
  private var pinned: Set<URL> = []
  private var copied: Set<URL> = []
  private var opensInAnnotate: Set<URL> = []
  private var clipboardOnly: Set<URL> = []
  private var sourceApps: [URL: String] = [:]
  private var order: [URL] = []

  func register(
    url: URL,
    bypassesDefaultPreset: Bool,
    pinsToScreen: Bool = false,
    copiesToClipboard: Bool = false,
    opensInAnnotate: Bool = false,
    copiesOnlyToClipboard: Bool = false,
    sourceAppBundleID: String? = nil
  ) {
    let url = url.standardizedFileURL
    order.removeAll { $0 == url }
    bypassed.remove(url)
    pinned.remove(url)
    sourceApps.removeValue(forKey: url)
    copied.remove(url)
    self.opensInAnnotate.remove(url)
    clipboardOnly.remove(url)
    guard bypassesDefaultPreset || pinsToScreen || copiesToClipboard || opensInAnnotate ||
      copiesOnlyToClipboard || sourceAppBundleID != nil
    else { return }
    if order.count >= 128 {
      let expired = order.removeFirst()
      bypassed.remove(expired)
      pinned.remove(expired)
      copied.remove(expired)
      self.opensInAnnotate.remove(expired)
      clipboardOnly.remove(expired)
      sourceApps.removeValue(forKey: expired)
    }
    order.append(url)
    if bypassesDefaultPreset { bypassed.insert(url) }
    if pinsToScreen { pinned.insert(url) }
    if copiesToClipboard { copied.insert(url) }
    if opensInAnnotate { self.opensInAnnotate.insert(url) }
    if copiesOnlyToClipboard { clipboardOnly.insert(url) }
    sourceApps[url] = sourceAppBundleID
  }

  /// Явный Copy или Ctrl при захвате копирует снимок независимо от After Capture.
  func consumeClipboardCopy(for url: URL) -> Bool {
    copied.remove(url.standardizedFileURL) != nil
  }

  func consumeCopyOnly(for url: URL) -> Bool {
    clipboardOnly.remove(url.standardizedFileURL) != nil
  }

  func consumeAnnotation(for url: URL) -> Bool {
    opensInAnnotate.remove(url.standardizedFileURL) != nil
  }

  func consumeBypass(for url: URL) -> Bool {
    bypassed.remove(url.standardizedFileURL) != nil
  }

  func consumePin(for url: URL) -> Bool {
    pinned.remove(url.standardizedFileURL) != nil
  }

  func consumeSourceAppBundleID(for url: URL) -> String? {
    sourceApps.removeValue(forKey: url.standardizedFileURL)
  }
}

@MainActor
enum OwnShotCaptureNamePrompt {
  static func resolve(suggested: String, isInteractive: Bool = true, scaleFactor: CGFloat? = nil, defaults: UserDefaults = .standard,
    prompt: ((String) -> String?)? = nil) -> String? {
    guard isInteractive, defaults.bool(forKey: OwnShotAdvancedPreferenceKeys.askForName) else { return suggested }
    let entered: String?
    if let prompt { entered = prompt(suggested) }
    else {
      let alert = NSAlert()
      alert.messageText = L10n.CaptureNamePrompt.title
      alert.addButton(withTitle: L10n.CaptureNamePrompt.save)
      alert.addButton(withTitle: L10n.Common.cancel)
      // Discard из changelog 4.7: снимок не сохраняется.
      alert.addButton(withTitle: L10n.CaptureNamePrompt.discard)
      let field = NSTextField(string: suggested)
      field.frame.size = CGSize(width: 320, height: 24)
      alert.accessoryView = field
      alert.window.initialFirstResponder = field
      NSApp.activate(ignoringOtherApps: true)
      entered = enteredName(for: alert.runModal(), fieldValue: field.stringValue, suggested: suggested)
    }
    guard let entered, !entered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return CaptureOutputNaming.resolveBaseName(customName: entered, kind: .screenshot, scaleFactor: scaleFactor, defaults: defaults)
  }

  /// Save берёт введённое имя, Cancel оставляет предложенное, Discard отменяет сохранение.
  static func enteredName(for response: NSApplication.ModalResponse, fieldValue: String, suggested: String) -> String? {
    switch response {
    case .alertFirstButtonReturn: fieldValue
    case .alertSecondButtonReturn: suggested
    default: nil
    }
  }
}
