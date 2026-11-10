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
            // SF Pro; моноширинные цифры, чтобы ширина пункта меньше «плясала».
            Text(model.menuTitle)
                .font(.system(size: 13, weight: .regular))
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
    }

    private var thinDivider: some View {
        Divider().padding(.horizontal, 14).padding(.vertical, 6)
    }

    // MARK: Шапка

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                Text("Не спать")
                    .font(.headline)
                Spacer(minLength: 8)
                Toggle("", isOn: isOnBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(model.busy)
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.status == .foreign {
                Button("Вернуть обычный сон") { model.forceRestoreSleep() }
                    .buttonStyle(.borderless)
                    .font(.caption)
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

    // MARK: Длительность

    private var durationBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Длительность")
                .font(.caption)
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
        VStack(alignment: .leading, spacing: 7) {
            metricRow("Температура", model.sample.temperatureC.map { "\(Int($0.rounded())) °C" } ?? "—")
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
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.primary)
        }
    }

    private var memoryRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Память")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(Fmt.gb(model.sample.memUsedBytes)) из \(Fmt.gb(model.sample.memTotalBytes))")
                    .font(.callout.monospacedDigit())
            }
            // Тонкая пастельная шкала: градиент на всю ширину, видна только занятая часть
            // (при низкой загрузке — зелёный край, при высокой — доходит до красного).
            GeometryReader { geo in
                let filled = max(4, geo.size.width * memoryFraction)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(pastelMemoryGradient)
                        .frame(width: geo.size.width)
                        .mask(
                            HStack(spacing: 0) {
                                Rectangle().frame(width: filled)
                                Spacer(minLength: 0)
                            }
                        )
                }
            }
            .frame(height: 4)
        }
    }

    private var memoryFraction: CGFloat {
        guard model.sample.memTotalBytes > 0 else { return 0 }
        return CGFloat(min(1, Double(sample.memUsedBytes) / Double(sample.memTotalBytes)))
    }

    private var sample: StatsSampler.Sample { model.sample }

    /// Пастельный «светофор» (+25% насыщенности к исходным мягким тонам).
    private var pastelMemoryGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.60, green: 0.85, blue: 0.67), // зелёный
                Color(red: 0.97, green: 0.88, blue: 0.49), // жёлтый
                Color(red: 0.96, green: 0.66, blue: 0.64)  // красный
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: Настройки

    private var settings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Запускать при входе", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            .font(.callout)
            .toggleStyle(.checkbox)
            .controlSize(.small)

            Button("Показать в Программах") { model.revealInFinder() }
                .buttonStyle(.borderless)
                .font(.callout)
        }
        .padding(.horizontal, 14)
    }

    // MARK: Низ

    private var footer: some View {
        HStack {
            Spacer()
            Button("Выход") { model.quit() }
                .buttonStyle(.borderless)
                .font(.callout)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 2)
    }
}
