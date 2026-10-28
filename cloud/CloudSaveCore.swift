import Foundation
import CryptoKit
import Darwin

// Shared by the Mac launcher and iPhone. Each device writes its own head; revisions and blobs are immutable.
// A divergent history is kept as a conflict, never resolved by a timestamp or by overwriting a newer profile.
struct CloudFile: Codable { let size: Int; let sha256: String }
struct CloudRevision: Codable {
    let format: String, game: String, version: String, id: String, device: String, created: String
    let parents: [String]
    let fingerprint: String
    let files: [String: CloudFile]
}
struct CloudHead: Codable { let revision: String, device: String, updated: String }
struct CloudLocalState: Codable {
    var deviceID: String
    var cloudID: String?
    var base: String?
    var fingerprint: String?
}
struct CloudReport: Codable {
    var status: String
    var revision: String?
    var choices: [CloudChoice] = []
    var message: String?
}
struct CloudChoice: Codable { let id: String, device: String, created: String }
struct CloudFailure: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

// startup/publish/resolve/checkRemote are serialized by the caller; cancel() is lock-protected.
final class CloudSaveEngine {
    static let format = "botw-cloud-v1", game = "01007EF00011E000", version = "1.6.0"
    static let byteLimit = 128 * 1024 * 1024, fileLimit = 4000
    let profile: URL, cloud: URL, stateURL: URL, backups: URL, device: String
    private let fm = FileManager.default
    private var state: CloudLocalState
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let cancellationLock = NSLock()
    private var coordinator: NSFileCoordinator?

    init(profile: URL, cloud: URL, stateURL: URL, backups: URL, device: String) throws {
        self.profile = profile; self.cloud = cloud; self.stateURL = stateURL; self.backups = backups; self.device = device
        encoder.outputFormatting = [.sortedKeys]
        if fm.fileExists(atPath: stateURL.path) {
            state = try decoder.decode(CloudLocalState.self, from: Data(contentsOf: stateURL))
            guard Self.validID(state.deviceID) else { throw CloudFailure("Повреждён локальный идентификатор синхронизации.") }
        } else {
            state = CloudLocalState(deviceID: UUID().uuidString.lowercased())
            try saveState()
        }
    }
    static func validID(_ id: String) -> Bool { UUID(uuidString: id) != nil && id == id.lowercased() }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
    var deviceID: String { state.deviceID }
    func cancel() { cancellationLock.lock(); let c = coordinator; cancellationLock.unlock(); c?.cancel() }

    private func saveState() throws {
        try fm.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }
    private func regular(_ url: URL, directory: Bool = false) throws {
        let v = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
        guard v.isSymbolicLink != true, directory ? v.isDirectory == true : v.isRegularFile == true else {
            throw CloudFailure("В папке сохранений обнаружена ссылка или неожиданный тип файла.")
        }
    }
    private func boundedData(_ url: URL, maximum: Int) throws -> Data {
        try regular(url)
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size >= 0, size <= maximum else {
            throw CloudFailure("Размер файла сохранений не прошёл проверку.")
        }
        let data = try Data(contentsOf: url)
        guard data.count == size else { throw CloudFailure("Облачный файл ещё загружается. Повторите позже.") }
        return data
    }
    static func safePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.contains("\\") && !parts.contains("") && !parts.contains(".") && !parts.contains("..") &&
            (path == "account.uid" || (parts.count >= 3 && parts[0] == "save"))
    }
    private func validate(_ files: [String: Data], allowEmpty: Bool = false) throws {
        guard files.count <= Self.fileLimit, files.values.reduce(0, { $0 + $1.count }) <= Self.byteLimit,
              files.keys.allSatisfy(Self.safePath) else { throw CloudFailure("Неверный состав или размер сохранения.") }
        if files.isEmpty && allowEmpty { return }
        guard let uid = files["account.uid"], uid.count == 16 else { throw CloudFailure("Неверный account.uid.") }
        let lo = uid.prefix(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        let hi = uid.suffix(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        let prefix = "save/" + String(format: "%016llx%016llx", hi, lo) + "/"
        guard files.keys.filter({ $0 != "account.uid" }).allSatisfy({ $0.hasPrefix(prefix) }) else {
            throw CloudFailure("Сохранение принадлежит другому игровому профилю.")
        }
        if !allowEmpty && files.count < 2 { throw CloudFailure("В игровом профиле ещё нет сохранений.") }
    }
    private func playable(_ files: [String: Data]) -> Bool { files.count > 1 && files["account.uid"]?.count == 16 }
    private func records(_ files: [String: Data]) -> [String: CloudFile] {
        files.mapValues { CloudFile(size: $0.count, sha256: Self.sha($0)) }
    }
    private func fingerprint(_ files: [String: CloudFile]) -> String {
        Self.sha(Data(files.keys.sorted().map { "\($0)\0\(files[$0]!.sha256)\0\(files[$0]!.size)\n" }.joined().utf8))
    }
    private func readProfile() throws -> [String: Data] {
        guard fm.fileExists(atPath: profile.path) else { return [:] }
        try regular(profile, directory: true)
        var result: [String: Data] = [:], total = 0
        let account = profile.appendingPathComponent("account.uid")
        if fm.fileExists(atPath: account.path) { result["account.uid"] = try boundedData(account, maximum: 16) }
        let save = profile.appendingPathComponent("save")
        if fm.fileExists(atPath: save.path) {
            try regular(save, directory: true)
            let canonicalRoot = profile.resolvingSymlinksInPath().path + "/"
            guard let iterator = fm.enumerator(at: save, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
                throw CloudFailure("Не удалось прочитать сохранения.")
            }
            for case let url as URL in iterator {
                let v = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey])
                guard v.isSymbolicLink != true else { throw CloudFailure("Ссылки в сохранениях не поддерживаются.") }
                if v.isDirectory == true { continue }
                try regular(url)
                let canonicalPath = url.resolvingSymlinksInPath().path
                guard canonicalPath.hasPrefix(canonicalRoot) else { throw CloudFailure("Путь сохранения вышел за пределы игрового профиля.") }
                let relative = String(canonicalPath.dropFirst(canonicalRoot.count))
                guard Self.safePath(relative), result.count < Self.fileLimit,
                      let size = v.fileSize, size <= Self.byteLimit - total else { throw CloudFailure("Сохранение слишком большое.") }
                let data = try Data(contentsOf: url); total += data.count; result[relative] = data
            }
        }
        try validate(result, allowEmpty: true)
        return result
    }
    private func stableProfile() throws -> [String: Data] {
        let first = try readProfile()
        Thread.sleep(forTimeInterval: 0.2)
        guard fingerprint(records(first)) == fingerprint(records(try readProfile())) else {
            throw CloudFailure("Игра сейчас записывает сохранение. Синхронизация повторится позже.")
        }
        return first
    }

    static func initializeRoot(_ root: URL) throws {
        let fm = FileManager.default, marker = root.appendingPathComponent("ZeldaCloud.json")
        if fm.fileExists(atPath: marker.path) { return }
        if fm.fileExists(atPath: root.path), !(try fm.contentsOfDirectory(atPath: root.path)).isEmpty {
            throw CloudFailure("Выбранная папка уже содержит другие данные. Используйте отдельную папку Zelda BOTW.")
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["format": format, "game": game, "version": version, "id": UUID().uuidString.lowercased()], options: [.sortedKeys])
        try data.write(to: marker, options: .atomic)
    }
    private func checkRoot(_ root: URL) throws {
        let marker = root.appendingPathComponent("ZeldaCloud.json"); try regular(marker)
        let value = try JSONSerialization.jsonObject(with: boundedData(marker, maximum: 4096)) as? [String: String]
        guard value?["format"] == Self.format, value?["game"] == Self.game, value?["version"] == Self.version,
              let id = value?["id"], Self.validID(id) else { throw CloudFailure("Выберите папку Zelda BOTW с сохранениями этой версии игры.") }
        for name in ["Objects", "Snapshots", "Devices"] {
            let path = root.appendingPathComponent(name)
            if fm.fileExists(atPath: path.path) { try regular(path, directory: true) }
        }
        if state.cloudID != id { state.cloudID = id; state.base = nil; state.fingerprint = nil; try saveState() }
    }
    private func coordinate<T>(write: Bool, _ block: (URL) throws -> T) throws -> T {
        let c = NSFileCoordinator(filePresenter: nil)
        cancellationLock.lock(); coordinator = c; cancellationLock.unlock()
        defer { cancellationLock.lock(); coordinator = nil; cancellationLock.unlock() }
        var error: NSError?, answer: Result<T, Error>?
        if write {
            c.coordinate(writingItemAt: cloud, options: [], error: &error) { url in answer = Result { try block(url) } }
        } else {
            c.coordinate(readingItemAt: cloud, options: [], error: &error) { url in answer = Result { try block(url) } }
        }
        if let error = error { throw error }
        guard let answer = answer else { throw CloudFailure("Папка iCloud сейчас недоступна.") }
        return try answer.get()
    }
    private func revision(_ id: String, root: URL) throws -> CloudRevision {
        guard Self.validID(id) else { throw CloudFailure("Неверный идентификатор облачной копии.") }
        let url = root.appendingPathComponent("Snapshots/\(id).json"); try regular(url)
        let r = try decoder.decode(CloudRevision.self, from: boundedData(url, maximum: 4 << 20))
        guard r.format == Self.format, r.game == Self.game, r.version == Self.version, r.id == id,
              r.parents.count <= 16, r.parents.allSatisfy(Self.validID), r.files.count <= Self.fileLimit,
              r.files.keys.allSatisfy(Self.safePath), r.files.values.allSatisfy({ $0.size >= 0 && $0.size <= Self.byteLimit && $0.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }),
              r.files.values.reduce(0, { $0 + $1.size }) <= Self.byteLimit, fingerprint(r.files) == r.fingerprint else {
            throw CloudFailure("Облачная копия повреждена или имеет другую версию игры.")
        }
        return r
    }
    private func tips(_ root: URL) throws -> [CloudRevision] {
        let heads = root.appendingPathComponent("Devices")
        guard fm.fileExists(atPath: heads.path) else { return [] }
        try regular(heads, directory: true)
        let files = try fm.contentsOfDirectory(at: heads, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        guard files.count <= 32 else { throw CloudFailure("В облачной папке слишком много устройств.") }
        var headsSet = Set<String>(), ancestors = Set<String>(), loaded: [String: CloudRevision] = [:]
        for file in files {
            guard Self.validID(file.deletingPathExtension().lastPathComponent) else { throw CloudFailure("Неверная запись устройства.") }
            try regular(file)
            let head = try decoder.decode(CloudHead.self, from: boundedData(file, maximum: 4096)); headsSet.insert(head.revision)
        }
        func walk(_ id: String, path: Set<String>) throws {
            guard !path.contains(id), loaded.count <= 4096 else { throw CloudFailure("Повреждена история сохранений.") }
            if loaded[id] != nil { return }
            let r = try revision(id, root: root); loaded[id] = r
            for parent in r.parents { ancestors.insert(parent); try walk(parent, path: path.union([id])) }
        }
        for head in headsSet { try walk(head, path: []) }
        return headsSet.subtracting(ancestors).compactMap { loaded[$0] }.sorted { $0.created < $1.created }
    }
    private func writeHead(_ id: String, root: URL) throws {
        let directory = root.appendingPathComponent("Devices"); try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(state.deviceID + ".json")
        let head = CloudHead(revision: id, device: device, updated: Self.now())
        try encoder.encode(head).write(to: path, options: .atomic)
        guard try decoder.decode(CloudHead.self, from: Data(contentsOf: path)).revision == id else {
            throw CloudFailure("Запись в iCloud пока не подтвердилась.")
        }
    }
    private func commit(_ files: [String: Data], parents: [String], root: URL) throws -> CloudRevision {
        try validate(files)
        let objects = root.appendingPathComponent("Objects"), snapshots = root.appendingPathComponent("Snapshots")
        try fm.createDirectory(at: objects, withIntermediateDirectories: true)
        try fm.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let listing = records(files)
        for (name, record) in listing {
            let target = objects.appendingPathComponent(record.sha256)
            if !fm.fileExists(atPath: target.path) {
                let temporary = objects.appendingPathComponent("pending-" + UUID().uuidString.lowercased())
                try files[name]!.write(to: temporary, options: .atomic)
                do { try fm.moveItem(at: temporary, to: target) }
                catch { if !fm.fileExists(atPath: target.path) { throw error } }
            }
            try regular(target)
            let check = try boundedData(target, maximum: record.size)
            guard check.count == record.size, Self.sha(check) == record.sha256 else { throw CloudFailure("Облачный файл ещё не загрузился полностью или повреждён.") }
        }
        let id = UUID().uuidString.lowercased()
        let r = CloudRevision(format: Self.format, game: Self.game, version: Self.version, id: id, device: device,
                              created: Self.now(), parents: parents, fingerprint: fingerprint(listing), files: listing)
        try encoder.encode(r).write(to: snapshots.appendingPathComponent(id + ".json"), options: .atomic)
        try writeHead(id, root: root)
        state.base = id; state.fingerprint = r.fingerprint; try saveState()
        return r
    }
    private func readFiles(_ r: CloudRevision, root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for (name, record) in r.files {
            let path = root.appendingPathComponent("Objects/" + record.sha256); try regular(path)
            let data = try boundedData(path, maximum: record.size)
            guard data.count == record.size, Self.sha(data) == record.sha256 else { throw CloudFailure("Сохранение ещё не загрузилось из iCloud целиком. Повторите синхронизацию немного позже.") }
            result[name] = data
        }
        try validate(result)
        return result
    }
    private func apply(_ r: CloudRevision, root: URL) throws {
        let files = try readFiles(r, root: root)
        let stage = profile.deletingLastPathComponent().appendingPathComponent(".cloud-import-" + UUID().uuidString.lowercased())
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        for (name, data) in files {
            let path = stage.appendingPathComponent(name); try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: path, options: .atomic)
        }
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let backup = backups.appendingPathComponent(UUID().uuidString.lowercased())
        let hadProfile = fm.fileExists(atPath: profile.path)
        if hadProfile {
            guard renamex_np(stage.path, profile.path, UInt32(RENAME_SWAP)) == 0 else { throw CloudFailure("Не удалось атомарно заменить профиль. Прежние сохранения не менялись.") }
            try fm.moveItem(at: stage, to: backup)
        } else { try fm.moveItem(at: stage, to: profile) }
        state.base = r.id; state.fingerprint = r.fingerprint; try saveState()
        try writeHead(r.id, root: root)
    }
    private func report(_ status: String, _ rows: [CloudRevision], revision: String? = nil) -> CloudReport {
        CloudReport(status: status, revision: revision, choices: rows.map { CloudChoice(id: $0.id, device: $0.device, created: $0.created) })
    }
    func startup() throws -> CloudReport {
        try coordinate(write: true) { root in
            try checkRoot(root)
            var rows = try tips(root), local = try stableProfile()
            let localFingerprint = fingerprint(records(local))
            if playable(local) && localFingerprint != state.fingerprint {
                if state.base == nil && rows.count == 1 && rows[0].fingerprint == localFingerprint {
                    state.base = rows[0].id; state.fingerprint = localFingerprint; try saveState()
                    _ = try commit(local, parents: [rows[0].id], root: root) // first device acknowledgement, preserving ancestry
                } else {
                    if let base = state.base { _ = try revision(base, root: root) }
                    _ = try commit(local, parents: state.base.map { [$0] } ?? [], root: root)
                }
                rows = try tips(root)
            }
            if rows.count > 1 && Set(rows.map { $0.fingerprint }).count == 1 {
                let data = try readFiles(rows[0], root: root)
                let merged = try commit(data, parents: rows.map { $0.id }, root: root); rows = [merged]
            }
            guard rows.count <= 1 else { return report("conflict", rows) }
            guard let newest = rows.first else { return report("empty", []) }
            if fingerprint(records(local)) != newest.fingerprint {
                try apply(newest, root: root); local = try readProfile()
                return report("imported", [], revision: newest.id)
            }
            state.base = newest.id; state.fingerprint = newest.fingerprint; try saveState(); try writeHead(newest.id, root: root)
            return report("ready", [], revision: newest.id)
        }
    }
    func publish() throws -> CloudReport {
        try coordinate(write: true) { root in
            try checkRoot(root)
            let local = try stableProfile()
            guard playable(local) else { return report("empty", []) }
            let f = fingerprint(records(local))
            if f != state.fingerprint {
                if let base = state.base { _ = try revision(base, root: root) }
                _ = try commit(local, parents: state.base.map { [$0] } ?? [], root: root)
            }
            let rows = try tips(root)
            if rows.count > 1 { return report("conflict", rows) }
            if rows.first?.fingerprint != f { return report("remote-update", rows) }
            return report("published", [], revision: state.base)
        }
    }
    func resolve(_ id: String) throws -> CloudReport {
        try coordinate(write: true) { root in
            try checkRoot(root)
            let rows = try tips(root)
            guard let selected = rows.first(where: { $0.id == id }) else { throw CloudFailure("Выбранная копия уже не является последней. Обновите список.") }
            // Save the local branch before replacing anything, then merge the choice with every current tip.
            let local = try stableProfile()
            if playable(local) && fingerprint(records(local)) != state.fingerprint {
                _ = try commit(local, parents: state.base.map { [$0] } ?? [], root: root)
            }
            let parents = try tips(root).map { $0.id }
            let files = try readFiles(selected, root: root)
            let merged = try commit(files, parents: parents, root: root)
            try apply(merged, root: root)
            return report("resolved", [], revision: merged.id)
        }
    }
    func checkRemote() throws -> CloudReport {
        try coordinate(write: false) { root in
            try checkRoot(root)
            let rows = try tips(root)
            if rows.count > 1 { return report("conflict", rows) }
            if let row = rows.first, row.fingerprint != state.fingerprint { return report("remote-update", rows) }
            return report("ready", [], revision: state.base)
        }
    }
}
