import Foundation
import Darwin

func runStorageTests() -> Bool {
    var passed = 0, failed = 0
    func check(_ value: Bool, _ label: String) {
        if value { passed += 1; print("PASS  " + label) }
        else { failed += 1; print("FAIL  " + label) }
    }
    func rejected(_ label: String, _ action: () throws -> Void) {
        do { try action(); check(false, label) } catch { check(true, label) }
    }
    let fm = FileManager.default
    // Fixtures remain on the external volume. No actual user data or disk is detached.
    let work = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Work/StorageTests-" + UUID().uuidString, isDirectory: true)
    do {
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let volume = try work.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString!
        func fixture(_ name: String) throws -> (URL, PortableIdentity) {
            let url = work.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: url.appendingPathComponent("Data"), withIntermediateDirectories: true)
            let id = PortableIdentity(schema: 1, storageID: UUID().uuidString, volumeUUID: volume)
            try JSONEncoder().encode(id).write(to: url.appendingPathComponent("QuietGuard.portable.json"))
            return (url, id)
        }
        let (base, id) = try fixture("roundtrip")
        let store = try PortableStore(root: base, identity: id)
        try store.validate(); check(true, "portable volume and marker identity validate")
        check(try store.read("settings.json") == nil, "missing settings stay absent instead of being invented")
        let data = try JSONEncoder().encode(GuardSettings())
        try store.saveSettings(data)
        check(try store.read("settings.json") == data, "atomic settings round-trip")
        var saved = GuardSettings(); saved.projectMode = true
        try store.saveSettings(JSONEncoder().encode(saved))
        let restored = try JSONDecoder().decode(GuardSettings.self, from: store.read("settings.json")!)
        check(restored.projectMode, "project protection survives a storage round-trip")
        try store.appendEvent(Data("first\n".utf8)); try store.appendEvent(Data("second\n".utf8))
        check(try store.read("events.jsonl") == Data("first\nsecond\n".utf8), "events append in order")
        rejected("path traversal filenames are rejected") { _ = try store.read("../outside") }
        let stranger = PortableIdentity(schema: 1, storageID: UUID().uuidString, volumeUUID: volume)
        rejected("wrong storage identity is rejected") { _ = try PortableStore(root: base, identity: stranger) }
        let wrongDisk = PortableIdentity(schema: 1, storageID: id.storageID, volumeUUID: UUID().uuidString)
        rejected("wrong physical volume UUID is rejected") { _ = try PortableStore(root: base, identity: wrongDisk) }
        let (missing, missingID) = try fixture("missing-data")
        try fm.removeItem(at: missing.appendingPathComponent("Data"))
        rejected("missing Data directory blocks initialization") { _ = try PortableStore(root: missing, identity: missingID) }
        check(!fm.fileExists(atPath: missing.appendingPathComponent("Data").path), "runtime does not recreate missing storage")
        let (altered, alteredID) = try fixture("altered-marker")
        let alteredStore = try PortableStore(root: altered, identity: alteredID)
        try Data("{}".utf8).write(to: altered.appendingPathComponent("QuietGuard.portable.json"))
        rejected("damaged marker blocks existing store") { try alteredStore.validate() }
        let (gone, goneID) = try fixture("removed-data")
        let goneStore = try PortableStore(root: gone, identity: goneID)
        try fm.moveItem(at: gone.appendingPathComponent("Data"), to: gone.appendingPathComponent("Data-detached"))
        rejected("lost data directory blocks writes") { try goneStore.appendEvent(Data("must-not-write".utf8)) }
        check(!fm.fileExists(atPath: gone.appendingPathComponent("Data").path), "failed write creates no fallback directory")
        try fm.createDirectory(at: gone.appendingPathComponent("Data"), withIntermediateDirectories: false)
        rejected("replacement directory cannot inherit old identity") { try goneStore.validate() }
        let (sym, symID) = try fixture("symlink-data")
        try fm.removeItem(at: sym.appendingPathComponent("Data"))
        try fm.createSymbolicLink(at: sym.appendingPathComponent("Data"), withDestinationURL: base.appendingPathComponent("Data"))
        rejected("symlinked data directory is refused") { _ = try PortableStore(root: sym, identity: symID) }
        let (files, filesID) = try fixture("symlink-settings")
        let fileStore = try PortableStore(root: files, identity: filesID)
        let outside = files.appendingPathComponent("do-not-touch.txt")
        try Data("untouched".utf8).write(to: outside)
        try fm.createSymbolicLink(at: files.appendingPathComponent("Data/settings.json"), withDestinationURL: outside)
        rejected("settings symlink cannot be overwritten") { try fileStore.saveSettings(data) }
        check(try Data(contentsOf: outside) == Data("untouched".utf8), "symlink target remains unchanged")
        let (rotate, rotateID) = try fixture("rotation")
        let rotator = try PortableStore(root: rotate, identity: rotateID)
        try Data(repeating: 65, count: 1_000_001).write(to: rotate.appendingPathComponent("Data/events.jsonl"))
        try rotator.appendEvent(Data("new\n".utf8))
        check(try rotator.read("events.previous.jsonl")?.count == 1_000_001, "oversize event file rotates to previous")
        check(try rotator.read("events.jsonl") == Data("new\n".utf8), "rotation starts a fresh active log")
        let (locked, lockedID) = try fixture("single-instance")
        do {
            let one = try PortableStore(root: locked, identity: lockedID); try one.acquireLease()
            let two = try PortableStore(root: locked, identity: lockedID)
            rejected("second instance cannot acquire the same lease") { try two.acquireLease() }
        }
        let next = try PortableStore(root: locked, identity: lockedID); try next.acquireLease()
        check(true, "lease releases when the prior instance ends")
        let (renamed, renamedID) = try fixture("renamed-root")
        let movedStore = try PortableStore(root: renamed, identity: renamedID)
        try fm.moveItem(at: renamed, to: work.appendingPathComponent("renamed-root-new"))
        rejected("moved root blocks old live storage handle") { try movedStore.validate() }
    } catch { check(false, "unexpected fixture error: " + error.localizedDescription) }
    print("\nPortable storage tests: \(passed) passed, \(failed) failed. Only isolated external-drive fixtures used.")
    return failed == 0
}
