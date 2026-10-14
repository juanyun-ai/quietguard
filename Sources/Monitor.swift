import Foundation
import AppKit
import Combine
import UserNotifications
import Darwin

struct TelemetryPacket {
    var time: Double
    var processes: [ProcessRecord]
    var temperature: Double?
    var average: Double?
    var sensorCount: Int
    var busy: UInt64
    var total: UInt64
    var ticksValid: Bool
    static func read() -> TelemetryPacket {
        var buffer = [QGProcess](repeating: QGProcess(), count: 4096)
        let n = Int(qg_collect(&buffer, Int32(buffer.count)))
        let rows = buffer.prefix(max(0, n)).map(ProcessRecord.init)
        var maximum = 0.0, average = 0.0, count: Int32 = 0
        let good = qg_temperature(&maximum, &average, &count) == 1
        var busy: UInt64 = 0, total: UInt64 = 0
        let ticks = qg_cpu_ticks(&busy, &total) == 1
        return TelemetryPacket(time: qg_clock(), processes: rows, temperature: good ? maximum : nil,
                               average: good ? average : nil, sensorCount: Int(count), busy: busy, total: total, ticksValid: ticks)
    }
}
struct LogEntry: Identifiable, Codable {
    var id = UUID()
    var time = Date()
    var message: String
}
struct HistoryPoint: Identifiable {
    var id = UUID()
    var temperature: Double?
    var cpu: Double?
}
struct PendingAction: Identifiable {
    var process: ProcessRecord
    var deadline: Double
    var id: String { process.id }
}

final class GuardModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let dataDirectory = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Data", isDirectory: true)
    private let store = PortableRuntime.store
    @Published private(set) var storageReady = false
    @Published private(set) var storageStatus = "正在验证外接存储…"
    private var loadingSettings = true
    private var configurationHealthy = true
    private var modeEpoch: UInt64 = 0
    private var checkingActionID: String?
    @Published var settings = GuardSettings() { didSet { saveSettings(); resetEvidence() } }
    @Published private(set) var automatic = false
    @Published private(set) var assessments: [Assessment] = []
    @Published private(set) var temperature: Double?
    @Published private(set) var averageTemperature: Double?
    @Published private(set) var totalCPU: Double?
    @Published private(set) var pressure = 0
    @Published private(set) var sensorCount = 0
    @Published private(set) var telemetryStatus = "正在读取本机传感器…"
    @Published private(set) var warningAge = 0.0
    @Published private(set) var severeAge = 0.0
    @Published private(set) var warning = false
    @Published private(set) var severe = false
    @Published private(set) var processCount = 0
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var history: [HistoryPoint] = []
    @Published private(set) var pending: [String: PendingAction] = [:]
    @Published private(set) var authorized: Set<String> = []
    @Published private(set) var now = qg_clock()
    @Published private(set) var lastUpdated: Date?
    private let engine = RuleEngine()
    private let queue = DispatchQueue(label: "QuietGuard.sampler", qos: .utility)
    private var timer: Timer?
    private var sampling = false
    private var previous: TelemetryPacket?
    private var all: [Int32: ProcessRecord] = [:]
    private var recentlyFront: [String: Double] = [:]
    private var handled: Set<String> = []
    private var wakeObservers: [NSObjectProtocol] = []
    private var lastAutoAction = -Double.infinity
    private var lastAlertLevel = 0
    private var sessionLocked = false
    private var lastTempChange = qg_clock()
    private var lastTemp: Double?
    private var notificationPermission = false
    override init() {
        super.init()
        do {
            guard let store else { throw StorageFailure(message: "便携存储初始化失败") }
            try store.validate()
            if let data = try store.read("settings.json") {
                let loaded = try JSONDecoder().decode(GuardSettings.self, from: data)
                guard loaded.valid else { throw StorageFailure(message: "规则配置损坏；自动处理已锁定") }
                settings = loaded
            }
            if let events = try store.read("events.jsonl"), let text = String(data: events, encoding: .utf8) {
                logs = text.split(separator: "\n").suffix(100).compactMap {
                    try? JSONDecoder().decode(LogEntry.self, from: Data($0.utf8))
                }.reversed()
            }
            storageReady = true; storageStatus = "外接卷便携模式 · 设置和日志随盘保存"
        } catch { configurationHealthy = false; storageFailure(error) }
        loadingSettings = false
        UNUserNotificationCenter.current().delegate = self
        let cancel = UNNotificationAction(identifier: "CANCEL", title: "取消所有自动处理", options: [])
        let category = UNNotificationCategory(identifier: "QG_PENDING", actions: [cancel], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
        let center = NSWorkspace.shared.notificationCenter
        wakeObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.resetEvidence(); self?.appendLog("电脑唤醒：连续计时和待执行动作已重置")
        })
        wakeObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.resetEvidence() })
        wakeObservers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.sessionLocked = true; self?.resetEvidence() })
        wakeObservers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.sessionLocked = false; self?.resetEvidence() })
        wakeObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if let p = self.all[app.processIdentifier] { self.recentlyFront[p.id] = qg_clock() }
            // Switching foreground invalidates pending actions until a fresh sample.
            self.pending.removeAll()
        })
        for name in [NSWorkspace.willUnmountNotification, NSWorkspace.didUnmountNotification] {
            wakeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let store = self.store else { return }
                let volume = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
                    ?? (note.userInfo?["NSDevicePath"] as? String)
                if let volume, store.root.path.hasPrefix(volume + "/") {
                    self.cancelAll(); self.appendLog("外接盘正在卸载：退出长安，不操作其他进程")
                    NSApp.terminate(nil)
                }
            })
        }
        wakeObservers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sessionLocked = true; self?.cancelAll(); self?.resetEvidence()
        })
        wakeObservers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sessionLocked = false; self?.resetEvidence()
        })
        appendLog("启动 0.2.0：外接卷便携模式，仅观察；自动授权不跨重启保留")
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.sample() }
        timer?.tolerance = 1
    }
    var statusTitle: String {
        if !storageReady { return "存储或配置异常 · 自动处理已停止" }
        if settings.projectMode { return "项目保护中" }
        if temperature == nil { return "温度数据不可用" }
        if severe { return "持续超限，需要关注" }
        if warning || pressure >= 2 { return "热状态值得关注" }
        return "安静守护，专注当下"
    }
    var pressureText: String { ["正常", "略高", "较高", "严重"][min(3, max(0, pressure))] }
    var pendingSorted: [PendingAction] { pending.values.sorted { $0.deadline < $1.deadline } }
    func resetEvidence() {
        modeEpoch &+= 1
        engine.reset(); pending.removeAll(); previous = nil
        warningAge = 0; severeAge = 0; warning = false; severe = false
    }
    private func storageFailure(_ error: Error) {
        storageReady = false; storageStatus = error.localizedDescription
        automatic = false; pending.removeAll(); authorized.removeAll(); modeEpoch &+= 1
    }
    @discardableResult private func checkStorage() -> Bool {
        do {
            guard let store, configurationHealthy else { throw StorageFailure(message: "便携存储或配置无效；请检查目录与规则") }
            try store.validate()
            storageReady = true; storageStatus = "外接卷便携模式 · 设置和日志随盘保存"
            return true
        } catch { storageFailure(error); return false }
    }
    func saveSettings() {
        guard !loadingSettings else { return }
        do {
            guard settings.valid, let store else { throw StorageFailure(message: "规则或存储无效") }
            try store.saveSettings(JSONEncoder().encode(settings))
            configurationHealthy = true
            _ = checkStorage()
        } catch { storageFailure(error) }
    }
    func appendLog(_ message: String) {
        let entry = LogEntry(message: message)
        logs.insert(entry, at: 0); if logs.count > 100 { logs.removeLast(logs.count - 100) }
        do {
            guard let store else { throw StorageFailure(message: "外接存储不可用；记录仅留在内存") }
            var data = try JSONEncoder().encode(entry); data.append(10)
            try store.appendEvent(data)
        } catch { storageFailure(error) }
    }
    private func confirmAutomaticAction(_ action: PendingAction) {
        guard checkingActionID == nil else { return }
        checkingActionID = action.id
        let epoch = modeEpoch
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] permission in
            DispatchQueue.main.async {
                guard let self else { return }
                self.checkingActionID = nil
                guard self.modeEpoch == epoch, self.pending[action.id]?.deadline == action.deadline,
                      self.automatic, !self.settings.projectMode, self.checkStorage(),
                      qg_clock() - self.now < 5,
                      self.assessments.contains(where: { $0.id == action.id && $0.eligible }) else { return }
                guard permission.authorizationStatus == .authorized, permission.alertSetting == .enabled else {
                    self.cancelAll(); self.appendLog("通知权限或横幅已关闭，取消自动结束"); return
                }
                self.execute(action.process, force: false, automated: true)
                self.lastAutoAction = qg_clock(); self.handled.insert(action.id)
                self.authorized.remove(action.id); self.pending.removeAll()
            }
        }
    }
    func sample() {
        guard !sampling else { return }
        sampling = true
        queue.async { [weak self] in
            let packet = TelemetryPacket.read()
            DispatchQueue.main.async { self?.consume(packet); self?.sampling = false }
        }
    }
    private func consume(_ packet: TelemetryPacket) {
        now = packet.time
        if !checkStorage() { resetEvidence() }
        all = Dictionary(packet.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        processCount = all.count
        let liveIDs = Set(packet.processes.map(\.id))
        authorized.formIntersection(liveIDs); handled.formIntersection(liveIDs)
        recentlyFront = recentlyFront.filter { now - $0.value < 600 && liveIDs.contains($0.key) }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let front, let p = all[front] { recentlyFront[p.id] = now }
        let dt = previous.map { now - $0.time } ?? 0
        let continuous = dt > 0 && dt <= 25
        if !continuous { pending.removeAll() }
        let old = Dictionary((previous?.processes ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        temperature = packet.temperature; averageTemperature = packet.average; sensorCount = packet.sensorCount
        pressure = ProcessInfo.processInfo.thermalState.rawValue
        if temperature != lastTemp { lastTempChange = now; lastTemp = temperature }
        let sensorFresh = temperature != nil && now - lastTempChange < 300
        if temperature == nil { telemetryStatus = "无法可靠读取 M4 CPU 温度；自动处理停用" }
        else if !sensorFresh { telemetryStatus = "温度读数长时间不变；暂不用于自动处理" }
        else { telemetryStatus = "\(sensorCount) 个 CPU 热区 · 取最高值 · 每 10 秒采样" }
        totalCPU = nil
        if continuous, packet.ticksValid, let before = previous, before.ticksValid,
           packet.total > before.total, packet.busy >= before.busy {
            totalCPU = min(100, max(0, 100 * Double(packet.busy - before.busy) / Double(packet.total - before.total)))
        }
        let observations = packet.processes.map { p -> ProcessObservation in
            var cpu: Double?, disk: UInt64?
            if continuous, let b = old[p.id] {
                if p.cpuValid && b.cpuValid && p.cpuNS >= b.cpuNS { cpu = Double(p.cpuNS - b.cpuNS) / 1e9 / dt * 100 }
                if p.diskValid && b.diskValid && p.diskBytes >= b.diskBytes { disk = p.diskBytes - b.diskBytes }
            }
            let chain = Safety.chain(p, in: all)
            let background = front != nil && !chain.contains(where: { $0.pid == front })
            var protection = Safety.soft(p, all: all, frontPID: front, settings: settings)
            if protection == nil && chain.contains(where: { recentlyFront[$0.id] != nil }) { protection = "最近 10 分钟使用过的应用" }
            if sessionLocked { protection = "会话不活跃，避免不可见的自动处理" }
            if packet.processes.count >= 4096 { protection = "进程快照达到容量上限：不自动处理" }
            return ProcessObservation(process: p, cpu: cpu, diskDelta: disk, background: background, protection: protection, authorized: authorized.contains(p.id))
        }
        let decisions = engine.ingest(now: now, temperature: sensorFresh ? temperature : nil, pressure: pressure,
                                      observations: observations, settings: settings, automatic: automatic && notificationPermission && storageReady)
        warningAge = engine.warningAge; severeAge = engine.severeAge; warning = engine.warning; severe = engine.severe
        assessments = decisions.sorted { ($0.observation.cpu ?? -1) > ($1.observation.cpu ?? -1) }
        let level = severe ? 2 : ((warning || pressure >= 2) ? 1 : 0)
        if level > lastAlertLevel {
            let message = severe ? "CPU 热区温度持续超过严重阈值；请检查负载用途。" : "热状态持续升高；监控不会仅凭温度结束进程。"
            appendLog(message); notify(title: "长安：热状态提醒", message: message)
        }
        lastAlertLevel = level
        let eligible = Dictionary(decisions.filter { $0.eligible && !handled.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        pending = pending.filter { eligible[$0.key] != nil }
        if automatic && !settings.projectMode && sensorFresh && now - lastAutoAction >= 600 {
            for d in eligible.values.sorted(by: { ($0.observation.cpu ?? 0) > ($1.observation.cpu ?? 0) }) {
                if pending[d.id] == nil {
                    let p = d.observation.process
                    pending[d.id] = PendingAction(process: p, deadline: now + 60)
                    appendLog("待处理：\(p.name) (PID \(p.pid))，60 秒后发送结束请求；可取消")
                    notify(title: "60 秒后结束已授权后台", message: "\(p.name) 满足连续超温、高 CPU、后台及低磁盘活动条件。打开长安或点取消阻止操作。", pending: true)
                }
                if let action = pending[d.id], now >= action.deadline {
                    confirmAutomaticAction(action)
                    break
                }
            }
        } else { pending.removeAll() }
        history.append(HistoryPoint(temperature: temperature, cpu: totalCPU))
        if history.count > 180 { history.removeFirst(history.count - 180) }
        previous = packet; lastUpdated = Date()
    }
    func toggleAutomatic() {
        modeEpoch &+= 1
        if automatic { automatic = false; pending.removeAll(); appendLog("已切换为仅观察模式"); return }
        guard checkStorage(), !settings.projectMode else { showMessage("暂不能启用", "请确认外接盘可用，并先手动关闭项目保护。"); return }
        let requestEpoch = modeEpoch
        let alert = NSAlert()
        alert.messageText = "开启受控自动处理？"
        alert.informativeText = "只对你逐项授权的当前进程实例生效。满足全部条件后倒计时 60 秒，再发送 SIGTERM；不会自动强制杀死。仍可能丢失该程序未保存的数据。项目保护、系统进程和开发任务保护优先。"
        alert.addButton(withTitle: "开启受控模式"); alert.addButton(withTitle: "保持观察")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self, self.modeEpoch == requestEpoch, self.checkStorage(), !self.settings.projectMode else { return }
                self.notificationPermission = granted
                self.automatic = granted
                self.appendLog(granted ? "受控自动模式已开启；未授权的进程仍不会被自动结束" : "系统通知未获许可，为避免不可见倒计时，保持仅观察")
            }
        }
    }
    func cancelAll() {
        modeEpoch &+= 1
        pending.removeAll(); automatic = false
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        appendLog("紧急停止：已取消全部待执行动作并返回仅观察模式")
    }
    func toggleProtection(_ p: ProcessRecord) {
        if settings.protectedPaths.contains(p.path) { settings.protectedPaths.remove(p.path); appendLog("移出保护名单：\(p.name)") }
        else { settings.protectedPaths.insert(p.path); authorized.remove(p.id); appendLog("加入保护名单：\(p.name)，含子进程") }
    }
    func authorize(_ p: ProcessRecord) {
        if authorized.contains(p.id) { authorized.remove(p.id); pending.removeValue(forKey: p.id); appendLog("撤销本次授权：\(p.name)"); return }
        if let reason = Safety.soft(p, all: all, frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier, settings: settings) { showMessage("无法自动处理", reason); return }
        let alert = NSAlert(); alert.messageText = "仅授权这个正在运行的进程实例？"
        alert.informativeText = "\(p.name)\nPID \(p.pid)\n\(p.path)\n\n请确认它没有必须保留的后台任务或未保存数据。CPU、温度和低磁盘活动不能证明空转。此授权不会传给重启后的同名程序。"
        alert.addButton(withTitle: "授权本次实例"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { authorized.insert(p.id); appendLog("明确授权当前实例：\(p.name) / PID \(p.pid)") }
    }
    func manualEnd(_ p: ProcessRecord, force: Bool) {
        if let reason = Safety.hard(p, all: all) { showMessage("已拦截", reason); return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = force ? "强制结束 \(p.name)？" : "向 \(p.name) 发送结束请求？"
        let protection = Safety.soft(p, all: all, frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier, settings: settings)
        alert.informativeText = "PID \(p.pid)\n\(p.path)\n\n" + (protection.map { "注意：\($0)。\n" } ?? "") + (force ? "SIGKILL 不给程序保存机会，可能丢失数据或中断项目。" : "SIGTERM 让程序有机会自行退出，但不保证保存数据；请先保存工作。")
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: force ? "确认强制结束" : "确认发送请求")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        execute(p, force: force, automated: false)
        authorized.remove(p.id); pending.removeValue(forKey: p.id)
        sample()
    }
    private func execute(_ p: ProcessRecord, force: Bool, automated: Bool) {
        guard checkStorage() else { return }
        var raw = QGProcess()
        guard qg_read_process(p.pid, &raw) == 1 else { appendLog("取消执行：进程已退出或身份读取失败"); return }
        let fresh = ProcessRecord(raw)
        guard fresh.id == p.id, fresh.uid == p.uid else { appendLog("安全拦截：PID 或可执行文件身份已改变"); return }
        var freshAll = all; freshAll[fresh.pid] = fresh
        var parent = fresh.parent
        for _ in 0..<64 {
            var r = QGProcess()
            guard parent > 1, qg_read_process(parent, &r) == 1 else { break }
            let item = ProcessRecord(r); freshAll[parent] = item
            if parent == item.parent { break }; parent = item.parent
        }
        if let reason = Safety.hard(fresh, all: freshAll) { appendLog("安全拦截：" + reason); return }
        if automated {
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let recent = Safety.chain(fresh, in: freshAll).contains { recentlyFront[$0.id] != nil }
            guard !force, automatic, !settings.projectMode, notificationPermission, !sessionLocked,
                  authorized.contains(fresh.id), qg_clock() - now < 5,
                  Safety.soft(fresh, all: freshAll, frontPID: front, settings: settings) == nil, !recent else {
                appendLog("取消自动执行：最新保护条件不再满足"); return
            }
        }
        appendLog("执行前记录：\(automated ? "自动" : "手动")请求结束 \(p.name) / PID \(p.pid)")
        guard storageReady, !automated || automatic else { return }
        let result = fresh.path.withCString { qg_signal_exact(fresh.pid, fresh.startSec, fresh.startUsec, $0, force ? SIGKILL : SIGTERM) }
        if result == 0 {
            appendLog("\(automated ? "受控自动" : "手动")：已向 \(p.name) / PID \(p.pid) 发送 \(force ? "SIGKILL" : "SIGTERM")，等待退出结果")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                var check = QGProcess()
                let alive = qg_read_process(p.pid, &check) == 1 && ProcessRecord(check).id == p.id
                self?.appendLog(alive ? "\(p.name) 仍在运行；不会自动升级为强制结束" : "已确认原进程实例退出：\(p.name)")
            }
        } else { appendLog("结束请求未执行：\(p.name)，错误 \(result) / \(String(cString: strerror(result)))") }
    }
    func showMessage(_ title: String, _ text: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.runModal()
    }
    private func notify(title: String, message: String, pending: Bool = false) {
        let content = UNMutableNotificationContent(); content.title = title; content.body = message
        content.sound = .default; if pending { content.categoryIdentifier = "QG_PENDING" }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { [weak self] error in
            if pending && error != nil {
                DispatchQueue.main.async {
                    self?.cancelAll()
                    self?.appendLog("系统未接受倒计时通知：自动处理已停用")
                }
            }
        }
    }
    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] yes, _ in
            DispatchQueue.main.async { self?.notificationPermission = yes; self?.appendLog(yes ? "系统通知已允许" : "系统通知未允许；面板仍会显示提醒") }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "CANCEL" { DispatchQueue.main.async { self.cancelAll() } }
        completionHandler()
    }
    func exportDiagnostics() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "QuietGuard-diagnostics.json"; panel.allowedContentTypes = [.json]
        panel.directoryURL = Self.dataDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let object: [String: Any] = ["version": "0.2.0", "portableDataPath": Self.dataDirectory.path, "date": ISO8601DateFormatter().string(from: Date()),
                                  "cpuTemperatureMax": temperature as Any? ?? NSNull(), "thermalState": pressureText,
                                  "logicalCPUs": ProcessInfo.processInfo.processorCount, "processCount": processCount,
                                  "mode": automatic ? "controlled" : "observe", "projectProtection": settings.projectMode,
                                  "sensorCount": sensorCount, "aiModelConnected": false,
                                  "events": logs.prefix(50).map { ["date": ISO8601DateFormatter().string(from: $0.time), "message": $0.message] }]
        do { try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic); appendLog("已手动导出诊断；未自动上传") }
        catch { showMessage("导出失败", error.localizedDescription) }
    }
}
