//
//  RecordingAudioMixerWindowController.swift
//  Snapzy
//
//  Окно Audio Mixer, как AudioMixer эталона: плеер записи, ползунки
//  Microphone volume и System audio volume, кнопка сведения и прогресс
//  Merging audio... с отменой. Ползунки сразу меняют звук в плеере.
//

import AppKit
import AVFoundation
import AVKit

@MainActor
final class RecordingAudioMixerWindowController: NSWindowController, NSWindowDelegate {
  /// Одно окно на файл: повторный вызов поднимает уже открытое.
  private static var openControllers: [URL: RecordingAudioMixerWindowController] = [:]

  /// Пункт меню карточки показывается, только если сводить есть что.
  static func canMix(_ url: URL) -> Bool {
    RecordingAudioMixer.source(for: url) != nil
  }

  static func present(for url: URL) {
    let key = url.standardizedFileURL
    if let existing = openControllers[key] {
      existing.showWindow(nil)
      existing.window?.makeKeyAndOrderFront(nil)
      return
    }
    guard let source = RecordingAudioMixer.source(for: url) else {
      RecordingStartWarningPresenter.presentAudioMixerFailure(message: L10n.RecordingParity.mergeFailedMessage)
      return
    }
    let controller = RecordingAudioMixerWindowController(source: source)
    openControllers[key] = controller
    controller.showWindow(nil)
    controller.window?.center()
    NSApp.activate(ignoringOtherApps: true)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  let source: RecordingAudioMixerSource
  private(set) var volumes = RecordingAudioMixerVolumes.default
  private(set) var isSaving = false
  private var didSave = false
  private var cancellation: RecordingAudioMergeCancellation?

  private let player = AVPlayer()
  private let playerView = AVPlayerView()
  private let microphoneSlider = NSSlider()
  private let systemAudioSlider = NSSlider()
  private let microphoneValueLabel = NSTextField(labelWithString: "")
  private let systemAudioValueLabel = NSTextField(labelWithString: "")
  private let progressIndicator = NSProgressIndicator()
  private let progressLabel = NSTextField(labelWithString: L10n.RecordingParity.mergingAudio)
  private let mergeButton = NSButton()
  private let cancelButton = NSButton()
  private var audioTracks: [AVAssetTrack] = []

  init(source: RecordingAudioMixerSource) {
    self.source = source
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = L10n.RecordingParity.audioMixerTitle
    window.subtitle = source.videoURL.lastPathComponent
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 420, height: 380)
    super.init(window: window)
    window.delegate = self
    buildContent(in: window)
    loadPlayerItem()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Ползунки

  /// Тесты и ползунки меняют громкости через один вход.
  func setVolumes(_ newVolumes: RecordingAudioMixerVolumes) {
    volumes = newVolumes
    microphoneSlider.doubleValue = Double(newVolumes.microphone)
    systemAudioSlider.doubleValue = Double(newVolumes.systemAudio)
    microphoneValueLabel.stringValue = RecordingAudioMixerVolumes.percentText(newVolumes.microphone)
    systemAudioValueLabel.stringValue = RecordingAudioMixerVolumes.percentText(newVolumes.systemAudio)
    applyPreviewAudioMix()
  }

  @objc private func micSliderChanged(_ sender: NSSlider) {
    setVolumes(RecordingAudioMixerVolumes(microphone: sender.floatValue, systemAudio: volumes.systemAudio))
  }

  @objc private func audioSliderChanged(_ sender: NSSlider) {
    setVolumes(RecordingAudioMixerVolumes(microphone: volumes.microphone, systemAudio: sender.floatValue))
  }

  // MARK: - Сведение

  @objc private func mergeAudio() {
    guard !isSaving else { return }
    let fileBytes = (try? source.sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    let available = RecordingDiskSpace.availableBytes(at: source.videoURL.deletingLastPathComponent())
    guard RecordingAudioMergeDiskPolicy.hasEnoughSpace(sourceFileBytes: fileBytes, availableBytes: available) else {
      RecordingStartWarningPresenter.presentAudioMixerFailure(message: L10n.RecordingParity.mergeDiskLowMessage)
      return
    }
    player.pause()
    let cancellation = RecordingAudioMergeCancellation()
    self.cancellation = cancellation
    setSaving(true)
    let source = source
    let volumes = volumes
    Task { [weak self] in
      do {
        try await RecordingAudioMixer.merge(source, volumes: volumes, cancellation: cancellation)
        self?.finishMerge(error: nil)
      } catch {
        self?.finishMerge(error: error)
      }
    }
  }

  private func finishMerge(error: Error?) {
    cancellation = nil
    setSaving(false)
    guard let error else {
      didSave = true
      close()
      return
    }
    if case RecordingAudioCompatibilityExporter.ExportError.cancelled = error { return }
    DiagnosticLogger.shared.logError(.recording, error, "Audio mixer merge failed", context: [
      "file": source.videoURL.lastPathComponent
    ])
    let message = source.kind == .separateTracksInVideo
      ? L10n.RecordingParity.mergeFailedMessage
      : error.localizedDescription
    RecordingStartWarningPresenter.presentAudioMixerFailure(message: message)
  }

  @objc private func cancelPressed() {
    if isSaving {
      guard let cancellation else { return }
      if RecordingStartWarningPresenter.confirmStopAudioMerge(), self.cancellation === cancellation {
        cancellation.cancel()
      }
      return
    }
    window?.performClose(nil)
  }

  private func setSaving(_ saving: Bool) {
    isSaving = saving
    progressIndicator.isHidden = !saving
    progressLabel.isHidden = !saving
    if saving { progressIndicator.startAnimation(nil) } else { progressIndicator.stopAnimation(nil) }
    mergeButton.isEnabled = !saving
    microphoneSlider.isEnabled = !saving
    systemAudioSlider.isEnabled = !saving
  }

  // MARK: - Закрытие

  /// Закрытие без сведения у раздельных дорожек спрашивает подтверждение.
  static func shouldConfirmClose(kind: RecordingAudioMixerSource.Kind, didSave: Bool, isSaving: Bool) -> Bool {
    !didSave && !isSaving && kind == .separateTracksInVideo
  }

  func windowShouldClose(_: NSWindow) -> Bool {
    if isSaving {
      cancelPressed()
      return false
    }
    guard Self.shouldConfirmClose(kind: source.kind, didSave: didSave, isSaving: isSaving) else { return true }
    return RecordingStartWarningPresenter.confirmKeepSeparateAudioTracks()
  }

  func windowWillClose(_: Notification) {
    player.pause()
    player.replaceCurrentItem(with: nil)
    Self.openControllers.removeValue(forKey: source.videoURL.standardizedFileURL)
  }

  // MARK: - Плеер

  private func loadPlayerItem() {
    let asset = AVURLAsset(url: source.sourceURL)
    let item = AVPlayerItem(asset: asset)
    player.replaceCurrentItem(with: item)
    playerView.player = player
    Task { [weak self] in
      let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
      self?.audioTracks = tracks
      self?.applyPreviewAudioMix()
    }
  }

  private func applyPreviewAudioMix() {
    guard let item = player.currentItem, !audioTracks.isEmpty else { return }
    let trackVolumes = volumes.trackVolumes(for: source)
    let mix = AVMutableAudioMix()
    mix.inputParameters = audioTracks.map { track in
      let parameters = AVMutableAudioMixInputParameters(track: track)
      parameters.setVolume(trackVolumes[track.trackID] ?? 1, at: .zero)
      return parameters
    }
    item.audioMix = mix
  }

  // MARK: - Вёрстка

  private func buildContent(in window: NSWindow) {
    playerView.controlsStyle = .inline
    playerView.showsFullScreenToggleButton = false

    let prompt = NSTextField(wrappingLabelWithString: L10n.RecordingParity.audioMixerPrompt)
    prompt.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)

    configure(slider: microphoneSlider, action: #selector(micSliderChanged(_:)),
              label: L10n.RecordingParity.audioMixerMicrophoneVolume)
    configure(slider: systemAudioSlider, action: #selector(audioSliderChanged(_:)),
              label: L10n.RecordingParity.audioMixerSystemAudioVolume)

    let grid = NSGridView(views: [
      [NSTextField(labelWithString: L10n.RecordingParity.audioMixerMicrophoneVolume), microphoneSlider, microphoneValueLabel],
      [NSTextField(labelWithString: L10n.RecordingParity.audioMixerSystemAudioVolume), systemAudioSlider, systemAudioValueLabel],
    ])
    grid.rowSpacing = 8
    grid.columnSpacing = 10
    grid.column(at: 0).xPlacement = .trailing
    grid.column(at: 2).width = 44
    grid.rowAlignment = .firstBaseline

    progressIndicator.style = .spinning
    progressIndicator.controlSize = .small
    progressIndicator.isDisplayedWhenStopped = false
    progressIndicator.isHidden = true
    progressLabel.isHidden = true
    progressLabel.textColor = .secondaryLabelColor

    cancelButton.title = L10n.Common.cancel
    cancelButton.bezelStyle = .rounded
    cancelButton.target = self
    cancelButton.action = #selector(cancelPressed)
    cancelButton.keyEquivalent = "\u{1b}"

    mergeButton.title = L10n.RecordingParity.audioMixerMerge
    mergeButton.bezelStyle = .rounded
    mergeButton.target = self
    mergeButton.action = #selector(mergeAudio)
    mergeButton.keyEquivalent = "\r"

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let buttons = NSStackView(views: [progressIndicator, progressLabel, spacer, cancelButton, mergeButton])
    buttons.orientation = .horizontal
    buttons.spacing = 8

    let stack = NSStackView(views: [playerView, prompt, grid, buttons])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 14
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
    stack.translatesAutoresizingMaskIntoConstraints = false

    let content = NSView()
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      stack.topAnchor.constraint(equalTo: content.topAnchor),
      stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      playerView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
      playerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
      buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
      microphoneSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
    ])
    window.contentView = content
    setVolumes(.default)
  }

  private func configure(slider: NSSlider, action: Selector, label: String) {
    slider.minValue = Double(RecordingAudioMixerVolumes.range.lowerBound)
    slider.maxValue = Double(RecordingAudioMixerVolumes.range.upperBound)
    slider.isContinuous = true
    slider.target = self
    slider.action = action
    slider.setAccessibilityLabel(label)
  }
}
