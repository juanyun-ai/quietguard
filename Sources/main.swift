import Foundation
import SwiftUI
import AppKit
import Darwin

let arguments = Set(CommandLine.arguments.dropFirst())
if arguments.contains("--self-test") {
    exit(runRuleTests() ? 0 : 1)
} else if arguments.contains("--signal-self-test") {
    exit(runSignalSelfTest() ? 0 : 1)
} else if arguments.contains("--storage-self-test") {
    exit(runStorageTests() ? 0 : 1)
} else if arguments.contains("--portable-check") {
    do {
        let store = try PortableRuntime.result.get(); try store.validate()
        for name in ["QuietGuardMark", "QuietGuardMenu", "QuietGuardMenu@2x"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png"), let image = NSImage(contentsOf: url), image.isValid else {
                throw StorageFailure(message: "图标资源无法加载：" + name)
            }
        }
        print("PORTABLE_OK " + store.dataDirectory.path + " · artwork resources verified")
    } catch { print("PORTABLE_BLOCKED " + error.localizedDescription); exit(2) }
} else if arguments.contains("--probe") {
    probeHardware()
} else {
    do {
        let store = try PortableRuntime.result.get()
        try store.acquireLease()
        QuietGuardApplication.main()
    } catch {
        let alert = NSAlert(); alert.messageText = "长安：便携启动检查"
        alert.informativeText = error.localizedDescription + "\n请从外接卷上的完整项目目录运行，不要只复制 .app。已有实例请使用菜单栏入口。"
        alert.runModal(); exit(2)
    }
}
