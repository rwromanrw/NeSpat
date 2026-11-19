import AppKit
import Foundation
import SwiftUI

// MARK: - Модель приложения (главный поток, тик 5 с)

/// Весь доступ — из главного потока (Timer в главном RunLoop), поэтому @unchecked Sendable безопасно.
final class AppModel: ObservableObject, @unchecked Sendable {

    enum Status: Equatable {
        case on            // наша сессия, подтверждено
        case off           // обычный сон
        case foreign       // сон выключен не этим приложением
        case unknown       // не удалось подтвердить
    }

    enum Duration: String, CaseIterable, Identifiable {
        case none = "Без лимита"
        case h1 = "1 ч"
        case h3 = "3 ч"
        case h8 = "8 ч"
        case test = "2 мин (тест)"
        var id: String { rawValue }
        var seconds: TimeInterval? {
            switch self {
            case .none: nil
            case .h1: 3600
            case .h3: 10800
            case .h8: 28800
            case .test: 120
            }
        }
    }

    /// Если между тиками больше этого — считаем, что Mac успел поспать (тики не шли).
    private static let sleepGap: TimeInterval = 90

    // UI-состояние
    @Published var menuMetrics = "…"
    @Published var status: Status = .unknown
    @Published var sample = StatsSampler.Sample()
    @Published var duration: Duration = .none
    @Published var remaining: TimeInterval?
    @Published var lastReason: String?
    @Published var lastLidAwakeSeconds: TimeInterval?
    /// Сейчас идет замер под закрытой крышкой (живой счетчик).
    @Published var lidAwakeLive = false
    @Published var busy = false
    @Published var launchAtLogin = false

    let testTimerAvailable: Bool

    private let sampler = StatsSampler()
    private var timer: Timer?
    private var session = Session()
    private var lastLid: Bool?

    init(testTimer: Bool) {
        testTimerAvailable = testTimer
        session = SessionStore.load()
        adoptSessionOnLaunch()
        launchAtLogin = LoginItem.isEnabled
        lastLidAwakeSeconds = session.lastLidAwakeSeconds
        lastReason = session.lastReason
        tick()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    var durations: [Duration] {
        testTimerAvailable ? Duration.allCases : Duration.allCases.filter { $0 != .test }
    }

    /// Смена длительности во время активной сессии пересчитывает дедлайн.
    func setDuration(_ d: Duration) {
        duration = d
        guard session.owned else { return }
        session.until = d.seconds.map { Date().addingTimeInterval($0) }
        SessionStore.save(session)
        remaining = session.until?.timeIntervalSinceNow
    }

    // MARK: Тик

    func tick() {
        sample = sampler.sample()
        let state = PowerInfo.sleepState()
        let lid = PowerInfo.lidClosed()

        refreshSessionFromDisk()

        // Честный статус
        switch state {
        case .disabled:
            status = session.owned ? .on : .foreign
        case .enabled:
            status = .off
            if session.owned { endSession(reason: nil) }
        case .unknown:
            status = session.owned ? .unknown : .off
        }
        lastReason = session.lastReason
        lastLidAwakeSeconds = session.lastLidAwakeSeconds

        guard session.owned else {
            remaining = nil
            lastLid = lid
            updateMenuMetrics()
            return
        }

        // Таймер
        if let until = session.until {
            remaining = until.timeIntervalSinceNow
            if until <= Date() {
                autoOff("таймер закончился")
                updateMenuMetrics()
                return
            }
        } else {
            remaining = nil
        }

        // Автоотключения
        if let percent = sample.batteryPercent, sample.charging == false, percent < 15 {
            autoOff("заряд \(percent)%")
            updateMenuMetrics()
            return
        } else if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            autoOff("перегрев (thermal state)")
            updateMenuMetrics()
            return
        } else if let t = sample.temperatureC, t >= 95 {
            autoOff("температура \(Int(t))°")
            updateMenuMetrics()
            return
        }

        // Крышка: погасить экран + замер «сколько не спал под крышкой»
        trackLid(closed: lid, sleepDisabled: state == .disabled)

        updateMenuMetrics()
    }

    private func updateMenuMetrics() {
        let temp = sample.temperatureC.map { String(format: "%2d°", Int($0.rounded())) } ?? " —"
        let cpu = sample.cpuPercent.map { String(format: "%2d%%", Int($0.rounded())) } ?? " —"
        let mem: String
        if sample.memTotalBytes > 0 {
            let p = Int((Double(sample.memUsedBytes) / Double(sample.memTotalBytes) * 100).rounded())
            mem = String(format: "%2d%%", p)
        } else {
            mem = " —"
        }
        let title = "\(temp) \(cpu) \(mem)"
        if title != menuMetrics { menuMetrics = title }
    }

    // MARK: Крышка

    private func trackLid(closed: Bool?, sleepDisabled: Bool) {
        guard let closed else {
            lastLid = nil
            return
        }

        if closed {
            if lastLid == false || (lastLid == nil && session.lidClosedAt == nil) {
                // Только что закрыли (или старт с уже закрытой крышкой).
                beginLidAwake()
                if sleepDisabled {
                    SleepControl.displaysleepnow()
                }
            } else if session.lidClosedAt != nil {
                pulseLidHeartbeat()
            }
        } else if lastLid == true || session.lidClosedAt != nil {
            // Открыли крышку — фиксируем итог.
            finalizeLidAwake()
        }

        lastLid = closed
    }

    private func beginLidAwake() {
        // Новый цикл крышки: прошлый итог убираем только здесь, счетчик с нуля.
        let now = Date()
        session.lastLidAwakeSeconds = nil
        lastLidAwakeSeconds = nil
        lidAwakeLive = true
        session.lidClosedAt = now
        session.lidHeartbeatAt = now
        SessionStore.save(session)
    }

    private func pulseLidHeartbeat() {
        let now = Date()
        if let hb = session.lidHeartbeatAt, now.timeIntervalSince(hb) > Self.sleepGap {
            // Тики долго не шли — Mac, скорее всего, спал. Режем замер по последнему «жив».
            finalizeLidAwake()
            return
        }
        session.lidHeartbeatAt = now
        lidAwakeLive = true
        // Живой счетчик, пока крышка закрыта (если панель все же открыта).
        if let start = session.lidClosedAt {
            let seconds = max(0, now.timeIntervalSince(start))
            if seconds >= 5 {
                lastLidAwakeSeconds = seconds
            }
        }
        SessionStore.save(session)
    }

    private func finalizeLidAwake() {
        guard let start = session.lidClosedAt else { return }
        let end = session.lidHeartbeatAt ?? start
        let seconds = max(0, end.timeIntervalSince(start))
        // Короткие ложные срабатывания (< 5 с) не показываем.
        if seconds >= 5 {
            session.lastLidAwakeSeconds = seconds
            lastLidAwakeSeconds = seconds
        } else if !lidAwakeLive {
            // не трогаем уже сохраненный «прошлый раз»
        } else {
            // Был короткий ложный цикл — прошлый итог уже сбросили в begin; оставляем пусто.
            session.lastLidAwakeSeconds = nil
            lastLidAwakeSeconds = nil
        }
        session.lidClosedAt = nil
        session.lidHeartbeatAt = nil
        lidAwakeLive = false
        SessionStore.save(session)
    }

    // MARK: Действия пользователя

    func toggle(_ on: Bool) {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if on {
            let outcome = SleepControl.setSleepDisabled(true)
            switch outcome {
            case .confirmed:
                session.owned = true
                session.pid = getpid()
                session.until = duration.seconds.map { Date().addingTimeInterval($0) }
                session.lastReason = nil
                // «Прошлый раз под крышкой» не трогаем — сброс только при следующем закрытии крышки.
                SessionStore.save(session)
                if PowerInfo.lidClosed() == true {
                    beginLidAwake()
                    SleepControl.displaysleepnow()
                    lastLid = true
                }
            case .notConfirmed, .canceled:
                session.owned = false
                SessionStore.save(session)
            }
        } else {
            // Выключаем: нашу сессию всегда; чужой флаг — только явной кнопкой
            let outcome = SleepControl.setSleepDisabled(false)
            if outcome == .confirmed || outcome == .notConfirmed {
                endSession(reason: nil)
            }
        }
        tick()
    }

    /// Явно вернуть обычный сон (в том числе чужой флаг).
    func forceRestoreSleep() {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        SleepControl.setSleepDisabled(false)
        endSession(reason: nil)
        tick()
    }

    func setLaunchAtLogin(_ on: Bool) {
        if LoginItem.setEnabled(on) {
            launchAtLogin = on
        } else {
            launchAtLogin = LoginItem.isEnabled
        }
    }

    /// Открыть системный «Мониторинг системы» (Activity Monitor).
    func openActivityMonitor() {
        let candidates = [
            "/System/Applications/Utilities/Activity Monitor.app",
            "/Applications/Utilities/Activity Monitor.app"
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
    }

    func quit() {
        if session.owned {
            SleepControl.setSleepDisabled(false)
            endSession(reason: nil)
        }
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    // MARK: Внутреннее

    private func adoptSessionOnLaunch() {
        guard session.owned else { return }
        if session.pid != getpid(), SessionStore.ownerAlive(session) {
            // Живой другой экземпляр владеет сессией: диск не трогаем, мы не владелец.
            session.owned = false
            session.until = nil
            return
        }
        // Перезапуск того же приложения: сессия остаётся нашей.
        session.pid = getpid()
        SessionStore.save(session)
    }

    private func refreshSessionFromDisk() {
        let disk = SessionStore.load()
        if disk.owned, disk.pid != getpid(), SessionStore.ownerAlive(disk) {
            // Сессией владеет другой живой экземпляр: мы наблюдатель, диск не переписываем.
            session.owned = false
            session.until = nil
            session.lastReason = disk.lastReason
            session.lastLidAwakeSeconds = disk.lastLidAwakeSeconds
            return
        }
        session = disk
    }

    private func autoOff(_ reason: String) {
        let outcome = SleepControl.setSleepDisabled(false)
        if outcome == .confirmed || outcome == .notConfirmed {
            endSession(reason: "Сон возвращён: \(reason)")
        }
    }

    private func endSession(reason: String?) {
        // Если крышка была закрыта — фиксируем итог. Надпись «прошлый раз» не стираем:
        // она живет до следующего закрытия крышки (даже после таймера / выключения режима).
        finalizeLidAwake()
        session.owned = false
        session.until = nil
        if let reason { session.lastReason = reason }
        SessionStore.save(session)
        remaining = nil
        lastReason = session.lastReason
        lastLidAwakeSeconds = session.lastLidAwakeSeconds
        lidAwakeLive = false
    }
}
