//
//  OwnShotLicense.swift
//  Snapzy
//
//  Заглушка лицензирования. OwnShot – личная сборка: ключ не проверяется,
//  сеть не используется, приложение всегда считается лицензированным.
//

import Foundation

/// Состояние лицензии. У личной сборки другого состояния нет.
nonisolated enum OwnShotLicenseState: Equatable {
  case licensed
}

/// Что показать после нажатия Activate в окне активации.
nonisolated enum OwnShotActivationOutcome: Equatable {
  /// Пустой ключ или ключ не в формате эталона: alert «Activation error».
  case invalidKey
  /// Ключ в верном формате: alert «Activation Successful» с пометкой, что ключ не проверялся.
  case notCheckedPersonalBuild
}

nonisolated enum OwnShotLicense {
  /// Формат ключа эталона: четыре группы по восемь латинских букв и цифр через дефис.
  private static let keyPattern = "^[A-Za-z0-9]{8}-[A-Za-z0-9]{8}-[A-Za-z0-9]{8}-[A-Za-z0-9]{8}$"

  /// Повторная проверка эталона ходит на сервер. Здесь ответ всегда один и без сети.
  static func check() -> OwnShotLicenseState { .licensed }

  static var isLicensed: Bool { check() == .licensed }

  /// Активированный эталон не показывает Activate… в статус-меню.
  /// OwnShot делает так же, а с Option пункт открывает окно активации для просмотра.
  static func showsActivateMenuItem(optionPressed: Bool) -> Bool {
    !isLicensed || optionPressed
  }

  static func isValidKeyFormat(_ key: String) -> Bool {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.range(of: keyPattern, options: .regularExpression) != nil
  }

  /// Проверяется только формат, ключ никуда не отправляется и не сохраняется.
  static func activationOutcome(for key: String) -> OwnShotActivationOutcome {
    isValidKeyFormat(key) ? .notCheckedPersonalBuild : .invalidKey
  }

  /// Выход при открытом окне активации подтверждается, как в эталоне.
  static func shouldConfirmQuit(activationWindowVisible: Bool) -> Bool {
    activationWindowVisible
  }
}
