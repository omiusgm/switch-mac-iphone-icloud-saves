import Foundation

struct CloudMacConfig: Codable { let profile: String, cloud: String, state: String, backups: String; let game_app: String? }
@main struct CloudCLI {
    static func retryCloud(_ block: () throws -> CloudReport) throws -> CloudReport {
        let deadline = Date().addingTimeInterval(20)
        while true {
            do { return try block() }
            catch {
                let e = error as NSError
                let pending = e.domain == NSCocoaErrorDomain && [256, 260].contains(e.code)
                    || error.localizedDescription.contains("ещё загру") || error.localizedDescription.contains("ещё не загру")
                guard pending && Date() < deadline else { throw error }
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }
    static func main() {
        do {
            let args = CommandLine.arguments
            guard args.count >= 3 else { throw CloudFailure("Укажите действие и файл настроек синхронизации.") }
            let action = args[1], config = try JSONDecoder().decode(CloudMacConfig.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
            if ["before", "seed", "resolve", "after"].contains(action) {
                let process = Process(), pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/ps"); process.arguments = ["-axww", "-o", "comm="]; process.standardOutput = pipe
                try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw CloudFailure("Не удалось проверить, закрыта ли игра.") }
                let app = config.game_app ?? NSHomeDirectory() + "/Applications/Breath of the Wild.app"
                let expected = URL(fileURLWithPath: app).resolvingSymlinksInPath().path + "/Contents/"
                let running = String(decoding: data, as: UTF8.self).split(separator: "\n").contains { row in
                    let path = String(row).trimmingCharacters(in: .whitespacesAndNewlines)
                    return path.hasPrefix(expected) || URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(expected)
                }
                guard !running else {
                    throw CloudFailure("Сначала сохранитесь и полностью закройте Zelda на Mac.")
                }
            }
            let root = URL(fileURLWithPath: config.cloud, isDirectory: true)
            if action == "seed" { try CloudSaveEngine.initializeRoot(root) }
            let engine = try CloudSaveEngine(profile: URL(fileURLWithPath: config.profile), cloud: root,
                stateURL: URL(fileURLWithPath: config.state), backups: URL(fileURLWithPath: config.backups), device: "Mac")
            let report: CloudReport
            switch action {
            case "before", "seed": report = try retryCloud { try engine.startup() }
            case "after": report = try retryCloud { try engine.publish() }
            case "resolve":
                guard args.count == 4 else { throw CloudFailure("Нужен идентификатор выбранной копии.") }
                report = try engine.resolve(args[3])
            default: throw CloudFailure("Неизвестное действие синхронизации.")
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } catch {
            let data = try! JSONSerialization.data(withJSONObject: ["status": "unavailable", "message": error.localizedDescription])
            print(String(decoding: data, as: UTF8.self)); exit(1)
        }
    }
}
