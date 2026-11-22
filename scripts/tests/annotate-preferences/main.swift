import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() { fatalError(message) }
}
let suite = "ownshot.annotate.preferences.tests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let settings = OwnShotAnnotatePreferences(defaults: defaults)
check(!settings.inverseArrowDirection, "Направление стрелки по умолчанию")
check(settings.smoothDrawing, "Сглаживание включено по умолчанию")
check(settings.drawObjectShadow && settings.showDockIcon, "Тень и Dock включены по умолчанию")
check(!settings.rememberBackground && !settings.automaticallyExpandCanvas && !settings.alwaysOnTop && !settings.showColorNames, "Остальные настройки выключены")
check(!settings.invertsArrow(optionHeld: false) && settings.invertsArrow(optionHeld: true), "Option временно меняет направление")
defaults.set(true, forKey: OwnShotAnnotatePreferenceKeys.inverseArrowDirection)
check(settings.invertsArrow(optionHeld: false) && !settings.invertsArrow(optionHeld: true), "Option отменяет сохранённое обратное направление")
let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 9), CGPoint(x: 20, y: 0)]
let smooth = OwnShotAnnotateDrawing.smooth(points)
check(smooth.first == points.first && smooth.last == points.last, "Концы штриха сохранены")
check(smooth[1].y < 9 && smooth.count > points.count, "Сглаживание убирает резкий угол")
let source = CGRect(x: 0, y: 0, width: 100, height: 80)
let outside = CGRect(x: -20, y: 40, width: 160, height: 60)
check(OwnShotAnnotateDrawing.expandedBounds(source: source, annotations: [outside]) == CGRect(x: -20, y: 0, width: 160, height: 100), "Расширение сохраняет начало координат")
check(OwnShotAnnotateColorName.name(red: 1, green: 0, blue: 0, alpha: 1) == "Red", "Имя красного цвета")
check(OwnShotAnnotateColorName.name(red: 0.5, green: 0.5, blue: 0.5, alpha: 1) == "Gray", "Имя серого цвета")
check(OwnShotAnnotateColorName.name(red: 0, green: 0, blue: 0, alpha: 0) == "Transparent", "Прозрачный цвет")
print("PASS: Annotate defaults, live persistence, Option override, smoothing, canvas union, color names")
