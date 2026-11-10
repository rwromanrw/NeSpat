import AppKit
import MenuBarExtraAccess
import SwiftUI

// MARK: - Приложение в строке меню

struct NeSpatApp: App {
    @StateObject private var model: AppModel
    @State private var isMenuPresented = false
    @State private var statusItem: NSStatusItem?

    init() {
        let testTimer = CommandLine.arguments.contains("--test-timer")
        _model = StateObject(wrappedValue: AppModel(testTimer: testTimer))
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            // Фиксированная ширина + моноширинные цифры: пункт не «пляшет».
            Text(model.menuTitle)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(minWidth: 108, alignment: .leading)
        }
        // menuBarExtraAccess обязан идти сразу после MenuBarExtra, до других scene-модификаторов.
        .menuBarExtraAccess(isPresented: $isMenuPresented) { item in
            // Запоминает позицию между перезапусками (после ⌘+перетаскивания).
            item.autosaveName = NSStatusItem.AutosaveName("local.nespat.statusItem")
            statusItem = item
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Панель по клику

struct PanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            durationPicker
            metrics
            Divider()
            settings
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: Шапка

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Не спать")
                    .font(.title2.bold())
                Spacer()
                Toggle("", isOn: isOnBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.large)
                    .disabled(model.busy)
            }
            Text(statusText)
                .font(.callout)
                .foregroundStyle(statusColor)
            if model.status == .foreign {
                Button("Вернуть обычный сон") { model.forceRestoreSleep() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var isOnBinding: Binding<Bool> {
        Binding(
            get: { model.status == .on },
            set: { model.toggle($0) }
        )
    }

    private var statusText: String {
        switch model.status {
        case .on:
            if let remaining = model.remaining {
                return "Включено. Осталось: \(Fmt.duration(remaining))"
            }
            return "Включено — подтверждено системой"
        case .off:
            return "Выключено — обычный сон"
        case .foreign:
            return "Сон выключен не этим приложением"
        case .unknown:
            return "⚠ Не удалось подтвердить состояние сна"
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .on: .green
        case .off: .secondary
        case .foreign: .orange
        case .unknown: .red
        }
    }

    // MARK: Длительность

    private var durationPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Длительность").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { model.duration },
                set: { model.setDuration($0) }
            )) {
                ForEach(model.durations) { d in
                    Text(d.rawValue).tag(d)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: Метрики

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 8) {
            metricRow("Температура чипа", model.sample.temperatureC.map { "\(Int($0.rounded())) °C" } ?? "—")
            metricRow("Процессор", model.sample.cpuPercent.map { Fmt.percent($0) } ?? "—")
            memoryRow
            metricRow(
                "Батарея",
                model.sample.batteryPercent.map { p in
                    let src = model.sample.charging == true ? "на зарядке" : "от батареи"
                    return "\(p)% · \(src)"
                } ?? "—"
            )
            if let reason = model.lastReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }

    private var memoryRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Память").foregroundStyle(.secondary)
                Spacer()
                Text("\(Fmt.gb(model.sample.memUsedBytes)) из \(Fmt.gb(model.sample.memTotalBytes))")
                    .monospacedDigit()
            }
            .font(.callout)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(memoryColor)
                        .frame(width: geo.size.width * memoryFraction)
                }
            }
            .frame(height: 6)
        }
    }

    private var memoryFraction: CGFloat {
        guard model.sample.memTotalBytes > 0 else { return 0 }
        return CGFloat(min(1, Double(model.sample.memUsedBytes) / Double(model.sample.memTotalBytes)))
    }

    private var memoryColor: Color {
        if memoryFraction < 0.7 { return .green }
        if memoryFraction < 0.9 { return .yellow }
        return .red
    }

    // MARK: Настройки

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Запускать при входе", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            Button("Показать в Программах") { model.revealInFinder() }
                .buttonStyle(.bordered)
        }
    }

    // MARK: Низ

    private var footer: some View {
        HStack {
            Spacer()
            Button("Выход") { model.quit() }
                .keyboardShortcut("q")
        }
    }
}
