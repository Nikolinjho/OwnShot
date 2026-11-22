# Сторонние компоненты

OwnShot включает код проекта [Snapzy](https://github.com/duongductrong/Snapzy). Уведомление об авторском праве Trong Duong Duc, условия BSD 3-Clause и отказ от гарантий сохранены в [LICENSES/Snapzy-BSD-3-Clause.txt](LICENSES/Snapzy-BSD-3-Clause.txt).

Версии зависимостей зафиксированы в [Package.resolved](Snapzy.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved). Условия распространения и уведомления об авторских правах приведены в следующих файлах.

- [GRDB.swift](LICENSES/GRDB.swift.txt)
- [Sparkle](LICENSES/Sparkle.txt) и [ed25519](LICENSES/Sparkle-ed25519.txt)
- [Swift-WebP](LICENSES/Swift-WebP.txt)
- [libwebp](LICENSES/libwebp.txt) и [патентная лицензия](LICENSES/libwebp-PATENTS.txt)
- [Swift Argument Parser](LICENSES/Swift-Argument-Parser.txt)

### Scroll capture frame analysis

OwnShot uses frame analysis from [Macshot](https://github.com/sw33tLie/macshot) at commit `ec1b4e9b4b94788cd07a5ba1ced4161d772c8c4c`. The vendored files retain their [source notice](Snapzy/Services/Capture/ScrollingCapture/Macshot/SOURCE.md) and [GPLv3 license](Snapzy/Services/Capture/ScrollingCapture/Macshot/LICENSE).

The combined OwnShot application is distributed under [GPLv3](LICENSE). Separately licensed components retain the notices listed here. The source at each GitHub release tag corresponds to that release.
