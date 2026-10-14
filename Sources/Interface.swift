import SwiftUI
import Charts
import AppKit

private enum GuardArtwork {
    static func load(_ name: String) -> NSImage {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"), let image = NSImage(contentsOf: url) { return image }
        return NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "长安")!
    }
    static let mark = load("QuietGuardMark")
    static let menu: NSImage = {
        let image = load("QuietGuardMenu")
        image.size = NSSize(width: 18, height: 18); image.isTemplate = true
        return image
    }()
}

private let ink = Color(red: 0.045, green: 0.065, blue: 0.085)
private let panel = Color(red: 0.085, green: 0.11, blue: 0.14)
private let accent = Color(red: 0.40, green: 0.88, blue: 0.73)

enum GuardTab: String, CaseIterable {
    case overview = "总览", processes = "后台进程", rules = "保护与规则", events = "事件记录"
    var icon: String {
        switch self { case .overview: return "square.grid.2x2"; case .processes: return "waveform.path.ecg"; case .rules: return "shield.lefthalf.filled"; case .events: return "clock.arrow.circlepath" }
    }
}
struct QuietGuardApplication: App {
    @StateObject private var model = GuardModel()
    var body: some Scene {
        WindowGroup("长安 QuietGuard", id: "dashboard") {
            Dashboard(model: model).preferredColorScheme(.dark)
                .onAppear { captureOwnWindowIfRequested() }
        }
        .defaultSize(width: 1120, height: 790)
        .windowStyle(.hiddenTitleBar)
        .commands { CommandGroup(replacing: .newItem) {} }
        MenuBarExtra {
            QuickPanel(model: model).preferredColorScheme(.dark)
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: GuardArtwork.menu).renderingMode(.template)
                Text((model.temperature.map { String(format: "%.0f°", $0) } ?? "—") + (model.severe ? " !" : ""))
            }
        }.menuBarExtraStyle(.window)
    }
}
struct QuickPanel: View {
    @ObservedObject var model: GuardModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("长安 · QuietGuard", systemImage: "shield.checkered").font(.headline)
            Text(model.statusTitle).font(.title3.bold())
            HStack { Text("CPU 热区"); Spacer(); Text(model.temperature.map { String(format: "%.1f °C", $0) } ?? "不可用").monospacedDigit() }
            HStack { Text("整机 CPU"); Spacer(); Text(model.totalCPU.map { String(format: "%.1f %%", $0) } ?? "采样中").monospacedDigit() }
            Text(model.automatic ? "受控自动 · 仅限明确授权的实例" : "仅观察 · 不会自动结束后台").font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("打开守护面板") { openWindow(id: "dashboard"); NSApp.activate(ignoringOtherApps: true) }
            Button(model.settings.projectMode ? "关闭项目保护" : "开启项目保护（直到手动关闭）") { model.settings.projectMode.toggle() }
            if !model.pending.isEmpty { Text("\(model.pending.count) 个后台正在倒计时").foregroundStyle(.orange) }
            Button("取消全部自动处理") { model.cancelAll() }
            Divider()
            Button("退出长安") { NSApp.terminate(nil) }
        }.padding(20).frame(width: 300)
    }
}
struct Dashboard: View {
    @ObservedObject var model: GuardModel
    @State private var tab: GuardTab = .overview
    @State private var query = ""
    @State private var selectedID: String?
    private var shown: [Assessment] {
        let filtered = model.assessments.filter {
            query.isEmpty || ($0.observation.process.name + " " + $0.observation.process.path + " " + String($0.observation.process.pid)).localizedCaseInsensitiveContains(query)
        }
        return Array(filtered.prefix(250))
    }
    private var selected: Assessment? { model.assessments.first { $0.id == selectedID } }
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 20) {
                header
                HStack {
                    Label(model.storageStatus, systemImage: model.storageReady ? "externaldrive" : "externaldrive.badge.exclamationmark")
                        .font(.caption).foregroundStyle(model.storageReady ? accent : .orange)
                    Spacer()
                    Button("打开外接目录") { NSWorkspace.shared.open(GuardModel.dataDirectory.deletingLastPathComponent()) }.font(.caption)
                }
                if !model.pending.isEmpty { pendingBanner }
                switch tab {
                case .overview: overview
                case .processes: processes
                case .rules: rules
                case .events: events
                }
            }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(minWidth: 1000, minHeight: 730).background(ink).tint(accent)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(nsImage: GuardArtwork.mark).resizable().interpolation(.high).frame(width: 58, height: 58).padding(.top, 30)
            Text("长安").font(.system(size: 29, weight: .semibold))
            Text("QUIETGUARD").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(2.3).foregroundStyle(.secondary)
            Text("少打扰，多守护。").font(.caption).foregroundStyle(.secondary).padding(.top, 7).padding(.bottom, 25)
            ForEach(GuardTab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    Label(item.rawValue, systemImage: item.icon).font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 13).padding(.horizontal, 12)
                        .background(tab == item ? accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(tab == item ? accent : .secondary)
                }.buttonStyle(.plain)
            }
            Spacer()
            Label("完全本地运行", systemImage: "lock.shield").font(.caption).foregroundStyle(accent)
            Text("不清内存 · 不改风扇\n不上传进程数据").font(.caption).foregroundStyle(.secondary).lineSpacing(5).padding(.top, 5)
            Text("0.2.0  /  外接盘版").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).padding(.top, 16)
        }.padding(.horizontal, 20).padding(.bottom, 25).frame(width: 185).background(Color.white.opacity(0.025))
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(tab.rawValue).font(.system(size: 24, weight: .semibold))
                Text("保护电脑，也保护你正在完成的工作。").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.settings.projectMode.toggle(); model.appendLog(model.settings.projectMode ? "项目保护开启：全部自动处理暂停，直到手动关闭" : "项目保护已手动关闭") } label: {
                Label(model.settings.projectMode ? "项目保护中" : "保护当前项目", systemImage: "shield.checkered")
            }.buttonStyle(.bordered)
            Button(model.automatic ? "受控自动" : "仅观察") { model.toggleAutomatic() }.buttonStyle(.borderedProminent)
        }
    }
    private var pendingBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
            Text("\(model.pending.count) 个已授权后台待处理 · 最早 \(Int(max(0, (model.pendingSorted.first?.deadline ?? model.now) - model.now))) 秒后发送结束请求")
                .font(.caption)
            Spacer()
            Button("立即取消全部") { model.cancelAll() }.tint(.orange)
        }.padding(13).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(model.statusTitle, systemImage: model.warning || model.severe ? "exclamationmark.shield" : "checkmark.shield")
                            .font(.system(size: 21, weight: .medium)).foregroundStyle(model.warning || model.severe ? Color.orange : accent)
                        Text(model.automatic ? "只管理你授权的后台，其余任务保持原样。" : "先看清，再行动。当前不会自动结束任何后台。")
                            .foregroundStyle(.secondary).font(.subheadline)
                        Text(model.telemetryStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(model.temperature.map { String(format: "%.1f°", $0) } ?? "—")
                        .font(.system(size: 57, weight: .light, design: .rounded)).monospacedDigit().foregroundStyle(accent)
                }.padding(25).background(LinearGradient(colors: [accent.opacity(0.11), panel], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 17))
                HStack(spacing: 14) {
                    metric("整机 CPU", model.totalCPU.map { String(format: "%.1f%%", $0) } ?? "采样中", "整机 100% · \(ProcessInfo.processInfo.processorCount) 个逻辑核心", "cpu")
                    metric("系统热压力", model.pressureText, "macOS 官方热状态 · 不是寿命预测", "thermometer.medium")
                    metric("高于预警阈值", elapsedLabel(model.warningAge), "\(Int(model.settings.warningTemperature))°C / \(Int(model.settings.warningSeconds / 60)) 分钟提醒", "clock")
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("CPU 温度轨迹").font(.headline)
                        Spacer()
                        Text("最高热区 · 最近最多 30 分钟").font(.caption).foregroundStyle(.secondary)
                    }
                    Chart {
                        ForEach(Array(model.history.enumerated()), id: \.element.id) { index, point in
                            if let temperature = point.temperature {
                                LineMark(x: .value("采样", index), y: .value("温度", temperature)).foregroundStyle(accent).lineStyle(StrokeStyle(lineWidth: 2))
                            }
                        }
                        RuleMark(y: .value("预警", model.settings.warningTemperature)).foregroundStyle(.orange.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 5]))
                        RuleMark(y: .value("严重", model.settings.severeTemperature)).foregroundStyle(.red.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 5]))
                    }.chartYScale(domain: 0...120).chartXAxis(.hidden).frame(height: 145)
                    Text("阈值是你的偏好，不是硬件损伤界线。温度只用于预警，不直接指定被结束的进程。").font(.caption).foregroundStyle(.secondary)
                }.padding(20).background(panel, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 13) {
                    HStack { Text("当前高负载").font(.headline); Spacer(); Button("查看全部 →") { tab = .processes }.buttonStyle(.plain).foregroundStyle(accent) }
                    if model.assessments.isEmpty { Text("正在建立第一次进程快照…").foregroundStyle(.secondary) }
                    ForEach(Array(model.assessments.prefix(4))) { a in
                        HStack(spacing: 12) {
                            Image(systemName: a.observation.protection == nil ? "app.dashed" : "lock.shield").foregroundStyle(a.observation.protection == nil ? .secondary : accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(a.observation.process.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(a.reason).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(a.observation.cpu.map { String(format: "%.1f%%", $0) } ?? "—").font(.system(size: 13, design: .monospaced))
                        }
                    }
                    Text("进程 CPU：100% 表示用满一个逻辑核心，因此可超过 100%。").font(.caption2).foregroundStyle(.secondary)
                }.padding(20).background(panel, in: RoundedRectangle(cornerRadius: 14))
            }
        }.scrollIndicators(.hidden)
    }
    private func metric(_ title: String, _ value: String, _ detail: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 25, weight: .medium, design: .rounded)).monospacedDigit()
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(panel, in: RoundedRectangle(cornerRadius: 14))
    }
    private var processes: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("搜索进程名称、PID 或路径", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 370)
                Spacer()
                Text("显示 \(shown.count) / \(model.processCount) · 按 CPU 排序").font(.caption).foregroundStyle(.secondary)
            }
            Table(shown, selection: $selectedID) {
                TableColumn("进程 / PID") { a in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(a.observation.process.name).lineLimit(1)
                        Text(String(a.observation.process.pid)).font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 3)
                }.width(min: 150, ideal: 220)
                TableColumn("CPU") { a in Text(a.observation.cpu.map { String(format: "%.1f%%", $0) } ?? "—").monospacedDigit() }.width(70)
                TableColumn("内存") { a in Text(String(format: "%.0f MB", Double(a.observation.process.memory) / 1048576)).monospacedDigit() }.width(80)
                TableColumn("高 CPU 持续") { a in Text(elapsedLabel(a.highSeconds)).font(.caption) }.width(100)
                TableColumn("判定") { a in
                    Text(a.observation.protection != nil ? "受保护" : (a.level > 0 ? "需要关注" : "观察中"))
                        .foregroundStyle(a.observation.protection != nil ? accent : (a.level > 0 ? .orange : .secondary))
                }.width(85)
            }.frame(minHeight: 220)
            Group {
                if let a = selected {
                    let p = a.observation.process
                    VStack(alignment: .leading, spacing: 11) {
                        HStack { Text(p.name).font(.headline); Spacer(); Text("PID \(p.pid)").monospaced().foregroundStyle(.secondary) }
                        Text(p.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        Text(a.reason).font(.subheadline).foregroundStyle(a.level > 0 ? Color.orange : accent).fixedSize(horizontal: false, vertical: true)
                        Text("连续后台 \(elapsedLabel(a.backgroundSeconds)) · 连续低磁盘活动 \(elapsedLabel(a.quietSeconds)) · 历史平滑 CPU \(String(format: "%.1f%%", a.baseline))")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(model.settings.protectedPaths.contains(p.path) ? "移出保护名单" : "加入保护名单") { model.toggleProtection(p) }
                            Button(model.authorized.contains(p.id) ? "撤销本次授权" : "授权本次自动处理") { model.authorize(p) }
                            Spacer()
                            Button("发送结束请求") { model.manualEnd(p, force: false) }
                            Menu("更多") { Button("强制结束（可能丢失数据）", role: .destructive) { model.manualEnd(p, force: true) } }
                                .fixedSize()
                        }.controlSize(.small)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("选择一个进程，查看判定依据与操作", systemImage: "cursorarrow.click").font(.headline)
                        Text("不会按名称批量清理。手动操作会再次核验目标身份，并要求确认；系统关键进程始终拦截。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                }
            }.padding(20).background(panel, in: RoundedRectangle(cornerRadius: 14))
            Text("低磁盘活动不等于没有工作：编译、推理、渲染、录制与数据任务默认保守保护。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var rules: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("连续超温规则").font(.headline)
                    Stepper("预警温度：高于 \(Int(model.settings.warningTemperature)) °C", value: $model.settings.warningTemperature, in: 45...model.settings.severeTemperature, step: 1)
                    Stepper("预警持续：\(Int(model.settings.warningSeconds / 60)) 分钟", value: $model.settings.warningSeconds, in: 60...min(7200, model.settings.severeSeconds), step: 60)
                    Divider()
                    Stepper("严重温度：高于 \(Int(model.settings.severeTemperature)) °C", value: $model.settings.severeTemperature, in: model.settings.warningTemperature...100, step: 1)
                    Stepper("严重持续：\(Int(model.settings.severeSeconds / 60)) 分钟", value: $model.settings.severeSeconds, in: max(300, model.settings.warningSeconds)...14400, step: 60)
                    Stepper("进程高 CPU：至少 \(Int(model.settings.highCPUPercent))%（单核口径）", value: $model.settings.highCPUPercent, in: 20...800, step: 10)
                    Text("修改规则会重置连续计时。更高温度同样命中严重规则；保护名单永远优先，不会因更热而失效。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(22).background(panel, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 12) {
                    Text("自动处理必须同时满足").font(.headline)
                    Text("逐项授权当前实例 + 受控模式 + 温度/CPU/后台连续达标 + 至少 5 分钟低磁盘活动 + 无保护命中 + 60 秒撤销窗口。")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("每次最多结束一个实例，之后冷却 10 分钟；不反复追杀重启后的程序。SIGTERM 失败不会自动升级为 SIGKILL。")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("项目保护：暂停所有自动处理，直到手动关闭", isOn: $model.settings.projectMode)
                    Button("允许系统提醒通知") { model.requestNotifications() }
                }.padding(22).background(panel, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 13) {
                    Text("你的保护名单").font(.headline)
                    if model.settings.protectedPaths.isEmpty { Text("尚未添加自定义项。系统组件、常见开发工具及其子进程仍受内置保护。").foregroundStyle(.secondary).font(.subheadline) }
                    ForEach(model.settings.protectedPaths.sorted(), id: \.self) { path in
                        HStack { Text(path).font(.caption).textSelection(.enabled); Spacer(); Button("移除") { model.settings.protectedPaths.remove(path) } }
                    }
                    Text("在“后台进程”中选择程序即可加入。保护按完整可执行路径生效，并沿父子关系传递。").font(.caption).foregroundStyle(.secondary)
                }.padding(22).background(panel, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 10) {
                    Label("AI 状态：尚未接入模型", systemImage: "sparkles").font(.headline)
                    Text("当前运行可解释的本地规则与负载平滑统计，不把它包装成通用 AI。后续模型只提供分类和建议，不能越过保护规则、生成任意命令或自动修改自身。")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(22).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            }
        }.scrollIndicators(.hidden)
    }
    private var events: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Text("本机历史与本次会话的操作记录").foregroundStyle(.secondary); Spacer(); Button("导出诊断 JSON") { model.exportDiagnostics() } }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.logs) { item in
                        HStack(alignment: .top, spacing: 17) {
                            Text(item.time.formatted(date: .omitted, time: .standard)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
                            Text(item.message).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }.padding(.vertical, 15)
                        Divider().opacity(0.5)
                    }
                }.padding(20)
            }.background(panel, in: RoundedRectangle(cornerRadius: 14))
            Text("记录保存在外接盘 Data 目录，约 2 MB 上限。导出不会自动上传，不读取文档内容。").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private var didCapture = false
func captureOwnWindowIfRequested() {
    guard !didCapture, let position = CommandLine.arguments.firstIndex(of: "--capture-window"), CommandLine.arguments.count > position + 1 else { return }
    didCapture = true
    let path = CommandLine.arguments[position + 1]
    DispatchQueue.main.asyncAfter(deadline: .now() + 13) {
        guard let window = NSApp.windows.first(where: { $0.title.contains("QuietGuard") && $0.frame.width > 900 }),
              let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
    }
}
