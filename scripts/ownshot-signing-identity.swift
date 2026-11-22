#!/usr/bin/env swift
import Foundation
import Security
import CryptoKit
import Darwin

// Закрытый ключ создаётся в связке ключей и никогда не экспортируется.
private let identityName = "OwnShot Local Development"
private let keyTag = Data("dev.nikoko.ownshot.local-signing".utf8)
private struct Failure: Error, CustomStringConvertible { let description: String }
private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(description: message) }
}
private func check(_ status: OSStatus, _ operation: String) throws {
    if status != errSecSuccess {
        throw Failure(description: "\(operation): \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))")
    }
}
private enum DER {
    static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var n = count, bytes = [UInt8]()
        while n > 0 { bytes.insert(UInt8(n & 255), at: 0); n >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
    static func node(_ tag: UInt8, _ bytes: Data) -> Data { Data([tag]) + length(bytes.count) + bytes }
    static func sequence(_ values: Data...) -> Data { node(0x30, values.reduce(Data(), +)) }
    static func oid(_ bytes: [UInt8]) -> Data { node(0x06, Data(bytes)) }
    static func integer(_ bytes: Data) -> Data {
        var value = bytes
        while value.count > 1 && value.first == 0 { value.removeFirst() }
        if value.first.map({ $0 & 0x80 != 0 }) ?? false { value.insert(0, at: 0) }
        return node(0x02, value)
    }
    static let sha256RSA = sequence(oid([0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x0b]), node(0x05, Data()))
    static let rsa = sequence(oid([0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01]), node(0x05, Data()))
    static let name = sequence(node(0x31, sequence(oid([0x55,0x04,0x03]), node(0x0c, Data(identityName.utf8)))))
    static func date(_ value: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return node(0x18, Data(formatter.string(from: value).utf8))
    }
    static func tbs(publicKey: Data, serial: Data, now: Date) -> Data {
        let usage = sequence(oid([0x55,0x1d,0x0f]), node(0x01, Data([0xff])), node(0x04, node(0x03, Data([7,0x80]))))
        let extended = sequence(oid([0x55,0x1d,0x25]), node(0x04, sequence(oid([0x2b,0x06,0x01,0x05,0x05,0x07,0x03,0x03]))))
        let constraints = sequence(oid([0x55,0x1d,0x13]), node(0x01, Data([0xff])), node(0x04, sequence()))
        let calendar = Calendar(identifier: .gregorian)
        let expires = calendar.date(byAdding: .year, value: 10, to: now)!
        return sequence(node(0xa0, integer(Data([2]))), integer(serial), sha256RSA, name,
                        sequence(date(now.addingTimeInterval(-300)), date(expires)), name,
                        sequence(rsa, node(0x03, Data([0]) + publicKey)),
                        node(0xa3, sequence(usage, extended, constraints)))
    }
}
private struct Pin: Codable {
    let commonName: String
    let fingerprintSHA256: String
    let fingerprintSHA1: String
    let keychainPath: String
}
private func fingerprint(_ certificate: SecCertificate) -> String {
    SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02X", $0) }.joined()
}
private func keychainPath(_ keychain: SecKeychain) throws -> String {
    var bytes = [CChar](repeating: 0, count: 4096)
    var length = UInt32(bytes.count)
    try check(SecKeychainGetPath(keychain, &length, &bytes), "Не удалось узнать путь связки ключей")
    return String(cString: bytes)
}
private func items(_ query: [CFString: Any]) throws -> [CFTypeRef] {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    try check(status, "Не удалось прочитать связку ключей")
    return result as? [CFTypeRef] ?? result.map { [$0] } ?? []
}
private func publicData(_ key: SecKey) throws -> Data {
    guard let publicKey = SecKeyCopyPublicKey(key) else { throw Failure(description: "У ключа отсутствует открытая часть") }
    var error: Unmanaged<CFError>?
    guard let data = SecKeyCopyExternalRepresentation(publicKey, &error) else {
        throw Failure(description: "Не удалось прочитать открытый ключ")
    }
    return data as Data
}
// Читаем только метаданные CSSM, не запрашивая данные закрытого ключа.
// Общий API атрибутов SecKey может инициировать экспорт legacy-ключа.
private func legacyKeyUInt32(_ key: SecKey, tag: Int32) throws -> UInt32 {
    var attributeTag = UInt32(tag)
    var format = UInt32(CSSM_DB_ATTRIBUTE_FORMAT_UINT32)
    return try withUnsafeMutablePointer(to: &attributeTag) { tags in
        try withUnsafeMutablePointer(to: &format) { formats in
            var info = SecKeychainAttributeInfo(count: 1, tag: tags, format: formats)
            var list: UnsafeMutablePointer<SecKeychainAttributeList>?
            try check(SecKeychainItemCopyAttributesAndData(unsafeBitCast(key, to: SecKeychainItem.self), &info, nil, &list, nil, nil), "Не удалось прочитать защитные атрибуты ключа")
            defer { if let list { SecKeychainItemFreeAttributesAndData(list, nil) } }
            guard let list, list.pointee.count == 1,
                  let attributes = list.pointee.attr,
                  attributes.pointee.tag == UInt32(tag),
                  attributes.pointee.length == MemoryLayout<UInt32>.size,
                  let data = attributes.pointee.data else {
                throw Failure(description: "Связка ключей не вернула защитный атрибут")
            }
            var value: UInt32 = 0
            withUnsafeMutableBytes(of: &value) { bytes in
                bytes.copyBytes(from: UnsafeRawBufferPointer(start: data, count: MemoryLayout<UInt32>.size))
            }
            return value
        }
    }
}
private func validate(_ certificate: SecCertificate, key: SecKey, keychain: SecKeychain) throws {
    var commonName: CFString?
    try check(SecCertificateCopyCommonName(certificate, &commonName), "Не удалось прочитать имя сертификата")
    try require(commonName as String? == identityName, "Неожиданное имя сертификата")
    try require(try legacyKeyUInt32(key, tag: kSecKeyExtractable) == 0, "Закрытый ключ экспортируемый")
    try require(try legacyKeyUInt32(key, tag: kSecKeyPermanent) != 0, "Закрытый ключ не сохранён в связке ключей")
    try require(try legacyKeyUInt32(key, tag: kSecKeyKeySizeInBits) == 2048, "Ожидался ключ RSA 2048")
    try require(try legacyKeyUInt32(key, tag: kSecKeyKeyType) == UInt32(CSSM_ALGID_RSA), "Ожидался ключ RSA")
    guard let certKey = SecCertificateCopyKey(certificate) else { throw Failure(description: "В сертификате отсутствует открытый ключ") }
    var error: Unmanaged<CFError>?
    guard let certData = SecKeyCopyExternalRepresentation(certKey, &error) else { throw Failure(description: "Не удалось прочитать открытый ключ сертификата") }
    try require(try publicData(key) == certData as Data, "Сертификат не соответствует постоянному ключу")
    var identity: SecIdentity?
    try check(SecIdentityCreateWithCertificate(keychain, certificate, &identity), "Не найдена идентичность сертификата")
    try require(identity != nil, "Не найдена идентичность сертификата")
}
private func create(_ keychain: SecKeychain) throws -> (SecCertificate, SecKey) {
    var trusted: [SecTrustedApplication] = []
    let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
    for path in ["/usr/bin/codesign", helper] {
        var app: SecTrustedApplication?
        try check(SecTrustedApplicationCreateFromPath(path, &app), "Не удалось ограничить доступ к ключу")
        guard let app else { throw Failure(description: "Не удалось создать правило доступа к ключу") }
        trusted.append(app)
    }
    var access: SecAccess?
    try check(SecAccessCreate(identityName as CFString, trusted as CFArray, &access), "Не удалось создать ACL")
    guard let access else { throw Failure(description: "Не удалось создать ACL") }
    let privateAttributes: [CFString: Any] = [kSecAttrIsPermanent: true, kSecAttrIsExtractable: false, kSecAttrIsSensitive: true,
        kSecAttrApplicationTag: keyTag, kSecAttrLabel: identityName, kSecAttrAccess: access]
    let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048,
        kSecUseKeychain: keychain, kSecAttrIsExtractable: false, kSecAttrAccess: access,
        kSecAttrIsSensitive: true, kSecPrivateKeyAttrs: privateAttributes,
        kSecPublicKeyAttrs: [kSecAttrIsPermanent: false]]
    var publicKey: SecKey?, privateKey: SecKey?
    try check(SecKeyGeneratePair(attributes as CFDictionary, &publicKey, &privateKey), "Не удалось создать защищённый ключ")
    guard let privateKey else { throw Failure(description: "Связка ключей не вернула закрытый ключ") }
    // При ошибке оставляем ключ для диагностики: автоматическая замена запрещена.
    var serial = Data(count: 20)
    let status = serial.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 20, $0.baseAddress!) }
    try check(status, "Не удалось создать серийный номер")
    serial[0] &= 0x7f
    serial[0] |= 1
    let tbs = DER.tbs(publicKey: try publicData(privateKey), serial: serial, now: Date())
    var error: Unmanaged<CFError>?
    guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, &error) else {
        throw Failure(description: "Не удалось подписать сертификат постоянным ключом")
    }
    let der = DER.sequence(tbs, DER.sha256RSA, DER.node(0x03, Data([0]) + (signature as Data)))
    guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { throw Failure(description: "Не удалось прочитать созданный сертификат") }
    try check(SecItemAdd([kSecClass: kSecClassCertificate, kSecValueRef: certificate,
                        kSecUseKeychain: keychain, kSecAttrLabel: identityName] as CFDictionary, nil), "Не удалось сохранить сертификат")
    return (certificate, privateKey)
}
private func selfTest() throws {
    try require(DER.length(127) == Data([127]), "Ошибка короткой длины DER")
    try require(DER.length(128) == Data([0x81,128]), "Ошибка длинной длины DER")
    try require(DER.integer(Data([0x80])) == Data([2,2,0,0x80]), "Ошибка положительного INTEGER")
    try require(DER.integer(Data([0,1])) == Data([2,1,1]), "Ошибка нормализации INTEGER")
    let tbs = DER.tbs(publicKey: Data([0x30,0]), serial: Data([1]), now: Date(timeIntervalSince1970: 1_800_000_000))
    try require(tbs.first == 0x30 && tbs.contains(0xa3), "Ошибка структуры TBSCertificate")
    try require(tbs.range(of: Data([0x55,0x1d,0x0f])) != nil, "Отсутствует Key Usage")
    try require(tbs.range(of: Data([0x2b,0x06,0x01,0x05,0x05,0x07,0x03,0x03])) != nil, "Отсутствует Code Signing EKU")
    let modulus = Data([0x81]) + Data(repeating: 0x55, count: 255)
    let publicKey = DER.sequence(DER.integer(modulus), DER.integer(Data([1,0,1])))
    let parsedTBS = DER.tbs(publicKey: publicKey, serial: Data([1]), now: Date(timeIntervalSince1970: 1_800_000_000))
    let certificateDER = DER.sequence(parsedTBS, DER.sha256RSA, DER.node(0x03, Data([0]) + Data(repeating: 0, count: 256)))
    guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
        throw Failure(description: "Security.framework не смог разобрать тестовый DER-сертификат")
    }
    try require(SecCertificateCopySubjectSummary(certificate) as String? == identityName, "Ошибка имени в тестовом сертификате")
    print("DER self-test: OK (8 проверок, без обращения к связке ключей)")
}
private func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["--self-test"] { try selfTest(); return }
    if args == ["--help"] || args.isEmpty {
        print("Использование: ownshot-signing-identity --ensure|--inspect [--pin путь] [--certificate путь.der]\n--ensure создаёт идентичность только при отсутствии ключа, сертификата и закреплённого отпечатка.\n--inspect только читает связку ключей. --certificate сохраняет открытый DER-сертификат.\n--self-test проверяет DER без обращения к связке ключей.")
        return
    }
    try require(args.first == "--ensure" || args.first == "--inspect", "Ожидался --ensure или --inspect")
    var pinURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".local-signing/identity.json")
    var certificateURL: URL?
    var index = 1
    while index < args.count {
        try require(index + 1 < args.count, "Не указан путь после \(args[index])")
        switch args[index] {
        case "--pin": pinURL = URL(fileURLWithPath: args[index + 1])
        case "--certificate": certificateURL = URL(fileURLWithPath: args[index + 1])
        default: throw Failure(description: "Неизвестный параметр: \(args[index])")
        }
        index += 2
    }
    // Два одновременных запуска не должны создать разные постоянные ключи.
    var lockDescriptor: Int32 = -1
    if args.first == "--ensure" {
        try FileManager.default.createDirectory(at: pinURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        lockDescriptor = open(pinURL.deletingLastPathComponent().appendingPathComponent("identity.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        try require(lockDescriptor >= 0, "Не удалось открыть блокировку идентичности")
        if flock(lockDescriptor, LOCK_EX) != 0 {
            close(lockDescriptor)
            throw Failure(description: "Не удалось заблокировать создание идентичности")
        }
    }
    defer { if lockDescriptor >= 0 { close(lockDescriptor) } }
    let pinned = FileManager.default.fileExists(atPath: pinURL.path) ? try JSONDecoder().decode(Pin.self, from: Data(contentsOf: pinURL)) : nil
    var defaultKeychain: SecKeychain?
    try check(SecKeychainCopyDefault(&defaultKeychain), "Не удалось открыть стандартную связку ключей")
    guard let keychain = defaultKeychain else { throw Failure(description: "Стандартная связка ключей отсутствует") }
    let path = try keychainPath(keychain)
    if let pinned { try require(pinned.commonName == identityName && pinned.keychainPath == path, "Закреплённая идентичность относится к другой связке ключей") }
    let scope: [CFString: Any] = [kSecMatchSearchList: [keychain], kSecMatchLimit: kSecMatchLimitAll, kSecReturnRef: true]
    var certQuery = scope
    certQuery[kSecClass] = kSecClassCertificate
    certQuery[kSecAttrLabel] = identityName
    var keyQuery = scope
    keyQuery[kSecClass] = kSecClassKey
    keyQuery[kSecAttrKeyClass] = kSecAttrKeyClassPrivate
    keyQuery[kSecAttrApplicationTag] = keyTag
    let certificates = try items(certQuery)
    let keys = try items(keyQuery)
    try require(certificates.count <= 1 && keys.count <= 1, "Найдено несколько ключей или сертификатов. Автоматический выбор запрещён")
    let certificate: SecCertificate, key: SecKey
    if certificates.isEmpty && keys.isEmpty {
        try require(pinned == nil, "Закреплённая идентичность отсутствует. Создание замены запрещено")
        try require(args.first == "--ensure", "Локальная идентичность ещё не создана")
        (certificate, key) = try create(keychain)
    } else {
        try require(certificates.count == 1 && keys.count == 1, "Найдена неполная идентичность. Создание замены запрещено")
        certificate = certificates[0] as! SecCertificate
        key = keys[0] as! SecKey
    }
    try validate(certificate, key: key, keychain: keychain)
    let sha1 = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02X", $0) }.joined()
    let result = Pin(commonName: identityName, fingerprintSHA256: fingerprint(certificate), fingerprintSHA1: sha1, keychainPath: path)
    if let pinned { try require(pinned.fingerprintSHA256 == result.fingerprintSHA256, "Отпечаток сертификата не совпадает с закреплённым. Подмена запрещена") }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(result)
    if args.first == "--ensure" && pinned == nil {
        try FileManager.default.createDirectory(at: pinURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: pinURL, options: .withoutOverwriting)
    }
    if let certificateURL { try (SecCertificateCopyData(certificate) as Data).write(to: certificateURL, options: .atomic) }
    print(String(decoding: data, as: UTF8.self))
}
do { try run() } catch {
    FileHandle.standardError.write(Data("Ошибка: \(error)\n".utf8))
    exit(1)
}
