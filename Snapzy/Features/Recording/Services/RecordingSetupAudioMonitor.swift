//
//  RecordingSetupAudioMonitor.swift
//  Snapzy
//
//  VU-метр на кнопках микрофона и системного звука в панели записи до старта,
//  как VUMeter эталона: свой лёгкий AVCaptureSession для микрофона и SCStream
//  для системного звука. Источники живут только пока открыта панель записи.
//

import AVFoundation
import Combine
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Источник проб уровня. Реальные пробы держат захват, в тестах подменяются.
protocol RecordingSetupAudioProbe: AnyObject {
  func start()
  func stop()
}

protocol RecordingSetupAudioProbeFactory {
  func makeMicrophoneProbe(deviceID: String, meter: RecordingAudioLevelMeter) -> RecordingSetupAudioProbe?
  func makeSystemAudioProbe(meter: RecordingAudioLevelMeter) -> RecordingSetupAudioProbe?
}

@MainActor
final class RecordingSetupAudioMonitor: ObservableObject {
  /// Какие пробы нужны сейчас: nil у микрофона – микрофон не слушается.
  struct Demand: Equatable {
    var microphoneDeviceID: String?
    var systemAudio: Bool

    static let none = Demand(microphoneDeviceID: nil, systemAudio: false)
  }

  /// Метр микрофона, нормированный уровень 0...1.
  let microphoneMeter = RecordingAudioLevelMeter()
  /// Метр системного звука, нормированный уровень 0...1.
  let systemAudioMeter = RecordingAudioLevelMeter()

  private let factory: RecordingSetupAudioProbeFactory
  private(set) var demand: Demand = .none
  private var microphoneProbe: RecordingSetupAudioProbe?
  private var systemAudioProbe: RecordingSetupAudioProbe?
  private var subscription: AnyCancellable?

  init(factory: RecordingSetupAudioProbeFactory? = nil) {
    self.factory = factory ?? RecordingSetupLiveAudioProbeFactory.makeDefault()
  }

  /// Пробы нужны только на открытой панели до старта записи.
  static func demand(
    isActive: Bool,
    captureMicrophone: Bool,
    microphoneDeviceID: String,
    captureSystemAudio: Bool
  ) -> Demand {
    guard isActive else { return .none }
    return Demand(
      microphoneDeviceID: captureMicrophone ? microphoneDeviceID : nil,
      systemAudio: captureSystemAudio
    )
  }

  /// Следит за кнопками панели и перезапускает пробы при смене источника.
  func observe(_ state: RecordingToolbarState) {
    subscription = state.$captureMicrophone
      .combineLatest(state.$microphoneDeviceID, state.$captureAudio, state.$isPreparingToRecord)
      .sink { [weak self] captureMicrophone, deviceID, captureAudio, isPreparing in
        // Публикация приходит в willSet, значения берутся из аргументов.
        self?.apply(Self.demand(
          isActive: !isPreparing,
          captureMicrophone: captureMicrophone,
          microphoneDeviceID: deviceID,
          captureSystemAudio: captureAudio
        ))
      }
  }

  func apply(_ newDemand: Demand) {
    if newDemand.microphoneDeviceID != demand.microphoneDeviceID {
      microphoneProbe?.stop()
      microphoneProbe = nil
      microphoneMeter.reset()
      if let deviceID = newDemand.microphoneDeviceID {
        microphoneProbe = factory.makeMicrophoneProbe(deviceID: deviceID, meter: microphoneMeter)
        microphoneProbe?.start()
      }
    }
    if newDemand.systemAudio != demand.systemAudio {
      systemAudioProbe?.stop()
      systemAudioProbe = nil
      systemAudioMeter.reset()
      if newDemand.systemAudio {
        systemAudioProbe = factory.makeSystemAudioProbe(meter: systemAudioMeter)
        systemAudioProbe?.start()
      }
    }
    demand = newDemand
  }

  /// Закрытие панели или старт записи: захват освобождается сразу.
  func stop() {
    subscription = nil
    apply(.none)
  }

  var isMonitoringMicrophone: Bool { microphoneProbe != nil }
  var isMonitoringSystemAudio: Bool { systemAudioProbe != nil }
}

// MARK: - Реальные пробы

struct RecordingSetupLiveAudioProbeFactory: RecordingSetupAudioProbeFactory {
  /// Под XCTest захват не стартует: тестовый хост не должен трогать микрофон и экран.
  static func makeDefault(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> RecordingSetupAudioProbeFactory {
    if environment["XCTestConfigurationFilePath"] != nil {
      return RecordingSetupDisabledAudioProbeFactory()
    }
    return RecordingSetupLiveAudioProbeFactory()
  }

  func makeMicrophoneProbe(deviceID: String, meter: RecordingAudioLevelMeter) -> RecordingSetupAudioProbe? {
    // Метр не просит доступ: без разрешения кнопка остаётся без уровня.
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return nil }
    return RecordingSetupMicrophoneLevelProbe(deviceID: deviceID, meter: meter)
  }

  func makeSystemAudioProbe(meter: RecordingAudioLevelMeter) -> RecordingSetupAudioProbe? {
    guard CGPreflightScreenCaptureAccess() else { return nil }
    return RecordingSetupSystemAudioLevelProbe(meter: meter)
  }
}

struct RecordingSetupDisabledAudioProbeFactory: RecordingSetupAudioProbeFactory {
  func makeMicrophoneProbe(deviceID _: String, meter _: RecordingAudioLevelMeter) -> RecordingSetupAudioProbe? { nil }
  func makeSystemAudioProbe(meter _: RecordingAudioLevelMeter) -> RecordingSetupAudioProbe? { nil }
}

/// Микрофон через тот же MicrophoneAudioCapturer, что и запись, но со своей сессией.
final class RecordingSetupMicrophoneLevelProbe: RecordingSetupAudioProbe {
  private let capturer: MicrophoneAudioCapturer
  private let forwarder: Forwarder

  init(deviceID: String, meter: RecordingAudioLevelMeter) {
    capturer = MicrophoneAudioCapturer(preferredDeviceID: deviceID)
    forwarder = Forwarder(meter: meter)
    capturer.delegate = forwarder
  }

  func start() { capturer.start() }
  func stop() { capturer.stop() }

  private nonisolated final class Forwarder: MicrophoneAudioCapturerDelegate, @unchecked Sendable {
    let meter: RecordingAudioLevelMeter
    init(meter: RecordingAudioLevelMeter) { self.meter = meter }

    func microphoneCapturer(_: MicrophoneAudioCapturer, didOutput sampleBuffer: CMSampleBuffer) {
      meter.ingest(sampleBuffer, source: .microphone)
    }
  }
}

/// Системный звук через SCStream с кадром 2×2 раз в секунду: нужен только звук.
final class RecordingSetupSystemAudioLevelProbe: RecordingSetupAudioProbe {
  private let output: Output
  private var stream: SCStream?
  private var isStopped = false

  init(meter: RecordingAudioLevelMeter) {
    output = Output(meter: meter)
  }

  deinit {
    // Панель закрылась без stop(): поток не должен пережить пробу.
    if let stream { Task { try? await stream.stopCapture() } }
  }

  func start() {
    isStopped = false
    Task { @MainActor [weak self] in
      await self?.startStream()
    }
  }

  func stop() {
    isStopped = true
    guard let stream else { return }
    self.stream = nil
    Task { try? await stream.stopCapture() }
  }

  private func startStream() async {
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      guard !isStopped, let display = content.displays.first else { return }
      let filter = SCContentFilter(display: display, excludingWindows: [])
      let configuration = SCStreamConfiguration()
      configuration.width = 2
      configuration.height = 2
      configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
      configuration.showsCursor = false
      configuration.capturesAudio = true
      configuration.excludesCurrentProcessAudio = true
      configuration.sampleRate = Int(RecordingAudioEncodingSettings.sampleRate)
      configuration.channelCount = 2
      let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
      try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
      try await stream.startCapture()
      if isStopped {
        try? await stream.stopCapture()
        return
      }
      self.stream = stream
    } catch {
      DiagnosticLogger.shared.log(.debug, .recording, "Setup system audio meter unavailable", context: [
        "error": error.localizedDescription
      ])
    }
  }

  private nonisolated final class Output: NSObject, SCStreamOutput, @unchecked Sendable {
    let meter: RecordingAudioLevelMeter
    let queue = DispatchQueue(label: "com.ownshot.recording.setup-vu-meter", qos: .userInteractive)

    init(meter: RecordingAudioLevelMeter) { self.meter = meter }

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
      guard type == .audio, sampleBuffer.isValid else { return }
      meter.ingest(sampleBuffer, source: .system)
    }
  }
}
