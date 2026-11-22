import Darwin
import Foundation

enum RecordingFocusRunnerError: Error {
  case timedOut
  case unsuccessfulExit(Int32)
  case invalidOutput
}

@MainActor
final class ShortcutsRecordingFocusRunner: RecordingFocusShortcutRunning {
  private let timeout: TimeInterval

  init(timeout: TimeInterval = 15) {
    self.timeout = timeout
  }

  func run(shortcut: RecordingFocusShortcut, input: String?) async throws -> String {
    let timeout = self.timeout
    let task = Task.detached(priority: .userInitiated) {
      try await Self.execute(shortcut: shortcut, input: input, timeout: timeout)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  nonisolated private static func execute(
    shortcut: RecordingFocusShortcut, input: String?, timeout: TimeInterval
  ) async throws -> String {
    try Task.checkCancellation()
    let files = FileManager.default
    let directory = files.temporaryDirectory.appendingPathComponent("OwnShot-Focus-\(UUID().uuidString)", isDirectory: true)
    try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? files.removeItem(at: directory) }
    let outputURL = directory.appendingPathComponent("output.txt")
    files.createFile(atPath: outputURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
    var arguments = ["run", shortcut.rawValue, "--output-type", "public.plain-text", "--output-path", outputURL.path]
    if let input {
      let inputURL = directory.appendingPathComponent("input.txt")
      try Data(input.utf8).write(to: inputURL)
      try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inputURL.path)
      arguments.append(contentsOf: ["--input-path", inputURL.path])
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let startedAt = ProcessInfo.processInfo.systemUptime
    try process.run()
    do {
      while process.isRunning {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime - startedAt < timeout else {
          throw RecordingFocusRunnerError.timedOut
        }
        try await Task.sleep(nanoseconds: 25_000_000)
      }
    } catch {
      stop(process)
      throw error
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw RecordingFocusRunnerError.unsuccessfulExit(process.terminationStatus)
    }
    let attributes = try files.attributesOfItem(atPath: outputURL.path)
    guard let size = attributes[.size] as? NSNumber, size.intValue <= 16_384 else {
      throw RecordingFocusRunnerError.invalidOutput
    }
    let data = try Data(contentsOf: outputURL)
    guard let output = String(data: data, encoding: .utf8) else {
      throw RecordingFocusRunnerError.invalidOutput
    }
    return output
  }

  nonisolated private static func stop(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let graceDeadline = ProcessInfo.processInfo.systemUptime + 0.25
    while process.isRunning, ProcessInfo.processInfo.systemUptime < graceDeadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
  }
}
