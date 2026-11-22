//
//  RecordingFocusSetup.swift
//  Snapzy
//
//  Проверка команд Shortcuts для «Do Not Disturb» while recording. У эталона в строке
//  настройки только переключатель, поэтому установка предлагается при включении.
//

import Foundation

nonisolated enum RecordingFocusSetup {
  static let requiredShortcuts: [RecordingFocusShortcut] = [.status, .on, .off]

  /// Каких команд нет в выводе `shortcuts list` (по строке на команду).
  static func missingShortcuts(inListOutput output: String) -> [RecordingFocusShortcut] {
    let installed = Set(
      output.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    )
    return requiredShortcuts.filter { !installed.contains($0.rawValue) }
  }

  /// Вывод `shortcuts list`. nil – команду запустить не удалось.
  static func listInstalledShortcuts() async -> String? {
    await Task.detached(priority: .userInitiated) { () -> String? in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
      process.arguments = ["list"]
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      process.standardInput = FileHandle.nullDevice
      do { try process.run() } catch { return nil }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return nil }
      return String(data: data, encoding: .utf8)
    }.value
  }
}
