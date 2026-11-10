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
        case none = "Без ограничения"
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

    // UI-состояние
    @Published var menuTitle = "…"
    @Published var status: Status = .unknown
    @Published var sample = StatsSampler.Sample()
    @Published var duration: Duration = .none
    @Published var remaining: TimeInterval?
    @Published var lastReason: String?
    @Published var busy = false

    let testTimerAvailable: Bool

    private let sampler = StatsSampler()
    private var timer: Timer?
    private var session = Session()
    private var lastLid: Bool?

    init(testTimer: Bool) {
        testTimerAvailable = testTimer
        session = SessionStore.load()
        adoptSessionOnLaunch()
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

        guard session.owned else {
            remaining = nil
            lastLid = lid
            updateMenuTitle()
            return
        }

        // Таймер
        if let until = session.until {
            remaining = until.timeIntervalSinceNow
            if until <= Date() {
                autoOff("таймер закончился")
                updateMenuTitle()
                return
            }
        } else {
            remaining = nil
        }

        // Автоотключения
        if let percent = sample.batteryPercent, sample.charging == false, percent < 15 {
            autoOff("заряд \(percent)%")
        } else if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            autoOff("перегрев (thermal state)")
        } else if let t = sample.temperatureC, t >= 95 {
            autoOff("температура \(Int(t))°")
        }

        // Крышка: погасить экран на переходе в «закрыта»
        if state == .disabled, lid == true, lastLid == false {
            SleepControl.displaysleepnow()
        }
        lastLid = lid

        updateMenuTitle()
    }

    private func updateMenuTitle() {
        let temp = sample.temperatureC.map { "\(Int($0.rounded()))°" } ?? "—"
        let cpu = sample.cpuPercent.map { Fmt.percent($0) } ?? "—"
        let memTotal = sample.memTotalBytes
        let mem: String
        if memTotal > 0 {
            mem = Fmt.percent(Double(sample.memUsedBytes) / Double(memTotal) * 100)
        } else {
            mem = "—"
        }
        let icon: String
        switch status {
        case .on: icon = "☕ "
        case .off, .foreign: icon = ""
        case .unknown: icon = "⚠ "
        }
        let title = "\(icon)\(temp.padding(toLength: 4, withPad: " ", startingAt: 0))\(cpu.padding(toLength: 4, withPad: " ", startingAt: 0))\(mem)"
        if title != menuTitle { menuTitle = title }
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
                SessionStore.save(session)
                if PowerInfo.lidClosed() == true { SleepControl.displaysleepnow() }
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
        session.owned = false
        session.until = nil
        if let reason { session.lastReason = reason }
        SessionStore.save(session)
        remaining = nil
    }
}
