import SwitcherCore
import SwiftUI

#if os(macOS)

struct UsageStatsView: View {
    @ObservedObject var model: UsageStatsModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(model.text("usage_stats"))
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Button(model.text("usage_stats_refresh")) {
                    Task { await model.refresh() }
                }
                .buttonStyle(.bordered)
                .disabled(model.isLoading)

                Button(model.text("usage_stats_export")) {
                    Task { await model.exportCSV() }
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            // Filters
            filterBar
                .padding(.horizontal)
                .padding(.vertical, 8)

            Divider()

            if model.isLoading && model.overview == nil {
                Spacer()
                ProgressView(model.text("usage_stats_loading"))
                    .padding()
                Spacer()
            } else if let overview = model.overview {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        metricsCards(overview)
                        dailyChart(overview)
                        if model.singleOverview != nil {
                            singleAccountSummary
                        }
                        if overview.accountBreakdown.count > 1 {
                            accountRanking(overview)
                        }
                        dailyDetail(overview)
                        statusBar(overview)
                    }
                    .padding()
                }
            } else if let error = model.errorMessage {
                Spacer()
                Text(error).foregroundStyle(.red).padding()
                Spacer()
            } else {
                Spacer()
                Text(model.text("usage_stats_no_data"))
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .task {
            await model.loadCached()
            await model.refresh()
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            // Account picker
            Picker(model.text("usage_stats_all_accounts"), selection: $model.selectedAccountID) {
                Text(model.text("usage_stats_all_accounts")).tag(nil as String?)
                ForEach(model.accounts) { account in
                    Text(account.displayName).tag(account.accountID as String?)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 180)
            .onChange(of: model.selectedAccountID) { _, _ in
                Task { await model.loadCached() }
            }

            // Range picker
            Picker(model.text("usage_stats_last_7d"), selection: Binding(
                get: { rangeTag },
                set: { newTag in
                    switch newTag {
                    case 0: model.dateRange = .today
                    case 7: model.dateRange = .lastDays(7)
                    case 30: model.dateRange = .lastDays(30)
                    default: model.dateRange = .custom(startLabel: "", endLabel: "")
                    }
                    Task { await model.loadCached() }
                }
            )) {
                Text(model.text("usage_stats_today")).tag(0)
                Text(model.text("usage_stats_last_7d")).tag(7)
                Text(model.text("usage_stats_last_30d")).tag(30)
                Text(model.text("usage_stats_custom")).tag(-1)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)

            if case .custom = model.dateRange {
                DatePicker("", selection: $model.customStart, displayedComponents: .date)
                    .labelsHidden()
                    .frame(width: 110)
                DatePicker("", selection: $model.customEnd, displayedComponents: .date)
                    .labelsHidden()
                    .frame(width: 110)
            }

            Spacer()

            // Timezone picker
            HStack(spacing: 4) {
                Text(model.text("usage_stats_timezone"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Picker("", selection: $model.timeZoneIdentifier) {
                    Text("Asia/Shanghai").tag("Asia/Shanghai")
                    Text("UTC").tag("UTC")
                    Text("America/New_York").tag("America/New_York")
                    Text("America/Los_Angeles").tag("America/Los_Angeles")
                    Text("Europe/London").tag("Europe/London")
                    Text("Asia/Tokyo").tag("Asia/Tokyo")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 160)
                .onChange(of: model.timeZoneIdentifier) { _, _ in
                    Task { await model.loadCached() }
                }
            }
        }
    }

    private var rangeTag: Int {
        switch model.dateRange {
        case .today: return 0
        case .lastDays(7): return 7
        case .lastDays(30): return 30
        default: return -1
        }
    }

    // MARK: - Metrics Cards

    private func metricsCards(_ overview: UsageStatsOverview) -> some View {
        HStack(spacing: 12) {
            metricCard(
                title: model.text("usage_stats_total"),
                value: formatNumber(overview.totalTokens),
                subtitle: model.text("usage_stats_tokens")
            )
            metricCard(
                title: model.text("usage_stats_daily_avg"),
                value: formatNumber(overview.dailyAverage),
                subtitle: model.text("usage_stats_tokens")
            )
            if let peak = overview.peakDay {
                metricCard(
                    title: model.text("usage_stats_peak_day"),
                    value: formatNumber(peak.tokens),
                    subtitle: peak.dateLabel
                )
            }
        }
    }

    private func metricCard(title: String, value: String, subtitle: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Daily Chart (bar chart using basic SwiftUI shapes)

    private func dailyChart(_ overview: UsageStatsOverview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.text("usage_stats_daily_detail"))
                .font(.system(size: 12, weight: .semibold))

            if overview.dailySeries.isEmpty {
                Text(model.text("usage_stats_no_data"))
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                    .padding(.vertical, 20)
            } else {
                let maxTokens = overview.dailySeries.map(\.tokens).max() ?? 1
                GeometryReader { geo in
                    HStack(alignment: .bottom, spacing: max(1, geo.size.width / CGFloat(overview.dailySeries.count) * 0.1)) {
                        ForEach(Array(overview.dailySeries.enumerated()), id: \.offset) { _, bucket in
                            VStack(spacing: 2) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.accentColor.opacity(0.8))
                                    .frame(height: max(2, geo.size.height * 0.85 * CGFloat(bucket.tokens) / CGFloat(maxTokens)))
                                    .help("\(bucket.dateLabel): \(formatNumber(bucket.tokens)) tokens")
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(height: 120)

                Text(model.text("usage_stats_daily_note"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Single Account Summary

    @ViewBuilder
    private var singleAccountSummary: some View {
        if let single = model.singleOverview {
            VStack(alignment: .leading, spacing: 8) {
                if let lifetime = single.lifetimeTokens, let asOf = single.statsAsOf {
                    summaryRow(model.format("usage_stats_lifetime", asOf), value: formatNumber(lifetime))
                }
                if let streak = single.currentStreakDays {
                    summaryRow(model.text("usage_stats_streak"), value: "\(streak) \(model.text("usage_stats_days"))")
                }
                if let longest = single.longestStreakDays {
                    summaryRow(model.text("usage_stats_longest_streak"), value: "\(longest) \(model.text("usage_stats_days"))")
                }
                if let threads = single.totalThreads {
                    summaryRow(model.text("usage_stats_threads"), value: formatNumber(threads))
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func summaryRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
    }

    // MARK: - Account Ranking

    private func accountRanking(_ overview: UsageStatsOverview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.text("usage_stats_account_rank"))
                .font(.system(size: 12, weight: .semibold))
            ForEach(Array(overview.accountBreakdown.enumerated()), id: \.offset) { _, entry in
                HStack {
                    Text(entry.displayName)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer()
                    Text(formatNumber(entry.totalTokens))
                        .font(.system(size: 11, design: .rounded))
                        .monospacedDigit()
                    Text(String(format: "%.0f%%", entry.proportion * 100))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Daily Detail Table

    private func dailyDetail(_ overview: UsageStatsOverview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !overview.dailySeries.isEmpty {
                ForEach(Array(overview.dailySeries.reversed().prefix(30).enumerated()), id: \.offset) { _, bucket in
                    HStack {
                        Text(bucket.dateLabel)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(formatNumber(bucket.tokens))
                            .font(.system(size: 11, design: .rounded))
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: - Status Bar

    private func statusBar(_ overview: UsageStatsOverview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 12) {
                Text(model.format("usage_stats_synced", "\(overview.syncedCount)", "\(overview.totalAccountCount)"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                if !overview.missingDates.isEmpty {
                    Text(model.format("usage_stats_missing_days", "\(overview.missingDates.count)"))
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }

                if overview.isPartial {
                    Text(model.text("usage_stats_partial"))
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }

                Spacer()

                Text(model.text("usage_stats_daily_note"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            // Auth expired warnings
            ForEach(model.syncResults.filter { result in
                if case .authExpired = result.status { return true }
                return false
            }, id: \.accountID) { result in
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text("\(result.displayName): \(model.text("usage_stats_auth_expired"))")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Helpers

    private func formatNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

// MARK: - Window opener (follows existing project pattern)

enum UsageStatsWindowController {
    private static var windowController: NSWindowController?

    @MainActor
    static func open(store: AccountStore, accounts: [AccountProfile], language: AppLanguage) {
        if let existing = windowController?.window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let model = UsageStatsModel(store: store, accounts: accounts, language: language)
        let view = UsageStatsView(model: model)
        let hostingController = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hostingController)
        window.title = L10n.string("usage_stats", language: language)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 700, height: 600))
        window.center()
        window.makeKeyAndOrderFront(nil)

        let controller = NSWindowController(window: window)
        windowController = controller
    }
}

#endif
