//
//  RecordingLifecycleGuards.swift
//  Snapzy
//
//  Проверки и предупреждения жизненного цикла записи по образцу эталона:
//  место на диске, камера без микрофона, закрытая крышка, заглушённый микрофон,
//  отключение микрофона, сбой системного звука, сведение дорожек, запрет сна
//  дисплея и звуки старта и паузы.
//

import AppKit
import AVFoundation
import CoreAudio
import IOKit

nonisolated enum RecordingLifecycleKeys {
  /// Не предупреждать о малом месте на диске перед записью.
  static let suppressLowDiskWarning = "ownshot.recording.warn.lowDisk.suppressed"
  /// Не спрашивать про камеру без микрофона.
  static let suppressNoMicrophoneWarning = "ownshot.recording.warn.noMicrophone.suppressed"
  /// warnAboutMutedMicrophone у эталона. По умолчанию включено.
  static let warnAboutMutedMicrophone = "ownshot.recording.warn.mutedMicrophone"
}

nonisolated enum RecordingLifecycleText {
  static func startErrorMessage(underlying: String) -> String {
    let base = L10n.RecordingParity.startErrorMessage
    let detail = underlying.trimmingCharacters(in: .whitespacesAndNewlines)
    return detail.isEmpty ? base : base + "\n\n" + detail
  }
}

// MARK: - Диск

nonisolated enum RecordingDiskSpace {
  enum Level: Equatable {
    case ok
    /// Перед стартом предупредить.
    case low
    /// Во время записи остановить.
    case critical
  }

  /// Пороги эталона неизвестны. Выбраны с запасом под минуту записи 4K.
  static let lowThreshold: Int64 = 5 * 1024 * 1024 * 1024
  static let criticalThreshold: Int64 = 512 * 1024 * 1024

  static func level(availableBytes: Int64?) -> Level {
    guard let availableBytes else { return .ok }
    if availableBytes < criticalThreshold { return .critical }
    if availableBytes < lowThreshold { return .low }
    return .ok
  }

  static func availableBytes(at url: URL) -> Int64? {
    let values = try? url.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
    ])
    if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
    return values?.volumeAvailableCapacity.map(Int64.init)
  }
}

// MARK: - Решение о предупреждениях перед стартом

nonisolated enum RecordingStartWarning: Equatable {
  case lowDisk
  case cameraWithoutMicrophone
  case builtInMicrophoneWithClosedLid
  case mutedMicrophone
}

nonisolated struct RecordingStartConditions: Equatable {
  var diskLevel: RecordingDiskSpace.Level
  var captureCamera: Bool
  var captureMicrophone: Bool
  var microphoneIsBuiltIn: Bool
  var lidClosed: Bool
  var microphoneMuted: Bool
  var lowDiskSuppressed: Bool
  var noMicrophoneSuppressed: Bool
  var warnAboutMutedMicrophone: Bool
}

nonisolated enum RecordingStartWarnings {
  /// Предупреждения в порядке показа. Пустой список – запись стартует сразу.
  static func warnings(for conditions: RecordingStartConditions) -> [RecordingStartWarning] {
    var result: [RecordingStartWarning] = []
    if conditions.diskLevel != .ok, !conditions.lowDiskSuppressed {
      result.append(.lowDisk)
    }
    if conditions.captureCamera, !conditions.captureMicrophone, !conditions.noMicrophoneSuppressed {
      result.append(.cameraWithoutMicrophone)
    }
    if conditions.captureMicrophone, conditions.microphoneIsBuiltIn, conditions.lidClosed {
      result.append(.builtInMicrophoneWithClosedLid)
    } else if conditions.captureMicrophone, conditions.microphoneMuted, conditions.warnAboutMutedMicrophone {
      result.append(.mutedMicrophone)
    }
    return result
  }
}

// MARK: - Системный звук

/// Снимок записи системного звука из RecordingSession.
nonisolated struct RecordingSystemAudioHealth: Equatable {
  var samplesReceived: Int
  var appendFailed: Bool
}

/// Решает, когда показать Audio Recording Failed. Срабатывает один раз за запись:
/// при сбое записи в дорожку, если звук не пришёл ни разу за `startTimeout`
/// или перестал приходить на `stallTimeout`. Пауза сдвигает отсчёт.
nonisolated struct RecordingSystemAudioWatchdog {
  /// SCStream присылает и тишину, поэтому пустой поток дольше этих сроков – сбой.
  static let defaultStartTimeout: TimeInterval = 10
  static let defaultStallTimeout: TimeInterval = 20

  let startTimeout: TimeInterval
  let stallTimeout: TimeInterval
  private(set) var hasFired = false
  private var lastCount = 0
  private var lastProgress: TimeInterval?

  init(
    startTimeout: TimeInterval = Self.defaultStartTimeout,
    stallTimeout: TimeInterval = Self.defaultStallTimeout
  ) {
    self.startTimeout = startTimeout
    self.stallTimeout = stallTimeout
  }

  /// true – пора спросить пользователя. После срабатывания всегда false.
  mutating func observe(_ health: RecordingSystemAudioHealth, isPaused: Bool, now: TimeInterval) -> Bool {
    guard !hasFired else { return false }
    if health.appendFailed { return fire() }
    guard let since = lastProgress else {
      lastProgress = now
      lastCount = health.samplesReceived
      return false
    }
    if isPaused || health.samplesReceived > lastCount {
      lastCount = health.samplesReceived
      lastProgress = now
      return false
    }
    let timeout = lastCount == 0 ? startTimeout : stallTimeout
    return now - since >= timeout ? fire() : false
  }

  private mutating func fire() -> Bool {
    hasFired = true
    return true
  }
}

// MARK: - Сведение дорожек

/// Почему микрофон и системный звук остались на отдельных дорожках.
nonisolated enum RecordingAudioMergeIssue: Equatable {
  /// Сведение упало (audioMixer_error).
  case failed
  /// Не хватает места на диске (audioMixer_disk_error).
  case lowDisk
  /// Пользователь остановил сведение.
  case cancelled

  /// Отменённое пользователем сведение отдельного сообщения не требует.
  var alertMessage: String? {
    switch self {
    case .failed: return L10n.RecordingParity.mergeFailedMessage
    case .lowDisk: return L10n.RecordingParity.mergeDiskLowMessage
    case .cancelled: return nil
    }
  }
}

nonisolated enum RecordingAudioMergeDiskPolicy {
  /// Запас сверх копии файла: сведённый файл и временная копия исходных дорожек.
  static let reserveBytes: Int64 = 256 * 1024 * 1024

  /// Сведение пишет новый файл и сохраняет копию исходника для редактора: нужно
  /// примерно два размера записи и запас.
  static func requiredBytes(sourceFileBytes: Int64) -> Int64 {
    max(0, sourceFileBytes) * 2 + reserveBytes
  }

  static func hasEnoughSpace(sourceFileBytes: Int64, availableBytes: Int64?) -> Bool {
    guard let availableBytes else { return true }
    return availableBytes >= requiredBytes(sourceFileBytes: sourceFileBytes)
  }
}

/// Флаг отмены сведения: выставляется с главного потока, читается в цикле копирования.
nonisolated final class RecordingAudioMergeCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  init() {}

  var isCancelled: Bool { lock.withLock { cancelled } }

  func cancel() { lock.withLock { cancelled = true } }
}

// MARK: - Сохранение

nonisolated enum RecordingSaveFailurePolicy {
  /// stopRecording() отдаёт nil и при сбое сохранения, и когда записи ещё не было
  /// (Stop во время подготовки). Ошибку показываем только в первом случае.
  static func shouldReportSaveFailure(outputURL: URL?, wasRecording: Bool) -> Bool {
    outputURL == nil && wasRecording
  }
}

// MARK: - GIF

/// Выбор в диалоге Are you sure you want to stop the conversion?
nonisolated enum RecordingGIFCancelChoice: Equatable {
  case saveAsVideo
  case deleteRecording
  case continueConverting

  /// Порядок кнопок алерта: первая – Save as Video, вторая – Delete Recording.
  static func from(buttonIndex: Int) -> RecordingGIFCancelChoice {
    switch buttonIndex {
    case 0: return .saveAsVideo
    case 1: return .deleteRecording
    default: return .continueConverting
    }
  }
}

/// Tracks cancel choices with their own conversion even when another recording finishes.
nonisolated struct RecordingGIFConversions {
  struct Conversion {
    let task: Task<URL, Error>
    let id: UUID
    let itemID: UUID?
    var cancelChoice: RecordingGIFCancelChoice?
  }

  private var active: [Conversion] = []

  func activeConversion(for itemID: UUID?) -> Conversion? {
    active.last { itemID == nil || $0.itemID == itemID }
  }

  func acceptsProgress(for id: UUID) -> Bool {
    active.contains { $0.id == id && $0.cancelChoice == nil }
  }

  mutating func start(_ task: Task<URL, Error>, id: UUID, itemID: UUID?) {
    active.append(Conversion(task: task, id: id, itemID: itemID))
  }

  @discardableResult
  mutating func cancel(_ task: Task<URL, Error>, choice: RecordingGIFCancelChoice) -> Bool {
    guard choice != .continueConverting,
          let index = active.firstIndex(where: { $0.task == task }),
          active[index].cancelChoice == nil else { return false }
    active[index].cancelChoice = choice
    task.cancel()
    return true
  }

  mutating func finish(_ task: Task<URL, Error>) -> RecordingGIFCancelChoice? {
    guard let index = active.firstIndex(where: { $0.task == task }) else { return nil }
    return active.remove(at: index).cancelChoice
  }
}

// MARK: - Системные пробы

nonisolated enum RecordingHardwareProbe {
  /// Закрыта ли крышка MacBook (AppleClamshellState у IOPMrootDomain).
  static func isLidClosed() -> Bool {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return false }
    defer { IOObjectRelease(service) }
    let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
    return (value?.takeRetainedValue() as? Bool) ?? false
  }

  /// CoreAudio-устройство выбранного микрофона. UID AVCaptureDevice совпадает с UID CoreAudio.
  static func audioDeviceID(forCaptureDeviceID deviceID: String?) -> AudioDeviceID? {
    let normalized = RecordingMicrophoneDeviceProvider.normalizedCaptureDeviceID(deviceID)
    if let uid = normalized {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      var cfUID = uid as CFString
      var device = AudioDeviceID(kAudioObjectUnknown)
      var size = UInt32(MemoryLayout<AudioDeviceID>.size)
      let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
        AudioObjectGetPropertyData(
          AudioObjectID(kAudioObjectSystemObject), &address,
          UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &device
        )
      }
      if status == noErr, device != kAudioObjectUnknown { return device }
      return nil
    }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return status == noErr && device != kAudioObjectUnknown ? device : nil
  }

  static func isBuiltIn(_ device: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var transport: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
    return status == noErr && transport == kAudioDeviceTransportTypeBuiltIn
  }

  /// Вход заглушён флагом Mute или громкостью 0.
  static func isMuted(_ device: AudioDeviceID) -> Bool {
    var muteAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyMute,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    if AudioObjectHasProperty(device, &muteAddress) {
      var muted: UInt32 = 0
      var size = UInt32(MemoryLayout<UInt32>.size)
      if AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &muted) == noErr, muted != 0 {
        return true
      }
    }
    for element in [kAudioObjectPropertyElementMain, 1] {
      var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: element
      )
      guard AudioObjectHasProperty(device, &volumeAddress) else { continue }
      var volume: Float32 = 1
      var size = UInt32(MemoryLayout<Float32>.size)
      if AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &volume) == noErr {
        return volume <= 0.001
      }
    }
    return false
  }
}

// MARK: - Показ предупреждений

@MainActor
enum RecordingStartWarningPresenter {
  enum Outcome: Equatable {
    case proceed
    /// Стартовать без микрофона.
    case proceedWithoutMicrophone
    /// Вернуться к панели записи.
    case cancel
  }

  static func conditions(
    saveDirectory: URL,
    captureCamera: Bool,
    captureMicrophone: Bool,
    microphoneDeviceID: String?,
    defaults: UserDefaults = .standard
  ) -> RecordingStartConditions {
    let device = captureMicrophone ? RecordingHardwareProbe.audioDeviceID(forCaptureDeviceID: microphoneDeviceID) : nil
    return RecordingStartConditions(
      diskLevel: RecordingDiskSpace.level(availableBytes: RecordingDiskSpace.availableBytes(at: saveDirectory)),
      captureCamera: captureCamera,
      captureMicrophone: captureMicrophone,
      microphoneIsBuiltIn: device.map(RecordingHardwareProbe.isBuiltIn) ?? false,
      lidClosed: captureMicrophone ? RecordingHardwareProbe.isLidClosed() : false,
      microphoneMuted: device.map(RecordingHardwareProbe.isMuted) ?? false,
      lowDiskSuppressed: defaults.bool(forKey: RecordingLifecycleKeys.suppressLowDiskWarning),
      noMicrophoneSuppressed: defaults.bool(forKey: RecordingLifecycleKeys.suppressNoMicrophoneWarning),
      warnAboutMutedMicrophone: defaults.object(forKey: RecordingLifecycleKeys.warnAboutMutedMicrophone) as? Bool ?? true
    )
  }

  /// Показывает предупреждения по очереди. Выбор пользователя решает, стартовать ли.
  static func present(_ warnings: [RecordingStartWarning], defaults: UserDefaults = .standard) -> Outcome {
    var outcome = Outcome.proceed
    for warning in warnings {
      let alert = makeAlert()
      switch warning {
      case .lowDisk:
        alert.messageText = L10n.RecordingParity.diskLowTitle
        alert.informativeText = L10n.RecordingParity.diskLowMessage
        alert.addButton(withTitle: L10n.RecordingParity.continueRecording)
        alert.addButton(withTitle: L10n.Common.cancel)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L10n.RecordingParity.dontWarnAgain
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
          defaults.set(true, forKey: RecordingLifecycleKeys.suppressLowDiskWarning)
        }
        guard response == .alertFirstButtonReturn else { return .cancel }
      case .cameraWithoutMicrophone:
        alert.messageText = L10n.RecordingParity.noMicrophoneTitle
        alert.informativeText = L10n.RecordingParity.noMicrophoneMessage
        alert.addButton(withTitle: L10n.RecordingParity.dontRecordAudio)
        alert.addButton(withTitle: L10n.RecordingParity.showPreferences)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L10n.RecordingParity.dontAskAgain
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
          defaults.set(true, forKey: RecordingLifecycleKeys.suppressNoMicrophoneWarning)
        }
        // Show preferences возвращает к панели, где выбирается микрофон.
        guard response == .alertFirstButtonReturn else { return .cancel }
      case .builtInMicrophoneWithClosedLid:
        alert.messageText = L10n.RecordingParity.lidClosedMessage
        alert.informativeText = ""
        alert.addButton(withTitle: L10n.RecordingParity.dontRecordAudio)
        alert.addButton(withTitle: L10n.Common.cancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return .cancel }
        outcome = .proceedWithoutMicrophone
      case .mutedMicrophone:
        alert.messageText = L10n.RecordingParity.microphoneMutedTitle
        alert.informativeText = L10n.RecordingParity.microphoneMutedMessage
        alert.addButton(withTitle: L10n.RecordingParity.continueRecording)
        alert.addButton(withTitle: L10n.Common.cancel)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L10n.RecordingParity.dontWarnAgain
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
          defaults.set(false, forKey: RecordingLifecycleKeys.warnAboutMutedMicrophone)
        }
        guard response == .alertFirstButtonReturn else { return .cancel }
      }
    }
    return outcome
  }

  /// Сообщение после остановки записи (обрыв потока или заполненный диск).
  static func presentStopped(title: String, message: String) {
    let alert = makeAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: L10n.Common.ok)
    alert.runModal()
  }

  /// Микрофон пропал во время записи. true – продолжить без звука, false – остановить.
  static func presentMicrophoneDisconnected() -> Bool {
    let alert = makeAlert()
    alert.messageText = L10n.RecordingParity.microphoneDisconnectedTitle
    alert.informativeText = L10n.RecordingParity.microphoneDisconnectedMessage
    alert.addButton(withTitle: L10n.RecordingParity.continueWithoutAudio)
    alert.addButton(withTitle: L10n.RecordingParity.stopRecording)
    return alert.runModal() == .alertFirstButtonReturn
  }

  /// Системный звук пропал во время записи. true – продолжить без звука, false – остановить.
  static func presentSystemAudioFailed() -> Bool {
    let alert = makeAlert()
    alert.messageText = L10n.RecordingParity.audioRecordingFailedTitle
    alert.informativeText = L10n.RecordingParity.audioRecordingFailedMessage
    alert.addButton(withTitle: L10n.RecordingParity.continueWithoutAudio)
    alert.addButton(withTitle: L10n.RecordingParity.stopRecording)
    return alert.runModal() == .alertFirstButtonReturn
  }

  /// Дорожки не свели: запись цела, микрофон и системный звук остались раздельными.
  static func presentAudioMergeIssue(_ issue: RecordingAudioMergeIssue) {
    guard let message = issue.alertMessage else { return }
    presentStopped(title: L10n.RecordingParity.mergeFailedTitle, message: message)
  }

  /// Подтверждение отмены сведения. true – остановить сведение.
  static func confirmStopAudioMerge() -> Bool {
    let alert = makeAlert()
    alert.messageText = L10n.RecordingParity.stopProcessingTitle
    alert.informativeText = L10n.RecordingParity.stopProcessingMessage
    alert.addButton(withTitle: L10n.RecordingParity.stopProcessing)
    alert.addButton(withTitle: L10n.RecordingParity.continueProcessing)
    return alert.runModal() == .alertFirstButtonReturn
  }

  /// Закрытие Audio Mixer без сведения: дорожки остаются раздельными.
  /// Под XCTest модальное окно не показывается, закрытие разрешено.
  static func confirmKeepSeparateAudioTracks() -> Bool {
    guard !isRunningUnderXCTest else { return true }
    let alert = makeAlert()
    alert.messageText = L10n.RecordingParity.audioMixerKeepSeparateTitle
    alert.informativeText = L10n.RecordingParity.audioMixerKeepSeparateMessage
    alert.addButton(withTitle: L10n.RecordingParity.continueProcessing)
    alert.addButton(withTitle: L10n.Common.cancel)
    return alert.runModal() == .alertFirstButtonReturn
  }

  /// Ошибка сведения в Audio Mixer.
  static func presentAudioMixerFailure(message: String) {
    guard !isRunningUnderXCTest else { return }
    let alert = makeAlert()
    alert.messageText = L10n.RecordingParity.mergeFailedTitle
    alert.informativeText = message
    alert.addButton(withTitle: L10n.Common.ok)
    alert.runModal()
  }

  private static var isRunningUnderXCTest: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  /// Подтверждение отмены конвертации в GIF.
  static func confirmStopGIFConversion() -> RecordingGIFCancelChoice {
    let alert = makeAlert()
    alert.messageText = L10n.RecordingParity.stopConversionTitle
    alert.informativeText = L10n.RecordingParity.stopConversionMessage
    alert.addButton(withTitle: L10n.RecordingParity.saveAsVideo)
    alert.addButton(withTitle: L10n.RecordingParity.deleteRecording)
    alert.addButton(withTitle: L10n.RecordingParity.continueConversion)
    let response = alert.runModal()
    return .from(buttonIndex: response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
  }

  /// Запись не сохранилась.
  static func presentSaveFailed(detail: String?) {
    presentStopped(title: L10n.RecordingParity.saveFailedTitle, message: detail ?? "")
  }

  private static func makeAlert() -> NSAlert {
    let alert = NSAlert()
    alert.alertStyle = .warning
    // Панель записи висит на уровне pop-up menu, алерт должен быть выше.
    alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
    NSApp.activate(ignoringOtherApps: true)
    return alert
  }
}

// MARK: - Во время записи

/// Держит дисплей включённым, пока идёт запись.
@MainActor
final class RecordingDisplaySleepAssertion {
  private var activity: NSObjectProtocol?

  var isActive: Bool { activity != nil }

  func begin() {
    guard activity == nil else { return }
    activity = ProcessInfo.processInfo.beginActivity(
      options: [.idleDisplaySleepDisabled, .userInitiated],
      reason: "Screen recording in progress"
    )
  }

  func end() {
    guard let activity else { return }
    ProcessInfo.processInfo.endActivity(activity)
    self.activity = nil
  }
}

/// Раз в несколько секунд проверяет место на диске и сообщает о критическом уровне.
@MainActor
final class RecordingDiskSpaceMonitor {
  private var timer: Timer?
  private let interval: TimeInterval
  private let probe: (URL) -> Int64?

  init(interval: TimeInterval = 5, probe: @escaping (URL) -> Int64? = RecordingDiskSpace.availableBytes(at:)) {
    self.interval = interval
    self.probe = probe
  }

  func start(directory: URL, onCritical: @escaping @MainActor () -> Void) {
    stop()
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.check(directory: directory) == .critical else { return }
        self.stop()
        onCritical()
      }
    }
  }

  @discardableResult
  func check(directory: URL) -> RecordingDiskSpace.Level {
    RecordingDiskSpace.level(availableBytes: probe(directory))
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }
}

/// Следит за отключением выбранного микрофона во время записи.
@MainActor
final class RecordingMicrophoneDisconnectMonitor {
  private var observer: NSObjectProtocol?

  func start(deviceID: String?, onDisconnect: @escaping @MainActor () -> Void) {
    stop()
    guard let device = RecordingMicrophoneDeviceProvider.captureDevice(matching: deviceID) else { return }
    let uniqueID = device.uniqueID
    observer = NotificationCenter.default.addObserver(
      forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let disconnected = notification.object as? AVCaptureDevice,
            disconnected.uniqueID == uniqueID else { return }
      MainActor.assumeIsolated {
        self?.stop()
        onDisconnect()
      }
    }
  }

  func stop() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
  }
}
