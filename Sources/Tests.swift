import Foundation
import Darwin

func runRuleTests() -> Bool {
    var passed = 0, failed = 0
    func check(_ value: @autoclosure () -> Bool, _ name: String) {
        if value() { passed += 1; print("PASS  " + name) }
        else { failed += 1; print("FAIL  " + name) }
    }
    let settings = GuardSettings()
    let record = ProcessRecord()
    let allowed = ProcessObservation(process: record, cpu: 100, diskDelta: 0, background: true, protection: nil, authorized: true)
    func feed(_ engine: RuleEngine, temp: Double? = 71, observation: ProcessObservation? = nil, automatic: Bool = true, config: GuardSettings? = nil, until: Int = 1200) -> Assessment {
        var output: [Assessment] = []
        for t in stride(from: 0, through: until, by: 10) {
            output = engine.ingest(now: Double(t), temperature: temp, pressure: 0, observations: [observation ?? allowed], settings: config ?? settings, automatic: automatic)
        }
        return output[0]
    }
    check(settings.valid, "default settings are valid")
    var bad = settings; bad.warningTemperature = .nan
    check(!bad.valid, "reject NaN settings")
    bad = settings; bad.severeTemperature = 60
    check(!bad.valid, "reject inverted temperature thresholds")
    bad = settings; bad.severeSeconds = 200
    check(!bad.valid, "reject severe duration shorter than safety floor")
    let goodEngine = RuleEngine()
    let good = feed(goodEngine)
    check(good.eligible, "all explicit conditions qualify at 20 minutes")
    check(good.highSeconds == 1200 && good.backgroundSeconds == 1200, "continuous durations use elapsed time")
    check(!feed(RuleEngine(), until: 1190).eligible, "19m50s does not meet 20m")
    check(!feed(RuleEngine(), automatic: false).eligible, "observe mode can never authorize an action")
    var changed = allowed; changed.authorized = false
    check(!feed(RuleEngine(), observation: changed).eligible, "missing per-instance consent blocks action")
    changed = allowed; changed.protection = "project tool"
    check(!feed(RuleEngine(), observation: changed).eligible, "protected process wins over severity")
    var project = settings; project.projectMode = true
    check(!feed(RuleEngine(), config: project).eligible, "global project mode blocks automation")
    changed = allowed; changed.background = false
    check(!feed(RuleEngine(), observation: changed).eligible, "foreground task is not eligible")
    changed = allowed; changed.cpu = nil
    check(!feed(RuleEngine(), observation: changed).eligible, "unknown CPU usage fails closed")
    changed = allowed; changed.cpu = 79.9
    check(!feed(RuleEngine(), observation: changed).eligible, "below high-CPU threshold is not eligible")
    changed = allowed; changed.cpu = 80
    check(feed(RuleEngine(), observation: changed).eligible, "high-CPU threshold is inclusive")
    changed = allowed; changed.diskDelta = 50000
    check(!feed(RuleEngine(), observation: changed).eligible, "ongoing disk activity vetoes action")
    changed = allowed; changed.diskDelta = nil
    check(!feed(RuleEngine(), observation: changed).eligible, "unavailable disk counters fail closed")
    check(!feed(RuleEngine(), temp: nil).eligible, "missing temperature never implies zero or safe action")
    check(!feed(RuleEngine(), temp: .nan).eligible, "NaN temperature blocks automation")
    check(!feed(RuleEngine(), temp: 200).eligible, "implausible sensor value blocks automation")
    check(!feed(RuleEngine(), temp: 70).eligible, "exactly 70 does not satisfy strictly greater than 70")
    let edge = RuleEngine(); _ = feed(edge, temp: 65, until: 300)
    check(!edge.warning, "exactly 65 does not satisfy strictly greater than 65")
    let edgeAbove = RuleEngine(); _ = feed(edgeAbove, temp: 65.1, until: 300)
    check(edgeAbove.warning, "above 65 for 5 minutes produces a warning")
    for temperature in [71.0, 80.0, 90.0, 100.0] {
        check(feed(RuleEngine(), temp: temperature).eligible, "severity is monotonic at \(temperature) C")
    }
    let gap = RuleEngine(); _ = feed(gap)
    let afterGap = gap.ingest(now: 1800, temperature: 71, pressure: 0, observations: [allowed], settings: settings, automatic: true)[0]
    check(!afterGap.eligible && afterGap.highSeconds == 0, "sleep / sampling gap resets evidence")
    let back = gap.ingest(now: 1700, temperature: 71, pressure: 0, observations: [allowed], settings: settings, automatic: true)[0]
    check(!back.eligible && back.highSeconds == 0, "backwards clock resets evidence")
    let reused = RuleEngine(); _ = feed(reused)
    changed = allowed; changed.process.startSec += 1
    let reuseResult = reused.ingest(now: 1210, temperature: 71, pressure: 0, observations: [changed], settings: settings, automatic: true)[0]
    check(!reuseResult.eligible && reuseResult.highSeconds == 0, "PID reuse cannot inherit elapsed CPU evidence")
    let dip = RuleEngine(); _ = feed(dip)
    changed = allowed; changed.cpu = 1
    _ = dip.ingest(now: 1210, temperature: 71, pressure: 0, observations: [changed], settings: settings, automatic: true)
    let dipResult = dip.ingest(now: 1220, temperature: 71, pressure: 0, observations: [allowed], settings: settings, automatic: true)[0]
    check(!dipResult.eligible, "discontinuous high CPU cannot be added together")
    let cool = RuleEngine(); _ = feed(cool)
    _ = cool.ingest(now: 1210, temperature: 60, pressure: 0, observations: [allowed], settings: settings, automatic: true)
    check(!cool.severe && cool.severeAge == 0, "cooling resets severe-temperature duration")
    let official = RuleEngine().ingest(now: 0, temperature: 95, pressure: 3, observations: [allowed], settings: settings, automatic: true)[0]
    check(!official.eligible, "critical OS pressure alone cannot authorize termination")
    let system = ProcessRecord(pid: 88, name: "kernel_task")
    check(Safety.hard(system, all: [:]) != nil, "kernel_task is protected independently of temperature")
    let compiler = ProcessRecord(pid: 90, name: "swift-frontend")
    let child = ProcessRecord(pid: 91, parent: 90)
    check(Safety.soft(child, all: [90: compiler, 91: child], frontPID: 500, settings: settings) != nil, "compiler protection propagates to descendants")
    check(Safety.soft(record, all: [record.pid: record], frontPID: record.pid, settings: settings) != nil, "frontmost process is protected")
    check(Safety.soft(record, all: [:], frontPID: nil, settings: settings) != nil, "unknown foreground identity fails closed")
    var whitelist = settings; whitelist.protectedPaths.insert(record.path)
    check(Safety.soft(record, all: [:], frontPID: 500, settings: whitelist) != nil, "exact executable allow-protection path is respected")
    let connector = ProcessRecord(name: "codexpro-server")
    check(Safety.hard(connector, all: [:]) != nil, "development connector is not an action target")
    let orphan = ProcessRecord(parent: 98765)
    check(Safety.soft(orphan, all: [:], frontPID: 500, settings: settings) != nil, "incomplete ancestry blocks automation")
    var cycle = record; cycle.parent = cycle.pid
    check(Safety.soft(cycle, all: [cycle.pid: cycle], frontPID: 500, settings: settings) != nil, "cyclic ancestry fails closed")
    let missing = RuleEngine(); _ = feed(missing)
    let noSensor = missing.ingest(now: 1210, temperature: nil, pressure: 3, observations: [allowed], settings: settings, automatic: true)[0]
    check(!noSensor.eligible && missing.severeAge == 0, "lost sensor invalidates an already-qualified candidate")
    let switched = RuleEngine(); _ = feed(switched)
    changed = allowed; changed.background = false
    _ = switched.ingest(now: 1210, temperature: 71, pressure: 0, observations: [changed], settings: settings, automatic: true)
    let backInBackground = switched.ingest(now: 1220, temperature: 71, pressure: 0, observations: [allowed], settings: settings, automatic: true)[0]
    check(!backInBackground.eligible && backInBackground.backgroundSeconds == 0, "foreground interaction resets continuous background time")
    print("\nRule / safety tests: \(passed) passed, \(failed) failed. No real processes signalled.")
    return failed == 0
}

func runSignalSelfTest() -> Bool {
    // Only this test's own newly spawned /bin/sleep child is ever targeted.
    let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]
    do { try child.run() } catch { print("FAIL spawn test child: \(error)"); return false }
    defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
    Thread.sleep(forTimeInterval: 0.1)
    var raw = QGProcess()
    guard qg_read_process(child.processIdentifier, &raw) == 1 else { print("FAIL read own test child"); return false }
    let p = ProcessRecord(raw)
    let stale = p.path.withCString { qg_signal_exact(p.pid, p.startSec + 1, p.startUsec, $0, SIGTERM) }
    guard stale == ESTALE && child.isRunning else { print("FAIL reject stale identity"); return false }
    let invalid = p.path.withCString { qg_signal_exact(p.pid, p.startSec, p.startUsec, $0, SIGSTOP) }
    guard invalid == EINVAL && child.isRunning else { print("FAIL reject unsupported signal"); return false }
    let own = p.path.withCString { qg_signal_exact(getpid(), p.startSec, p.startUsec, $0, SIGTERM) }
    guard own == EINVAL else { print("FAIL self-protection"); return false }
    let sent = p.path.withCString { qg_signal_exact(p.pid, p.startSec, p.startUsec, $0, SIGTERM) }
    guard sent == 0 else { print("FAIL signal test child: \(sent)"); return false }
    child.waitUntilExit()
    print("PASS  stale PID identity rejected; unsupported signal rejected; self protected; owned sleep child terminated.")
    print("No pre-existing user processes were targeted.")
    return true
}

func probeHardware() {
    let one = TelemetryPacket.read()
    Thread.sleep(forTimeInterval: 1)
    let two = TelemetryPacket.read()
    let usage = two.total > one.total && two.busy >= one.busy ? Double(two.busy - one.busy) / Double(two.total - one.total) * 100 : 0
    let obj: [String: Any] = ["version": "0.2.0", "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "logical_cpus": ProcessInfo.processInfo.processorCount, "memory_bytes": ProcessInfo.processInfo.physicalMemory,
        "temperature_max_c": two.temperature as Any? ?? NSNull(), "temperature_average_c": two.average as Any? ?? NSNull(),
        "valid_cpu_thermal_zones": two.sensorCount, "observed_processes": two.processes.count,
        "system_cpu_percent": usage, "thermal_state": ProcessInfo.processInfo.thermalState.rawValue,
        "default_mode": "observe", "cloud_requests": 0]
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
}
