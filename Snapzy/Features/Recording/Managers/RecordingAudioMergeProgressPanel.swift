//
//  RecordingAudioMergeProgressPanel.swift
//  Snapzy
//
//  Окно Merging audio... на время сведения микрофона и системного звука,
//  как AudioMixer у эталона: индикатор и отмена с подтверждением.
//

import AppKit

@MainActor
final class RecordingAudioMergeProgressPanel: NSObject {
  /// Короткое сведение не мигает окном.
  static let presentationDelay: TimeInterval = 0.5

  private var panel: NSPanel?
  private var cancellation: RecordingAudioMergeCancellation?
  private var pendingShow: DispatchWorkItem?

  func begin(cancellation: RecordingAudioMergeCancellation) {
    end()
    self.cancellation = cancellation
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.show() }
    }
    pendingShow = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.presentationDelay, execute: work)
  }

  func end() {
    pendingShow?.cancel()
    pendingShow = nil
    cancellation = nil
    panel?.orderOut(nil)
    panel = nil
  }

  private func show() {
    guard cancellation != nil, panel == nil else { return }
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 96),
      styleMask: [.titled, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.title = L10n.RecordingParity.mergingAudio
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    // Выше панели записи, как алерты записи.
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)

    let label = NSTextField(labelWithString: L10n.RecordingParity.mergingAudio)
    let indicator = NSProgressIndicator()
    indicator.style = .bar
    indicator.isIndeterminate = true
    indicator.startAnimation(nil)
    let cancelButton = NSButton(title: L10n.Common.cancel, target: self, action: #selector(cancelPressed))
    cancelButton.keyEquivalent = "\u{1b}"

    let stack = NSStackView(views: [label, indicator, cancelButton])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let content = NSView()
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      stack.topAnchor.constraint(equalTo: content.topAnchor),
      stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      indicator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
    ])
    panel.contentView = content
    panel.center()
    panel.orderFrontRegardless()
    self.panel = panel
  }

  @objc private func cancelPressed() {
    guard let cancellation else { return }
    // Сведение могло закончиться, пока висел вопрос: тогда отменять нечего.
    if RecordingStartWarningPresenter.confirmStopAudioMerge(), self.cancellation === cancellation {
      cancellation.cancel()
    }
  }
}
