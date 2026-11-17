import Foundation

@main struct RecoveryTests {
    static let fm = FileManager.default
    static let uid = Data([1,0,0,0,0,0,0,0,2,0,0,0,0,0,0,0])
    static let slot = "save/00000000000000020000000000000001/0/game_data.sav"
    static let decoder = JSONDecoder()

    struct Rig {
        let root: URL
        var cloud: URL { root.appendingPathComponent("cloud") }
        func profile(_ device: String) -> URL { root.appendingPathComponent("\(device)/profile") }
        func state(_ device: String) -> URL { root.appendingPathComponent("\(device)/state.json") }
        func backup(_ device: String) -> URL { root.appendingPathComponent("\(device)/backups") }
        func engine(_ device: String) throws -> CloudSaveEngine {
            try CloudSaveEngine(profile: profile(device), cloud: cloud, stateURL: state(device), backups: backup(device), device: device)
        }
        func head(_ device: CloudSaveEngine) -> URL { cloud.appendingPathComponent("Devices/\(device.deviceID).json") }
        func headID(_ device: CloudSaveEngine) throws -> String {
            try decoder.decode(CloudHead.self, from: Data(contentsOf: head(device))).revision
        }
        func snapshot(_ id: String) -> URL { cloud.appendingPathComponent("Snapshots/\(id).json") }
        func revision(_ id: String) throws -> CloudRevision {
            try decoder.decode(CloudRevision.self, from: Data(contentsOf: snapshot(id)))
        }
        func put(_ device: String, _ value: String) throws {
            let path = profile(device).appendingPathComponent(slot)
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try uid.write(to: profile(device).appendingPathComponent("account.uid"))
            try Data(value.utf8).write(to: path, options: .atomic)
        }
        func value(_ device: String) throws -> String {
            String(decoding: try Data(contentsOf: profile(device).appendingPathComponent(slot)), as: UTF8.self)
        }
        func slotInode(_ device: String) throws -> NSNumber? {
            try fm.attributesOfItem(atPath: profile(device).appendingPathComponent(slot).path)[.systemFileNumber] as? NSNumber
        }
    }

    static func require(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        if try !condition() { throw CloudFailure("Test failed: " + label) }
    }
    static func scenario(_ name: String, _ run: (Rig, CloudSaveEngine, CloudSaveEngine, CloudSaveEngine, String, String) throws -> Void) throws {
        let root = fm.temporaryDirectory.appendingPathComponent("botw-cloud-recovery-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let rig = Rig(root: root)
        try CloudSaveEngine.initializeRoot(rig.cloud)
        let mac = try rig.engine("Mac"), phone = try rig.engine("iPhone"), pad = try rig.engine("iPad")
        try rig.put("Mac", "old")
        let old = try mac.startup().revision!
        _ = try phone.startup(); _ = try pad.startup()
        let stale = try Data(contentsOf: rig.head(phone))
        try rig.put("iPhone", "phone-new")
        let new = try phone.publish().revision!
        try stale.write(to: rig.head(phone), options: .atomic)
        try run(rig, mac, phone, pad, old, new)
        print("PASS \(name)")
    }
    static func expectRefused(_ rig: Rig, _ phone: CloudSaveEngine, _ expectedHead: String, value: String = "phone-new") throws {
        let beforeState = try Data(contentsOf: rig.state("iPhone"))
        let beforeInode = try rig.slotInode("iPhone")
        var refused = false
        do { _ = try phone.startup() } catch { refused = true }
        try require(refused, "ambiguous startup is refused")
        try require(try rig.headID(phone) == expectedHead, "head is untouched")
        try require(try Data(contentsOf: rig.state("iPhone")) == beforeState, "state is untouched")
        try require(try rig.slotInode("iPhone") == beforeInode && rig.value("iPhone") == value, "profile is untouched")
    }

    static func main() throws {
        if CommandLine.arguments.contains("--original") {
            try scenario("unpatched startup rolls back the local profile") { rig, _, phone, _, old, _ in
                let report = try phone.startup()
                try require(report.status == "imported" && report.revision == old, "reports old head imported")
                try require(try rig.value("iPhone") == "old", "profile now contains older data")
                let backups = try fm.contentsOfDirectory(at: rig.backup("iPhone"), includingPropertiesForKeys: nil)
                try require(backups.count == 1, "newer profile survives in backup")
                try require(try Data(contentsOf: backups[0].appendingPathComponent(slot)) == Data("phone-new".utf8), "backup actually has newer bytes")
            }
            return
        }
        try scenario("repairs original head without importing") { rig, mac, phone, _, _, new in
            let inode = try rig.slotInode("iPhone")
            let oldState = try Data(contentsOf: rig.state("iPhone"))
            let report = try phone.startup()
            try require(report.status == "ready" && report.revision == new, "acknowledges newer local copy")
            try require(try rig.headID(phone) == new, "phone head visible")
            try require(try rig.slotInode("iPhone") == inode && rig.value("iPhone") == "phone-new", "does not replace local profile")
            try require(try Data(contentsOf: rig.state("iPhone")) == oldState, "state bytes unchanged")
            try require(try mac.startup().revision == new && rig.value("Mac") == "phone-new", "other device finds the recovered revision")
        }
        try scenario("independent iPad change before repair") { rig, _, phone, pad, _, new in
            try rig.put("iPad", "pad-new")
            let padID = try pad.publish().revision!
            for _ in 0..<2 {
                let report = try phone.startup()
                try require(report.status == "conflict" && Set(report.choices.map(\.id)) == [new, padID], "both branches require choice")
                try require(try rig.headID(phone) == new && rig.headID(pad) == padID, "independent heads preserved")
                try require(try rig.value("iPhone") == "phone-new" && rig.value("iPad") == "pad-new", "independent profiles preserved")
            }
        }
        try scenario("equal independent profiles merge without changing either profile") { rig, _, phone, pad, _, new in
            try rig.put("iPad", "phone-new")
            let padID = try pad.publish().revision!
            let phoneInode = try rig.slotInode("iPhone"), padInode = try rig.slotInode("iPad")
            let report = try phone.startup()
            try require(report.status == "ready", "equal bytes are merged without a prompt")
            let merged = try rig.revision(report.revision!)
            try require(Set(merged.parents) == [new, padID], "merge records both independent parents")
            try require(try merged.fingerprint == rig.revision(new).fingerprint && merged.fingerprint == rig.revision(padID).fingerprint,
                        "merge preserves the shared payload")
            try require(try rig.headID(phone) == merged.id && rig.headID(pad) == padID, "only phone head advances")
            try require(try rig.slotInode("iPhone") == phoneInode && rig.slotInode("iPad") == padInode
                        && rig.value("iPhone") == "phone-new" && rig.value("iPad") == "phone-new", "both profiles retain their bytes and inode")
            try require(try pad.startup().revision == merged.id, "other parent is recognized as an ancestor")
        }
        try scenario("independent iPad change after repair") { rig, _, phone, pad, _, new in
            try require(try phone.startup().revision == new, "repair succeeded")
            try rig.put("iPad", "pad-new")
            try require(try pad.publish().status == "conflict", "late branch is reported")
            let report = try phone.startup()
            try require(report.status == "conflict" && report.choices.count == 2, "repair did not prevent the other branch")
            try require(try rig.value("iPhone") == "phone-new" && rig.value("iPad") == "pad-new", "both saves remain")
        }
        try scenario("missing manifest") { rig, _, phone, _, old, new in
            try fm.removeItem(at: rig.snapshot(new))
            try expectRefused(rig, phone, old)
        }
        try scenario("incomplete blob") { rig, _, phone, _, old, _ in
            let blob = rig.cloud.appendingPathComponent("Objects/" + CloudSaveEngine.sha(Data("phone-new".utf8)))
            try Data("partial".utf8).write(to: blob)
            try expectRefused(rig, phone, old)
        }
        try scenario("cycle in the detached local history") { rig, _, phone, _, old, new in
            let snapshot = rig.snapshot(new)
            var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: snapshot)) as! [String: Any]
            raw["parents"] = [old, new]
            try JSONSerialization.data(withJSONObject: raw).write(to: snapshot, options: .atomic)
            try expectRefused(rig, phone, old)
        }
        try scenario("different revision already occupies this device head") { rig, _, phone, pad, _, _ in
            try rig.put("iPad", "pad-new")
            let other = try pad.publish().revision!
            try Data(contentsOf: rig.head(pad)).write(to: rig.head(phone), options: .atomic)
            try expectRefused(rig, phone, other)
        }
        try scenario("dirty local profile with detached base fails closed and remains recoverable") { rig, _, phone, _, old, new in
            try rig.put("iPhone", "phone-dirty")
            try expectRefused(rig, phone, old, value: "phone-dirty")

            let dirty = try rig.value("iPhone")
            let savedRecord = try rig.revision(new).files[slot]!
            let savedBytes = try Data(contentsOf: rig.cloud.appendingPathComponent("Objects/" + savedRecord.sha256))
            try require(savedBytes.count == savedRecord.size && CloudSaveEngine.sha(savedBytes) == savedRecord.sha256,
                        "recoverable base bytes are independently verified")
            try rig.put("iPhone", String(decoding: savedBytes, as: UTF8.self))
            try require(try phone.startup().revision == new, "verified profile reattaches its original base")
            try rig.put("iPhone", dirty)
            let child = try rig.revision(phone.startup().revision!)
            try require(child.parents == [new], "restored dirty profile publishes as a child of its proper base")
            try require(try rig.value("iPhone") == "phone-dirty", "dirty progress survives recovery")
        }
        try scenario("remote descendant remains authoritative") { rig, _, phone, pad, _, new in
            _ = try phone.startup()
            try require(try pad.startup().revision == new, "iPad saw restored head")
            try rig.put("iPad", "pad-next")
            let descendant = try pad.publish().revision!
            try require(try phone.startup().revision == descendant && rig.value("iPhone") == "pad-next", "phone imports genuine descendant")
        }
    }
}
