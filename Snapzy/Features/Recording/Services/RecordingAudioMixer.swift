//
//  RecordingAudioMixer.swift
//  Snapzy
//
//  Сведение микрофона и системного звука с громкостями из окна Audio Mixer,
//  как AudioMixer эталона (micVolume, audioVolume, mergeAudio). Работает с уже
//  записанными дорожками: раздельными в самом видео или сохранёнными до
//  автоматического сведения в RecordingMetadataStore.
//

import AVFoundation
import Foundation

/// Откуда брать раздельные дорожки для сведения.
struct RecordingAudioMixerSource: Equatable {
  enum Kind: Equatable {
    /// Видео записано с Separate tracks: обе дорожки в самом файле.
    case separateTracksInVideo
    /// Видео уже сведено, исходник с раздельными дорожками лежит в хранилище.
    case storedAudioSource
  }

  let videoURL: URL
  let sourceURL: URL
  let kind: Kind
  let systemAudioTrackID: CMPersistentTrackID
  let microphoneTrackID: CMPersistentTrackID
}

/// Положения ползунков. 100% повторяет автоматическое сведение, 200% – полный уровень дорожки.
struct RecordingAudioMixerVolumes: Equatable {
  static let range: ClosedRange<Float> = 0...2
  static let `default` = RecordingAudioMixerVolumes(microphone: 1, systemAudio: 1)

  var microphone: Float
  var systemAudio: Float

  init(microphone: Float, systemAudio: Float) {
    self.microphone = Self.clamped(microphone)
    self.systemAudio = Self.clamped(systemAudio)
  }

  static func clamped(_ value: Float) -> Float {
    guard value.isFinite else { return 1 }
    return min(range.upperBound, max(range.lowerBound, value))
  }

  /// Множитель дорожки: запас под сведение двух дорожек, как у автоматического сведения.
  static func gain(for slider: Float) -> Float {
    clamped(slider) * RecordingAudioCompatibilityExporter.mixdownInputVolume(audioTrackCount: 2)
  }

  func trackVolumes(for source: RecordingAudioMixerSource) -> [CMPersistentTrackID: Float] {
    [
      source.microphoneTrackID: Self.gain(for: microphone),
      source.systemAudioTrackID: Self.gain(for: systemAudio),
    ]
  }

  static func percentText(_ value: Float) -> String {
    "\(Int((clamped(value) * 100).rounded()))%"
  }

  /// Для журнала, как события audioMixer_merge_originalvolume / editedvolume эталона.
  var isOriginal: Bool { self == .default }
}

enum RecordingAudioMixer {
  /// Чистая логика выбора источника: дорожки видео, затем сохранённый исходник.
  static func resolveSource(
    videoURL: URL,
    videoAudioTrackIDs: [CMPersistentTrackID],
    metadata: RecordingMetadata?,
    storedSourceAudioTrackIDs: [CMPersistentTrackID]?
  ) -> RecordingAudioMixerSource? {
    let videoTracks = videoAudioTrackIDs.sorted()
    if videoTracks.count == 2 {
      // Порядок дорожек записи: системный звук, затем микрофон.
      return makeSource(videoURL: videoURL, sourceURL: videoURL, kind: .separateTracksInVideo,
                        trackIDs: videoTracks, roles: defaultRoles)
    }
    guard let metadata, let sourceURL = metadata.audioSourceURL,
          let storedTracks = storedSourceAudioTrackIDs?.sorted(), storedTracks.count == 2 else {
      return nil
    }
    return makeSource(videoURL: videoURL, sourceURL: sourceURL, kind: .storedAudioSource,
                      trackIDs: storedTracks, roles: storedRoles(metadata, trackIDs: storedTracks))
  }

  private static let defaultRoles: [RecordingAudioSourceTrackRole] = [.systemAudio, .microphone]

  /// Роли дорожек сохранённого исходника: по trackID, затем по порядку, иначе порядок записи.
  private static func storedRoles(
    _ metadata: RecordingMetadata,
    trackIDs: [CMPersistentTrackID]
  ) -> [RecordingAudioSourceTrackRole] {
    let byID = Dictionary(
      metadata.audioSourceTracks.map { (CMPersistentTrackID($0.trackID), $0.role) },
      uniquingKeysWith: { first, _ in first }
    )
    let mapped = trackIDs.compactMap { byID[$0] }
    if mapped.count == trackIDs.count { return mapped }
    if metadata.audioSourceTrackRoles.count == trackIDs.count { return metadata.audioSourceTrackRoles }
    return defaultRoles
  }

  private static func makeSource(
    videoURL: URL,
    sourceURL: URL,
    kind: RecordingAudioMixerSource.Kind,
    trackIDs: [CMPersistentTrackID],
    roles: [RecordingAudioSourceTrackRole]
  ) -> RecordingAudioMixerSource? {
    guard trackIDs.count == 2, roles.count == 2,
          let systemIndex = roles.firstIndex(of: .systemAudio),
          let microphoneIndex = roles.firstIndex(of: .microphone) else { return nil }
    return RecordingAudioMixerSource(
      videoURL: videoURL,
      sourceURL: sourceURL,
      kind: kind,
      systemAudioTrackID: trackIDs[systemIndex],
      microphoneTrackID: trackIDs[microphoneIndex]
    )
  }

  /// Быстрая синхронная проверка для пункта меню карточки.
  static func source(for videoURL: URL) -> RecordingAudioMixerSource? {
    guard videoURL.isFileURL, FileManager.default.fileExists(atPath: videoURL.path) else { return nil }
    let metadata = RecordingMetadataStore.load(for: videoURL)
    var storedTracks: [CMPersistentTrackID]?
    if let sourceURL = metadata?.audioSourceURL, FileManager.default.fileExists(atPath: sourceURL.path) {
      storedTracks = audioTrackIDs(at: sourceURL)
    }
    return resolveSource(
      videoURL: videoURL,
      videoAudioTrackIDs: audioTrackIDs(at: videoURL),
      metadata: metadata,
      storedSourceAudioTrackIDs: storedTracks
    )
  }

  /// Синхронное чтение заголовка локального файла: меню собирается в момент открытия.
  private static func audioTrackIDs(at url: URL) -> [CMPersistentTrackID] {
    AVURLAsset(url: url).tracks(withMediaType: .audio).map(\.trackID)
  }

  /// Сведение с громкостями. Для видео с раздельными дорожками исходник сначала
  /// сохраняется в хранилище, чтобы громкости можно было поменять ещё раз.
  static func merge(
    _ source: RecordingAudioMixerSource,
    volumes: RecordingAudioMixerVolumes,
    mono: Bool = UserDefaults.standard.bool(forKey: OwnShotRecordingPreferenceKeys.mono),
    cancellation: RecordingAudioMergeCancellation? = nil
  ) async throws {
    let destinationRevision = try CaptureFilePublication.DestinationRevision.existing(at: source.videoURL)
    let fileType: AVFileType = source.videoURL.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
    var mixSourceURL = source.sourceURL
    var storedSourceURL: URL?
    if source.kind == .separateTracksInVideo {
      let stored = try RecordingMetadataStore.storeAudioSource(from: source.videoURL)
      storedSourceURL = stored
      mixSourceURL = stored
    }
    do {
      try await RecordingAudioCompatibilityExporter.mixTracks(
        from: mixSourceURL,
        into: source.videoURL,
        fileType: fileType,
        volumes: volumes.trackVolumes(for: source),
        mono: mono,
        cancellation: cancellation,
        expectedDestinationRevision: destinationRevision
      )
    } catch {
      if let storedSourceURL { try? FileManager.default.removeItem(at: storedSourceURL) }
      throw error
    }
    if let storedSourceURL {
      saveStoredSourceMetadata(storedSourceURL, for: source)
    }
    DiagnosticLogger.shared.log(.info, .recording, "Audio mixer merged tracks", context: [
      "file": source.videoURL.lastPathComponent,
      "kind": "\(source.kind)",
      "volume": volumes.isOriginal ? "original" : "edited",
      "microphone": RecordingAudioMixerVolumes.percentText(volumes.microphone),
      "systemAudio": RecordingAudioMixerVolumes.percentText(volumes.systemAudio),
    ])
  }

  /// Метаданные получают сохранённый исходник и роли его дорожек.
  private static func saveStoredSourceMetadata(_ storedURL: URL, for source: RecordingAudioMixerSource) {
    let tracks = [
      RecordingAudioSourceTrack(trackID: Int(source.systemAudioTrackID), role: .systemAudio),
      RecordingAudioSourceTrack(trackID: Int(source.microphoneTrackID), role: .microphone),
    ].sorted { $0.trackID < $1.trackID }
    var metadata = RecordingMetadataStore.load(for: source.videoURL)
      ?? RecordingMetadata(captureSize: .zero, samplesPerSecond: 60, mouseSamples: [])
    if let previous = metadata.audioSourceURL, previous != storedURL {
      try? FileManager.default.removeItem(at: previous)
    }
    metadata.audioSourceURL = storedURL
    metadata.audioSourceTracks = tracks
    metadata.audioSourceTrackRoles = tracks.map(\.role)
    do {
      try RecordingMetadataStore.save(metadata, for: source.videoURL)
    } catch {
      DiagnosticLogger.shared.logError(.recording, error, "Audio mixer failed to save metadata")
      try? FileManager.default.removeItem(at: storedURL)
    }
  }
}
