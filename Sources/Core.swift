import Foundation
import Darwin

struct GuardSettings: Codable {
    var warningTemperature = 65.0
    var warningSeconds = 300.0
    var severeTemperature = 70.0
    var severeSeconds = 1200.0
    var highCPUPercent = 80.0 // 100% = one logical CPU, matching Activity Monitor.
    var protectedPaths: Set<String> = []
    var projectMode = false // Remains active until explicitly turned off.
    var valid: Bool {
        warningTemperature.isFinite && severeTemperature.isFinite && warningSeconds.isFinite &&
        severeSeconds.isFinite && highCPUPercent.isFinite &&
        (45...100).contains(warningTemperature) && (warningTemperature...110).contains(severeTemperature) &&
        (60...7200).contains(warningSeconds) && (max(300, warningSeconds)...14400).contains(severeSeconds) &&
        (20...800).contains(highCPUPercent)
    }
}

struct ProcessRecord: Identifiable, Equatable {
    var pid: Int32
    var parent: Int32
    var uid: UInt32
    var startSec: UInt64
    var startUsec: UInt64
    var name: String
    var path: String
    var cpuNS: UInt64
    var memory: UInt64
    var diskBytes: UInt64
    var cpuValid: Bool
    var diskValid: Bool
    var id: String { "\(pid):\(startSec):\(startUsec):\(path)" }
    init(_ raw: QGProcess) {
        pid = raw.pid; parent = raw.ppid; uid = raw.uid
        startSec = raw.start_sec; startUsec = raw.start_usec
        name = tupleString(raw.name); path = tupleString(raw.path)
        cpuNS = raw.cpu_ns; memory = raw.resident_bytes; diskBytes = raw.io_bytes
        cpuValid = raw.cpu_valid == 1; diskValid = raw.io_valid == 1
        if name.isEmpty { name = URL(fileURLWithPath: path).lastPathComponent }
    }
    init(pid: Int32 = 90001, parent: Int32 = 1, name: String = "ExampleHelper", path: String = "/Applications/Example.app/Contents/MacOS/Example", start: UInt64 = 100) {
        self.pid = pid; self.parent = parent; uid = getuid(); startSec = start; startUsec = 0
        self.name = name; self.path = path; cpuNS = 0; memory = 0; diskBytes = 0; cpuValid = true; diskValid = true
    }
}
func tupleString<T>(_ tuple: T) -> String {
    var t = tuple
    return withUnsafeBytes(of: &t) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
}
func elapsedLabel(_ seconds: Double) -> String {
    if seconds < 60 { return "\(Int(max(0, seconds))) 秒" }
    return "\(Int(seconds / 60)) 分 \(Int(seconds) % 60) 秒"
}

struct ProcessObservation {
    var process: ProcessRecord
    var cpu: Double?
    var diskDelta: UInt64?
    var background: Bool
    var protection: String?
    var authorized: Bool
}
struct Assessment: Identifiable {
    var observation: ProcessObservation
    var level: Int
    var reason: String
    var highSeconds: Double
    var backgroundSeconds: Double
    var quietSeconds: Double
    var baseline: Double
    var eligible: Bool
    var id: String { observation.process.id }
}

// Pure local rules; there is deliberately no signal, shell, network or LLM call here.
final class RuleEngine {
    struct Window {
        var high: Double?
        var background: Double?
        var quiet: Double?
        var baseline = 0.0
    }
    private(set) var warningStart: Double?
    private(set) var severeStart: Double?
    private var lastTime: Double?
    private var windows: [String: Window] = [:]
    private(set) var warningAge = 0.0
    private(set) var severeAge = 0.0
    private(set) var warning = false
    private(set) var severe = false
    func reset() {
        warningStart = nil; severeStart = nil; lastTime = nil; windows.removeAll()
        warningAge = 0; severeAge = 0; warning = false; severe = false
    }
    private func track(_ start: inout Double?, condition: Bool, now: Double) -> Double {
        if !condition { start = nil; return 0 }
        if start == nil { start = now }
        return max(0, now - (start ?? now))
    }
    func ingest(now: Double, temperature: Double?, pressure: Int, observations: [ProcessObservation], settings: GuardSettings, automatic: Bool) -> [Assessment] {
        guard now.isFinite, settings.valid else { reset(); return [] }
        if let last = lastTime, now <= last || now - last > 25 { reset() }
        lastTime = now
        let validTemp = temperature.flatMap { $0.isFinite && (10...120).contains($0) ? $0 : nil }
        warningAge = track(&warningStart, condition: validTemp.map { $0 > settings.warningTemperature } ?? false, now: now)
        severeAge = track(&severeStart, condition: validTemp.map { $0 > settings.severeTemperature } ?? false, now: now)
        warning = warningStart != nil && warningAge >= settings.warningSeconds
        severe = severeStart != nil && severeAge >= settings.severeSeconds
        let live = Set(observations.map { $0.process.id })
        windows = windows.filter { live.contains($0.key) }
        return observations.map { o in
            var w = windows[o.process.id] ?? Window()
            let cpu = o.cpu.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let high = track(&w.high, condition: cpu.map { $0 >= settings.highCPUPercent } ?? false, now: now)
            let background = track(&w.background, condition: o.background, now: now)
            // Low disk I/O is only a veto / heuristic, NEVER proof of useless computation.
            let quiet = track(&w.quiet, condition: o.diskDelta.map { $0 < 32768 } ?? false, now: now)
            let oldBaseline = w.baseline
            if let cpu { w.baseline = w.baseline == 0 ? cpu : 0.97 * w.baseline + 0.03 * cpu }
            windows[o.process.id] = w
            var level = 0
            var reason = "正常观察；没有足够证据判定空转"
            var eligible = false
            if let protection = o.protection { reason = "受保护：" + protection }
            else if !o.background { reason = "前台或前台关系不明：不自动处理" }
            else if cpu == nil { reason = "CPU 数据不完整：不自动处理" }
            else if high >= settings.warningSeconds {
                level = 1
                reason = "持续高 CPU；低磁盘写入也不能证明空转"
                if severe { level = 2; reason = "温度与后台负载持续超限，建议检查用途" }
                if !o.authorized { reason += " · 未授权自动结束" }
                else if settings.projectMode { reason += " · 项目保护中" }
                else if !automatic { reason += " · 仅观察" }
                else if validTemp == nil { reason += " · 温度不可用" }
                else if o.diskDelta == nil { reason += " · 磁盘活动不可验证" }
                else if quiet < 300 { reason += " · 近期存在磁盘活动" }
                else if !severe || high < settings.severeSeconds || background < settings.severeSeconds { reason += " · 连续时长不足" }
                else { eligible = true; level = 3; reason = "已授权的后台实例满足全部规则，进入可撤销倒计时" }
            } else if pressure >= 2 {
                reason = "系统热压力升高；不据此归罪于单一进程"
            }
            return Assessment(observation: o, level: level, reason: reason, highSeconds: high,
                              backgroundSeconds: background, quietSeconds: quiet, baseline: oldBaseline, eligible: eligible)
        }
    }
}

// Hard exclusions apply to both manual and automatic controls.
// Soft exclusions apply to automation; manual action requires an explicit warning.
enum Safety {
    static func chain(_ process: ProcessRecord, in all: [Int32: ProcessRecord]) -> [ProcessRecord] {
        var result = [process], seen: Set<Int32> = [process.pid], parent = process.parent
        for _ in 0..<64 {
            guard parent > 1, !seen.contains(parent), let p = all[parent] else { break }
            result.append(p); seen.insert(parent); parent = p.parent
        }
        return result
    }
    static func hard(_ process: ProcessRecord, all: [Int32: ProcessRecord]) -> String? {
        if process.uid != getuid() || process.uid == 0 { return "系统或其他用户进程" }
        if process.pid <= 1 || process.startSec == 0 || process.path.isEmpty { return "身份信息不完整" }
        if process.pid == getpid() { return "守护程序自身" }
        if ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"].contains(where: { process.path.hasPrefix($0) }) { return "macOS 系统组件" }
        let identity = (process.name + " " + process.path).lowercased()
        if identity.contains("codexpro") || identity.contains("quietguard") { return "本地连接或守护组件" }
        let core = ["kernel_task", "launchd", "windowserver", "loginwindow", "powerd", "thermalmonitord", "coreaudiod", "securityd", "trustd", "tccd", "backupd", "softwareupdated", "installd", "mds", "mds_stores"]
        if core.contains(process.name.lowercased()) || process.name.lowercased().hasPrefix("mdworker") { return "关键系统服务" }
        if let me = all[getpid()], chain(me, in: all).contains(where: { $0.pid == process.pid }) { return "当前守护程序的父进程" }
        return nil
    }
    static func soft(_ process: ProcessRecord, all: [Int32: ProcessRecord], frontPID: Int32?, settings: GuardSettings) -> String? {
        if let hard = hard(process, all: all) { return hard }
        guard let frontPID else { return "无法确认前台应用" }
        let parents = chain(process, in: all)
        guard let last = parents.last, last.parent <= 1 else { return "父进程链不完整：不自动处理" }
        if parents.contains(where: { $0.pid == frontPID }) { return "前台应用及其子进程" }
        if parents.contains(where: { settings.protectedPaths.contains($0.path) }) { return "你的保护名单（含子进程）" }
        let tools = ["swift", "swift-frontend", "xcodebuild", "clang", "clang++", "cc", "gcc", "make", "cmake", "ninja", "cargo", "rustc", "go", "git", "rsync", "ffmpeg", "blender", "handbrake", "java", "node", "bun", "npm", "pnpm", "yarn", "python", "python3", "ruby", "perl", "ollama", "docker", "postgres", "mysqld", "redis-server", "sqlite3", "codex", "opencode"]
        let appMarkers = ["terminal.app/", "iterm.app/", "xcode.app/", "visual studio code.app/", "cursor.app/", "jetbrains", "pycharm.app/", "idea.app/", "lm studio.app/", "final cut pro.app/", "davinci resolve", "obs.app/"]
        for p in parents {
            let n = p.name.lowercased(), path = p.path.lowercased()
            if tools.contains(n) || n.hasPrefix("python3.") || appMarkers.contains(where: { path.contains($0) }) {
                return "开发、计算、录制或数据任务（保守保护）"
            }
        }
        return nil
    }
}
