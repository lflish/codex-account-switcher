import AppKit
import SwiftUI
import SwitcherCore

/// The application uses one native popover for accounts and token usage.
struct CompactSwitcherPanel: View {
    @ObservedObject var model: AppModel
    @StateObject private var stats: UsageStatsModel
    @ObservedObject var quota: AccountQuotaModel
    let closePanel: () -> Void
    @State private var range = 7
    @State private var settingsExpanded = false

    init(model: AppModel, quota: AccountQuotaModel, closePanel: @escaping () -> Void) {
        self.model = model
        self.closePanel = closePanel
        _stats = StateObject(wrappedValue: UsageStatsModel(
            store: model.usageStatsStore, accounts: model.accounts, language: model.settings.language
        ))
        self.quota = quota
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Codex 账号").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    if stats.isLoading || quota.isLoading { ProgressView().controlSize(.small) }
                    Button {
                        Task { await refreshUsage() }
                    } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("刷新用量与剩余额度")
                    .accessibilityLabel("刷新用量与剩余额度")
                    .disabled(stats.isLoading || quota.isLoading)
                }

                Picker("统计周期", selection: $range) {
                    Text("昨日").tag(0)
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                }
                .pickerStyle(.segmented)
                .onChange(of: range) { _, value in
                    stats.dateRange = value == 0 ? .yesterday : .lastDays(value)
                    Task { await stats.loadCached() }
                }

                summary

                VStack(spacing: 6) {
                    ForEach(model.accounts) { account in accountRow(account) }
                }

                if let error = model.visibleError {
                    Text(error.messageKey.map(model.text) ?? error.message)
                        .font(.caption).foregroundStyle(.orange)
                }
                if let error = stats.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }

                Divider()
                DisclosureGroup("账号与设置", isExpanded: $settingsExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(model.text("launch_at_login"), isOn: Binding(
                            get: { model.launchesAtLogin }, set: { model.setLaunchAtLogin($0) }
                        ))
                        if model.launchAtLoginRequiresApproval || model.launchAtLoginUnavailable {
                            Text(model.text(model.launchAtLoginRequiresApproval
                                ? "launch_at_login_requires_approval" : "launch_at_login_unavailable"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button(model.text(model.isAddingAccount ? "cancel_add_account" : "add_account")) {
                                if model.isAddingAccount { model.cancelAddingAccount() }
                                else { model.addAccount() }
                            }
                            .disabled(model.isMutating && !model.isAddingAccount)
                            Button("登记当前账号") { Task { await model.registerCurrentAccount() } }
                                .disabled(model.isMutating)
                        }
                        .disabled(stats.isLoading)
                    }
                    .padding(.top, 10)
                }
                .font(.system(size: 12))

                HStack {
                    Text("北京时间 · Token 用量").foregroundStyle(.secondary)
                    Spacer()
                    Button(model.text("quit")) { NSApp.terminate(nil) }.buttonStyle(.borderless)
                }
                .font(.system(size: 10))
            }
            .padding(16)
        }
        .frame(width: 400, height: 680)
        .task {
            stats.accounts = model.accounts
            await stats.loadCached()
            await stats.refresh()
        }
        .onChange(of: model.accounts) { _, accounts in
            stats.accounts = accounts
            Task { await stats.refresh() }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("全部账号 · 所选周期已用 Token").font(.system(size: 11)).foregroundStyle(.secondary)
            if let overview = stats.overview, !overview.dailySeries.isEmpty {
                let reportedCount = overview.accountBreakdown.filter { $0.coverageStart != nil }.count
                Text(TokenCountFormatter.compact(overview.totalTokens))
                    .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    .help("\(TokenCountFormatter.exact(overview.totalTokens)) Token")
                Text("已上报 \(overview.dailySeries.count) 天 · \(reportedCount)/\(overview.totalAccountCount) 个账号有上报")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if stats.syncStatuses.values.contains(where: { if case .stale = $0 { true } else { false } }) {
                    Text("含缓存数据 · 部分账号刷新失败").font(.caption).foregroundStyle(.orange)
                }
                if overview.isPartial || reportedCount < overview.totalAccountCount {
                    Text("部分账号暂无可用数据").font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text(stats.isLoading ? "正在读取…" : "暂无上报")
                    .font(.system(size: 24, weight: .semibold))
                Text("只汇总已上报的日期").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private func accountRow(_ account: AccountProfile) -> some View {
        let active = account.id == model.activeAccountID
        let entry = stats.overview?.accountBreakdown.first { $0.accountID == account.accountID }
        let email = account.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = email.isEmpty ? account.displayName : email
        let subscriptionHelp = model.subscriptionSnapshots[account.id].map {
            "订阅至 \($0.activeUntil.formatted(.dateTime.year().month().day()))（登录快照，非实时账单查询）"
        } ?? "暂无订阅到期日快照"
        return VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 10) {
            Image(systemName: active ? "checkmark.circle.fill" : "person.crop.circle")
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(title + "\n" + subscriptionHelp)
                HStack(spacing: 6) {
                    if active {
                        Text("当前").font(.system(size: 9)).foregroundStyle(.secondary)
                    } else {
                        Button("切换") { confirmSwitch(to: account) }
                            .font(.system(size: 10))
                            .buttonStyle(.link)
                            .disabled(model.isMutating || model.isAddingAccount)
                            .accessibilityLabel("切换到 \(account.displayName)")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                Text(entry?.coverageStart == nil ? "暂无上报" : TokenCountFormatter.compact(entry!.totalTokens))
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .help(entry?.coverageStart == nil ? "暂无上报" : "\(TokenCountFormatter.exact(entry!.totalTokens)) Token")
                Text("所选周期已用 · Token").font(.system(size: 9)).foregroundStyle(.secondary)
                if let status = account.accountID.flatMap({ stats.syncStatuses[$0] }),
                   let message = statusMessage(status) {
                    Text(message).font(.system(size: 9)).foregroundStyle(.orange)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
          }
          // Only advances the display clock; it never requests quota data.
          TimelineView(.periodic(from: .now, by: 30)) { context in
              quotaSummary(account, now: context.date)
          }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(active ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private func confirmSwitch(to account: AccountProfile) {
        guard !model.isMutating, !model.isAddingAccount else { return }
        let email = account.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target = email.isEmpty ? account.displayName : "\(email)（\(account.displayName)）"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "切换 Codex 账号？"
        alert.informativeText = "目标：\(target)\n\n将重启 Codex 桌面端，请先处理正在运行的任务。无法正常退出时将停止切换。"
        alert.addButton(withTitle: "取消").keyEquivalent = "\r"
        alert.addButton(withTitle: "切换并重启").keyEquivalent = ""
        closePanel()
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Task { await model.switchAccount(to: account.id) }
    }

    private func refreshUsage() async {
        async let tokens: Void = stats.refresh()
        async let limits: Void = quota.refresh(accounts: model.accounts)
        _ = await (tokens, limits)
    }

    private func quotaSummary(_ account: AccountProfile, now: Date) -> some View {
        let state = quota.states[account.id]
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 16) {
                quotaWindow("5 小时剩余", resetTitle: "5h重置", window: state?.snapshot?.fiveHour, state: state, now: now)
                quotaWindow("每周剩余", resetTitle: "周重置", window: state?.snapshot?.weekly, state: state, now: now)
            }
            resetCreditsSummary(state, now: now)
            if let failure = state?.failure {
                Text(quotaFailureMessage(failure))
                    .font(.system(size: 9)).foregroundStyle(.orange)
            }
            if let snapshot = state?.snapshot {
                Text("\(state?.failure == nil ? "更新于" : "缓存于") \(quotaDate(snapshot.fetchedAt))")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    private func resetCreditsSummary(_ state: AccountQuotaState?, now: Date) -> some View {
        let details = state?.resetCredits
        let quotaSnapshot = state?.snapshot
        let useDetails = details != nil && (quotaSnapshot?.resetCreditsRemaining == nil
            || details!.fetchedAt >= quotaSnapshot!.fetchedAt)
        let count = useDetails ? details?.availableCount : quotaSnapshot?.resetCreditsRemaining
        let countTime = (useDetails ? details?.fetchedAt : quotaSnapshot?.fetchedAt) ?? .distantPast
        let eligibleCards = details?.credits.filter {
            $0.status == "available" && $0.resetType == "codexRateLimits"
        } ?? []
        let expiredSinceCount = eligibleCards.contains {
            guard let expiry = $0.expiresAt else { return false }
            return expiry <= now && expiry > countTime
        }
        let currentCards = eligibleCards.filter { $0.expiresAt.map { $0 > now } ?? true }
        let dates = currentCards.compactMap(\.expiresAt).sorted()
        let countText = expiredSinceCount ? "待刷新" : count.map { "\($0)张" }
            ?? (quota.isLoading ? "读取中" : "暂无数据")
        let tooltip = currentCards.enumerated().map { index, card in
            "第\(index + 1)张：\(card.expiresAt.map(quotaDate) ?? "未提供到期日")"
        }.joined(separator: "\n")
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("重置卡 \(countText)").font(.system(size: 10))
                Spacer()
                if count != 0, let earliest = dates.first {
                    Text("\(state?.resetCreditsFailure == nil ? "已知最早到期" : "缓存已知最早到期") \(quotaDate(earliest))")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                } else if count != nil && count != 0 {
                    Text(!currentCards.isEmpty && dates.isEmpty ? "未提供到期日"
                         : (quota.isLoading ? "到期信息读取中" : "到期信息暂无数据"))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .help(tooltip)
            if let error = state?.resetCreditsFailure {
                Text(quotaFailureMessage(error).replacingOccurrences(of: "额度", with: "重置卡详情"))
                    .font(.system(size: 9)).foregroundStyle(.orange)
                if let details {
                    Text("卡详情缓存于 \(quotaDate(details.fetchedAt))")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func quotaWindow(_ title: String, resetTitle: String, window: QuotaWindowSnapshot?, state: AccountQuotaState?, now: Date) -> some View {
        let hasExpired = window?.resetsAt.map { $0 <= now } ?? false
        let value = window.map { hasExpired ? "待更新" : "\($0.remainingPercent)%" }
            ?? (quota.isLoading && state?.snapshot == nil ? "读取中" : "暂无数据")
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(title).foregroundStyle(.secondary)
                Text(value).fontWeight(.medium)
            }
            .font(.system(size: 10))
            if let window, !hasExpired {
                ProgressView(value: Double(window.remainingPercent), total: 100)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .tint(window.remainingPercent == 0 ? Color.clear
                          : state?.failure != nil ? Color.secondary
                          : window.remainingPercent < 10 ? .red
                          : window.remainingPercent < 50 ? .yellow : .accentColor)
                    .frame(height: 4)
                    .accessibilityLabel(title)
                    .accessibilityValue("\(window.remainingPercent)%")
            }
            if let resetsAt = window?.resetsAt {
                Text("\(hasExpired ? "上期重置" : resetTitle) \(quotaDate(resetsAt))")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .help(fullQuotaDate(resetsAt))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fullQuotaDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy年MM月dd日 HH:mm"
        return formatter.string(from: date) + " 北京时间"
    }

    private func quotaDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM月dd日 HH:mm"
        return formatter.string(from: date)
    }

    private func quotaFailureMessage(_ error: QuotaReadError) -> String {
        switch error {
        case .authExpired, .identityUnavailable: "额度读取需要更新登录"
        case .forbidden: "额度访问受限，可能需要更新登录"
        case .rateLimited: "额度请求过于频繁，请稍后重试"
        default: "额度刷新失败"
        }
    }

    private func statusMessage(_ status: AccountSyncStatus) -> String? {
        switch status {
        case .synced: nil
        case .stale: "缓存 · 刷新失败"
        case .authExpired: "登录已过期"
        case .unavailable: "暂不可用"
        case .neverSynced: "尚未同步"
        }
    }
}
