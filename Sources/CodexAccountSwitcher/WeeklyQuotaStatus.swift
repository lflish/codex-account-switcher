import AppKit
import Foundation
import SwitcherCore

/// Display-only projection of the active account's existing cache.
struct WeeklyQuotaStatus {
    let remainingPercent: Int?
    let tooltip: String
    let isCached: Bool

    init(accounts: [AccountProfile], activeID: UUID?, identityConfirmed: Bool,
         states: [UUID: AccountQuotaState], now: Date) {
        guard identityConfirmed, let account = accounts.first(where: { $0.id == activeID }) else {
            remainingPercent = nil
            isCached = false
            tooltip = "Codex · 每周剩余：—\n当前账号尚未确认"
            return
        }
        let email = account.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = email.isEmpty ? account.displayName : "\(email)（\(account.displayName)）"
        let state = states[account.id]
        isCached = state?.failure != nil && state?.snapshot != nil
        let window = state?.snapshot?.weekly
        let expired = window?.resetsAt.map { $0 <= now } ?? false
        remainingPercent = expired ? nil : window?.remainingPercent
        var lines = [title, "每周剩余：\(remainingPercent.map { "\($0)%" } ?? "—")"]
        if expired { lines.append("上期额度已过期，待刷新") }
        else if window == nil { lines.append("暂无每周额度数据") }
        if state?.failure != nil { lines.append("缓存 · 额度刷新失败") }
        if let date = state?.snapshot?.fetchedAt { lines.append("更新于 \(Self.date(date))") }
        if let date = window?.resetsAt { lines.append("周重置 \(Self.date(date))") }
        tooltip = lines.joined(separator: "\n")
    }

    private static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM月dd日 HH:mm"
        return formatter.string(from: date) + " 北京时间"
    }
}

enum WeeklyQuotaTone: Equatable {
    case neutral, warning, critical

    static func tone(for remainingPercent: Int?) -> Self {
        guard let remainingPercent else { return .neutral }
        if remainingPercent < 10 { return .critical }
        if remainingPercent < 50 { return .warning }
        return .neutral
    }
}

/// Colored content stays inside the original native button, including its alternate image.
@MainActor
enum WeeklyQuotaStatusImage {
    static func image(remainingPercent: Int?, logo: NSImage, isCached: Bool = false,
                      appearance: NSAppearance, highlighted: Bool = false) -> NSImage {
        var ink = NSColor.labelColor
        var fill = NSColor.labelColor
        var zeroInk = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            let foreground: NSColor = highlighted ? .selectedMenuItemTextColor : .labelColor
            ink = (isCached ? foreground.withAlphaComponent(0.5) : foreground).usingColorSpace(.deviceRGB)!
            let color: NSColor = switch WeeklyQuotaTone.tone(for: remainingPercent) {
            case .neutral: foreground
            case .warning: .systemYellow
            case .critical: .systemRed
            }
            fill = (isCached ? foreground.withAlphaComponent(0.5) : color).usingColorSpace(.deviceRGB)!
            zeroInk = (isCached ? ink : NSColor.systemRed).usingColorSpace(.deviceRGB)!
        }
        let textColor = remainingPercent == 0 && !highlighted ? zeroInk : ink
        // Explicit alpha tint is needed because the outer image is not a template.
        let tintedLogo = NSImage(size: NSSize(width: 16, height: 16))
        tintedLogo.lockFocus()
        logo.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16),
                  from: .zero, operation: .sourceOver, fraction: 1)
        ink.setFill()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill(using: .sourceIn)
        tintedLogo.unlockFocus()
        let image = NSImage(size: NSSize(width: 91, height: 20), flipped: false) { _ in
            tintedLogo.draw(in: NSRect(x: 0, y: 2, width: 16, height: 16))
            let track = NSRect(x: 21, y: 7, width: 30, height: 6)
            ink.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
            if let value = remainingPercent, value > 0 {
                fill.setFill()
                NSBezierPath(roundedRect: NSRect(x: 21, y: 7,
                    width: 30 * CGFloat(min(100, max(0, value))) / 100, height: 6),
                    xRadius: 3, yRadius: 3).fill()
            }
            let text = remainingPercent.map { "\($0)%" } ?? "—"
            (text as NSString).draw(at: NSPoint(x: 57, y: 3), withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: textColor
            ])
            return true
        }
        image.isTemplate = false
        return image
    }
}
