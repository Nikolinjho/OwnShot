//
//  RecordingCrashRecovery.swift
//  Snapzy
//
//  Восстановление записи после аварийного выхода, как у эталона:
//  «CleanShot quit unexpectedly. Your screen recording has been successfully recovered.»
//  Писатель .mov ведёт фрагменты (ScreenRecordingManager.recordingFragmentInterval),
//  поэтому недописанный файл открывается до последнего фрагмента.
//

import AVFoundation
import Darwin
import Foundation

nonisolated enum RecordingCrashRecoveryScanner {
  static let videoExtensions: Set<String> = ["mov", "mp4"]

  typealias DirectoryListing = (URL, FileManager.DirectoryEnumerationOptions) throws -> [URL]
  typealias FileIdentity = CaptureFilePublication.SourceIdentity

  static func listDirectory(_ directory: URL, _ options: FileManager.DirectoryEnumerationOptions) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isHiddenKey], options: options
    )
  }

  static func isDiscarded(_ directory: URL) -> Bool {
    FileIdentity.at(RecordingProcessingSession.discardMarker(for: directory)) != nil
  }

  struct EntryRevision: Equatable {
    private let identity: FileIdentity
    let fileRevision: CaptureFilePublication.FileRevision?

    init?(at url: URL) {
      guard let identity = FileIdentity.at(url) else { return nil }
      self.identity = identity
      fileRevision = CaptureFilePublication.FileRevision(at: url)
    }
  }

  struct Candidate {
    let url: URL
    let revision: CaptureFilePublication.FileRevision?
  }

  struct Session {
    let directory: URL
    let identity: FileIdentity
    let originalEntries: [String: EntryRevision]
    let candidates: [Candidate]

    var isCurrent: Bool {
      !RecordingCrashRecoveryScanner.isDiscarded(directory)
        && FileIdentity.at(directory, type: mode_t(S_IFDIR)) == identity
    }

    func contentsAreCurrent(listDirectory: DirectoryListing) -> Bool {
      guard isCurrent, let remaining = try? listDirectory(directory, []) else { return false }
      return remaining.allSatisfy { file in
        guard let original = originalEntries[file.lastPathComponent] else { return false }
        return EntryRevision(at: file) == original
      } && isCurrent
    }
  }

  struct Snapshot {
    let root: URL
    let identity: FileIdentity
    let sessions: [Session]

    var rootIsCurrent: Bool {
      FileIdentity.at(root, type: mode_t(S_IFDIR)) == identity
    }

    func contentsAreCurrent(_ session: Session, listDirectory: DirectoryListing) -> Bool {
      rootIsCurrent && session.contentsAreCurrent(listDirectory: listDirectory) && rootIsCurrent
    }

    func canRemoveEmpty(_ session: Session, listDirectory: DirectoryListing) -> Bool {
      guard rootIsCurrent, session.isCurrent,
            let remaining = try? listDirectory(session.directory, []), remaining.isEmpty else { return false }
      return rootIsCurrent && session.isCurrent
    }
  }

  /// Снимок включает только каталоги, содержимое которых удалось прочитать.
  static func snapshot(
    inProcessingRoot root: URL, listDirectory: DirectoryListing = RecordingCrashRecoveryScanner.listDirectory
  ) -> Snapshot? {
    guard let identity = FileIdentity.at(root, type: mode_t(S_IFDIR)),
          let directories = try? listDirectory(root, [.skipsHiddenFiles]) else { return nil }
    let sessions = directories.compactMap { directory -> Session? in
      guard !isDiscarded(directory),
            let identity = FileIdentity.at(directory, type: mode_t(S_IFDIR)),
            let files = try? listDirectory(directory, []),
            FileIdentity.at(directory, type: mode_t(S_IFDIR)) == identity else { return nil }
      var originalEntries: [String: EntryRevision] = [:]
      for file in files {
        originalEntries[file.lastPathComponent] = EntryRevision(at: file)
      }
      // Скрытые временные файлы сведения не восстанавливаем: исходник лежит рядом.
      let candidates = files.filter {
        videoExtensions.contains($0.pathExtension.lowercased())
          && !$0.lastPathComponent.hasPrefix(".")
          && (try? $0.resourceValues(forKeys: [.isHiddenKey]).isHidden) != true
      }.map { Candidate(url: $0, revision: originalEntries[$0.lastPathComponent]?.fileRevision) }
      return Session(directory: directory, identity: identity, originalEntries: originalEntries, candidates: candidates)
    }
    let snapshot = Snapshot(root: root, identity: identity, sessions: sessions)
    return snapshot.rootIsCurrent ? snapshot : nil
  }
}

@MainActor
enum RecordingCrashRecovery {
  /// Запускается при старте приложения, когда ни одна запись ещё не идёт.
  static func recoverOnLaunch() {
    let captures = TempCaptureManager.shared
    startRecovery(
      in: captures.recordingProcessingRootDirectory,
      isPlayable: isPlayable,
      destinationFor: { captures.proposedRecoveredRecordingURL(for: $0) },
      deleteSession: { directory in
        directory.withUnsafeFileSystemRepresentation { path in
          if let path { _ = rmdir(path) }
        }
      }
    ) { recovered in
      await SystemNotificationService.shared.post(
        title: L10n.RecordingParity.recoveredTitle,
        body: L10n.RecordingParity.recoveredMessage
      )
      for url in recovered {
        await PostCaptureActionHandler.shared.handleVideoCapture(url: url)
      }
    }
  }

  @discardableResult
  static func startRecovery(
    in root: URL,
    listDirectory: @escaping RecordingCrashRecoveryScanner.DirectoryListing = RecordingCrashRecoveryScanner.listDirectory,
    isPlayable: @escaping @MainActor (URL) async throws -> Bool,
    destinationFor: @escaping @MainActor (URL) -> URL,
    deleteSession: @escaping @MainActor (URL) -> Void,
    onRecovered: @escaping @MainActor ([URL]) async -> Void
  ) -> Task<Void, Never>? {
    // Пока проверяется старое видео, пользователь уже может начать новую запись.
    guard let snapshot = RecordingCrashRecoveryScanner.snapshot(
      inProcessingRoot: root, listDirectory: listDirectory
    ) else { return nil }
    let candidates = snapshot.sessions.flatMap(\.candidates).sorted { $0.url.path < $1.url.path }
    guard !candidates.isEmpty else {
      for session in snapshot.sessions where snapshot.canRemoveEmpty(session, listDirectory: listDirectory) {
        deleteSession(session.directory)
      }
      return nil
    }
    return Task { @MainActor in
      var recovered: [URL] = []
      var sessionsToKeep: Set<String> = []
      var unplayableFiles: Set<URL> = []
      for entry in candidates {
        guard snapshot.rootIsCurrent else { break }
        let candidate = entry.url
        let directory = candidate.deletingLastPathComponent()
        let sessionPath = directory.standardizedFileURL.path
        guard !RecordingCrashRecoveryScanner.isDiscarded(directory),
              let revision = entry.revision,
              CaptureFilePublication.FileRevision(at: candidate) == revision else {
          sessionsToKeep.insert(sessionPath)
          continue
        }
        let playable: Bool
        do {
          playable = try await isPlayable(candidate)
        } catch {
          sessionsToKeep.insert(sessionPath)
          DiagnosticLogger.shared.logError(.recording, error, "Unfinished recording inspection failed; keeping session", context: [
            "file": candidate.lastPathComponent,
          ])
          continue
        }
        guard snapshot.rootIsCurrent else { break }
        guard CaptureFilePublication.FileRevision(at: candidate) == revision else {
          sessionsToKeep.insert(sessionPath)
          continue
        }
        guard playable else {
          unplayableFiles.insert(candidate)
          continue
        }
        let proposedDestination = destinationFor(candidate)
        do {
          let destination = try CaptureFilePublication.moveChoosingFreeName(at: candidate, to: proposedDestination) { _ in
            guard snapshot.rootIsCurrent,
                  !RecordingCrashRecoveryScanner.isDiscarded(directory),
                  CaptureFilePublication.FileRevision(at: candidate) == revision else {
              throw CocoaError(.fileNoSuchFile)
            }
          }
          recovered.append(destination)
          DiagnosticLogger.shared.log(.info, .recording, "Unfinished recording recovered", context: [
            "file": destination.lastPathComponent,
          ])
        } catch {
          sessionsToKeep.insert(sessionPath)
          DiagnosticLogger.shared.logError(.recording, error, "Unfinished recording recovery move failed", context: [
            "file": candidate.lastPathComponent,
          ])
        }
      }
      for session in snapshot.sessions where !sessionsToKeep.contains(session.directory.standardizedFileURL.path) {
        let unplayable = session.candidates.filter { unplayableFiles.contains($0.url) }
        if !unplayable.isEmpty {
          guard snapshot.contentsAreCurrent(session, listDirectory: listDirectory) else { continue }
          for entry in unplayable {
            guard snapshot.rootIsCurrent, session.isCurrent, let revision = entry.revision else { break }
            do {
              try revision.removeOriginal(at: entry.url)
              DiagnosticLogger.shared.log(.warning, .recording, "Unfinished recording is not playable; discarded", context: [
                "file": entry.url.lastPathComponent,
              ])
            } catch {
              DiagnosticLogger.shared.logError(.recording, error, "Unfinished recording cleanup failed", context: [
                "file": entry.url.lastPathComponent,
              ])
            }
          }
        }
        if snapshot.canRemoveEmpty(session, listDirectory: listDirectory) { deleteSession(session.directory) }
      }
      if !recovered.isEmpty {
        await onRecovered(recovered)
      }
    }
  }

  private static func isPlayable(_ url: URL) async throws -> Bool {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard !tracks.isEmpty else { return false }
    let duration = try await asset.load(.duration)
    let seconds = CMTimeGetSeconds(duration)
    return seconds.isFinite && seconds > 0
  }
}
