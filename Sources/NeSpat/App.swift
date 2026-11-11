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
            // Системный кегль строки меню (menu font 14 pt) + табличные цифры, чтобы ширина не плясала.
            Text(model.menuTitle)
                .font(.system(size: 14, weight: .regular))
                .monospacedDigit()
                .frame(minWidth: 100, alignment: .leading)
        }
        // menuBarExtraAccess обязан идти сразу после MenuBarExtra.
        .menuBarExtraAccess(isPresented: $isMenuPresented) { item in
            // v2: сброс залипшей позиции под вырезом. Preferred Position — только если ещё нет
            // (иначе каждый запуск затирает ⌘-перетаскивание пользователя).
            let name = "local.nespat.statusItem.v2"
            let defaults = UserDefaults.standard
            let visibleKey = "NSStatusItem Visible \(name)"
            let visibleCCKey = "NSStatusItem VisibleCC \(name)"
            let positionKey = "NSStatusItem Preferred Position \(name)"
            defaults.set(true, forKey: visibleKey)
            defaults.set(true, forKey: visibleCCKey)
            if defaults.object(forKey: positionKey) == nil {
                defaults.set(220, forKey: positionKey)
            }
            item.autosaveName = NSStatusItem.AutosaveName(name)
            item.isVisible = true
            statusItem = item
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Панель (стиль системных меню macOS)

struct PanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            thinDivider
            durationBlock
            thinDivider
            metrics
            thinDivider
            settings
            thinDivider
            footer
        }
        .padding(.vertical, 8)
        .frame(width: 300)
        // Явно системный шрифт Apple (SF Pro) — чтобы кириллица не уходила в fallback.
        .font(.system(size: 13))
    }

    private var thinDivider: some View {
        Divider().padding(.horizontal, 14).padding(.vertical, 6)
    }

    // MARK: Шапка

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                Text("Не спать")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Toggle("", isOn: isOnBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(model.busy)
            }
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(statusColor)
                .fixedSize(horizontal: false, vertical: true)
            if model.status == .foreign {
                Button("Вернуть обычный сон") { model.forceRestoreSleep() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
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
                return "Включено · осталось \(Fmt.duration(remaining))"
            }
            return "Включено · подтверждено системой"
        case .off:
            return "Выключено · обычный сон"
        case .foreign:
            return "Сон выключен не этим приложением"
        case .unknown:
            return "Не удалось подтвердить состояние сна"
        }
    }

    /// Цвет статуса — системные насыщенные тона, в единой семантике со шкалами.
    private var statusColor: Color {
        switch model.status {
        case .on: .green
        case .off: .secondary
        case .foreign: .yellow
        case .unknown: .red
        }
    }

    // MARK: Длительность

    private var durationBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Длительность")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
    }

    // MARK: Метрики

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 9) {
            barRow(
                "Температура",
                model.sample.temperatureC.map { "\(Int($0.rounded())) °C" } ?? "—",
                fraction: temperatureFraction,
                fill: .load
            )
            barRow(
                "Процессор",
                model.sample.cpuPercent.map { Fmt.percent($0) } ?? "—",
                fraction: cpuFraction,
                fill: .load
            )
            barRow(
                "Память",
                "\(Fmt.gb(model.sample.memUsedBytes)) из \(Fmt.gb(model.sample.memTotalBytes))",
                fraction: memoryFraction,
                fill: .load
            )
            barRow(
                "Батарея",
                model.sample.batteryPercent.map { p in
                    let src = model.sample.charging == true ? "на зарядке" : "от батареи"
                    return "\(p)% · \(src)"
                } ?? "—",
                fraction: model.sample.batteryPercent.map { CGFloat($0) / 100 },
                fill: .battery(model.sample.batteryPercent ?? 100)
            )
            if let reason = model.lastReason {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.75))
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
    }

    /// Единая метрика: подпись + значение + тонкая шкала.
    /// Честная семантика: длина заливки = значение, цвет = состояние (зелёный/жёлтый/красный),
    /// как у системного индикатора батареи. Радуги по всей ширине больше нет.
    private func barRow(_ label: String, _ value: String, fraction: CGFloat?, fill: BarFill) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary)
            }
            if let fraction {
                let f = min(max(fraction, 0), 1)
                GeometryReader { geo in
                    let filled = max(4, geo.size.width * f)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.18))
                        switch fill {
                        case .load:
                            // Градация по всей дорожке, видна только занятая часть:
                            // длина = значение, цвет кончика = состояние.
                            Capsule()
                                .fill(loadGradient)
                                .frame(width: geo.size.width)
                                .mask(
                                    HStack(spacing: 0) {
                                        Rectangle().frame(width: filled)
                                        Spacer(minLength: 0)
                                    }
                                )
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(gloss)
                                        .frame(width: filled)
                                }
                        case .battery(let percent):
                            Capsule()
                                .fill(batteryColor(percent))
                                .frame(width: filled)
                                .overlay(Capsule().fill(gloss))
                        }
                    }
                }
                .frame(height: 5)
            }
        }
    }

    private enum BarFill {
        case load
        case battery(Int)
    }

    /// Насыщенный «светофор» нагрузки: зелёный → жёлтый → красный по всей дорожке.
    private var loadGradient: LinearGradient {
        LinearGradient(
            colors: [.green, .yellow, .red],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Батарея: сплошной цвет по уровню заряда (заряд, а не нагрузка).
    private func batteryColor(_ percent: Int) -> Color {
        if percent < 15 { return .red }
        if percent < 30 { return .yellow }
        return .green
    }

    /// 25…85 °C → 0…1: при обычной работе шкала наполнена, но не врёт (35° уже видно).
    private var temperatureFraction: CGFloat? {
        guard let t = model.sample.temperatureC else { return nil }
        return CGFloat(min(max((t - 25) / 60, 0), 1))
    }

    private var cpuFraction: CGFloat? {
        guard let c = model.sample.cpuPercent else { return nil }
        return CGFloat(min(max(c / 100, 0), 1))
    }

    private var memoryFraction: CGFloat? {
        guard model.sample.memTotalBytes > 0 else { return nil }
        return CGFloat(min(1, Double(sample.memUsedBytes) / Double(sample.memTotalBytes)))
    }

    private var sample: StatsSampler.Sample { model.sample }

    /// Глянцевый блик: светлая полоса сверху капсулы, к низу сходит на нет.
    private var gloss: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.32),
                Color.white.opacity(0.10),
                Color.white.opacity(0.02)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: Настройки

    private var settings: some View {
        HStack {
            Spacer()
            Button(action: { model.openActivityMonitor() }) {
                Label("Мониторинг системы", systemImage: "activity")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 14)
    }

    // MARK: Низ

    private var footer: some View {
        HStack(alignment: .center) {
            Toggle("Запускать при входе", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            .font(.system(size: 13))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .tint(.accentColor)

            Spacer(minLength: 8)

            Button("Выход") { model.quit() }
                .buttonStyle(.borderless)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 2)
    }
}
