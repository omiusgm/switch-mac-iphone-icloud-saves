import Foundation

@main struct CloudTests {
    static let fm = FileManager.default
    static let uid = Data([1,0,0,0,0,0,0,0,2,0,0,0,0,0,0,0])
    static let slot = "save/00000000000000020000000000000001/0/game_data.sav"
    static var checks = 0
    static func fixture(_ root: URL, _ value: String) throws {
        try fm.createDirectory(at: root.appendingPathComponent(slot).deletingLastPathComponent(), withIntermediateDirectories: true)
        try uid.write(to: root.appendingPathComponent("account.uid"))
        try Data(value.utf8).write(to: root.appendingPathComponent(slot), options: .atomic)
    }
    static func value(_ root: URL) throws -> String { String(decoding: try Data(contentsOf: root.appendingPathComponent(slot)), as: UTF8.self) }
    static func require(_ condition: Bool, _ label: String) throws { if !condition { throw CloudFailure("Test failed: " + label) }; checks += 1 }
    static func main() {
        let root = fm.temporaryDirectory.appendingPathComponent("botw-cloud-tests-" + UUID().uuidString)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: root) }
            let cloud = root.appendingPathComponent("cloud")
            try CloudSaveEngine.initializeRoot(cloud)
            func engine(_ name: String) throws -> CloudSaveEngine {
                try CloudSaveEngine(profile: root.appendingPathComponent(name + "/profile"), cloud: cloud,
                    stateURL: root.appendingPathComponent(name + "/state.json"), backups: root.appendingPathComponent(name + "/backups"), device: name)
            }
            let ap = root.appendingPathComponent("Mac/profile"), bp = root.appendingPathComponent("iPhone/profile")
            try fixture(ap, "one"); let a = try engine("Mac"), b = try engine("iPhone")
            try require(try a.startup().status == "ready", "first publication")
            try require(try b.startup().status == "imported" && value(bp) == "one", "Mac to phone import")
            try fixture(bp, "phone-two"); _ = try b.publish()
            try require(try a.startup().status == "imported" && value(ap) == "phone-two", "phone to Mac import")
            try require(!(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Mac/backups").path)).isEmpty, "original profile backed up")
            try fixture(ap, "mac-three"); try fixture(bp, "phone-three")
            _ = try a.publish(); try require(try b.publish().status == "conflict", "divergent histories detected")
            let conflict = try a.startup()
            try require(conflict.status == "conflict" && value(ap) == "mac-three" && value(bp) == "phone-three", "conflict does not overwrite either device")
            guard let phone = conflict.choices.first(where: { $0.device == "iPhone" }) else { throw CloudFailure("Missing phone choice") }
            _ = try a.resolve(phone.id); _ = try b.startup()
            try require(try value(ap) == "phone-three" && value(bp) == "phone-three", "explicit conflict resolution merges ancestry")
            try fixture(bp, "pending-four"); _ = try b.publish()
            let blob = cloud.appendingPathComponent("Objects/" + CloudSaveEngine.sha(Data("pending-four".utf8)))
            let parked = root.appendingPathComponent("not-uploaded-yet")
            try fm.moveItem(at: blob, to: parked)
            var refused = false
            do { _ = try a.startup() } catch { refused = true }
            try require(try refused && value(ap) == "phone-three", "head arriving before payload does not damage local save")
            try fm.moveItem(at: parked, to: blob)
            _ = try a.startup(); try require(try value(ap) == "pending-four", "late cloud payload recovers")
            try fixture(bp, "corrupt-five"); _ = try b.publish()
            let bad = cloud.appendingPathComponent("Objects/" + CloudSaveEngine.sha(Data("corrupt-five".utf8)))
            try Data("bad".utf8).write(to: bad); refused = false
            do { _ = try a.startup() } catch { refused = true }
            try require(try refused && value(ap) == "pending-four", "corrupted payload rejected before import")
            try Data("corrupt-five".utf8).write(to: bad)
            let c = try engine("new-device"), cp = root.appendingPathComponent("new-device/profile")
            try fixture(cp, "unknown-local")
            try require(try c.startup().status == "conflict" && value(cp) == "unknown-local", "unrelated first local profile preserved")
            let linkProfile = root.appendingPathComponent("symlink/profile")
            try fm.createDirectory(at: linkProfile, withIntermediateDirectories: true)
            try uid.write(to: linkProfile.appendingPathComponent("account.uid"))
            try fm.createSymbolicLink(at: linkProfile.appendingPathComponent("save"), withDestinationURL: root.appendingPathComponent("Mac/profile/save"))
            refused = false
            do { _ = try engine("symlink").startup() } catch { refused = true }
            try require(refused, "symlink profile rejected")
            print("Cloud save engine: \(checks) checks passed, including two-way import, divergent histories, backups, partial uploads, corruption and symlinks.")
        } catch { fputs((error.localizedDescription + "\n"), stderr); exit(1) }
    }
}
