import AppKit
import Combine
import OSLog
import SwiftUI
import SwitcherCore

@MainActor
final class SwitcherAppDelegate: NSObject, NSApplicationDelegate {
    static var usesDevEntry: Bool {
        Bundle.main.bundleIdentifier == "local.codex-account-switcher.claude-verify"
    }

    let model = AppModel.live()
    let updater = AppUpdater()

    private lazy var quota = AccountQuotaModel(store: model.usageStatsStore)
    private lazy var quotaRefresh = AccountQuotaRefreshScheduler(
        canRefresh: { [weak self] in
            guard let self else { return false }
            return hasLoaded && !model.accounts.isEmpty && !quota.isLoading
        },
        refresh: { [weak self] in
            guard let self else { return }
            let startedAt = Date()
            let accounts = model.accounts
            await quota.refresh(accounts: accounts)
            guard Self.usesDevEntry, !Task.isCancelled else { return }
            let succeeded = accounts.filter {
                let state = quota.states[$0.id]
                return state?.failure == nil && (state?.snapshot?.fetchedAt ?? .distantPast) >= startedAt
            }.count
            let failed = accounts.filter { quota.states[$0.id]?.failure != nil }.count
            let skipped = max(0, accounts.count - succeeded - failed)
            Logger(subsystem: "local.codex-account-switcher.claude-verify", category: "QuotaRefresh")
                .notice("Background quota refresh completed attempted=\(accounts.count, privacy: .public) success=\(succeeded, privacy: .public) failure=\(failed, privacy: .public) skipped=\(skipped, privacy: .public)")
        }
    )
    private lazy var stats = UsageStatsModel(
        store: model.usageStatsStore, accounts: model.accounts, language: model.settings.language
    )
    private var quotaObservation: AnyCancellable?
    private var appearanceObservation: NSKeyValueObservation?
    private var displayClock: AnyCancellable?
    private var quotaAccounts: [SwitcherCore.AccountProfile] = []

    private var modelObservation: AnyCancellable?
    private var wakeObservation: AnyCancellable?
    private var panel: NSPopover?
    private var statusItem: NSStatusItem?
    private var hasLoaded = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        modelObservation = model.objectWillChange.sink { [weak self] in
            guard let self else { return }
            updater.accountOperationInProgress = model.isMutating || model.isAddingAccount
            DispatchQueue.main.async { [weak self] in self?.modelDidChange() }
        }
        updater.start()
        wakeObservation = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.model.refreshWeeklyUsage()
                    self?.quotaRefresh.requestRefresh()
                }
            }
        installStatusItem()
        if statusItem != nil {
            quotaObservation = quota.$states.sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.updateStatusItem() }
            }
            displayClock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
                .sink { [weak self] _ in self?.updateStatusItem() }
        }
        Task {
            await model.startBackgroundUsageRefresh()
            hasLoaded = true
            quotaRefresh.start()
            modelDidChange()
            showPanel(refreshQuota: false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        quotaRefresh.stop()
        wakeObservation?.cancel()
        displayClock?.cancel()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    private func showPanel(refreshQuota: Bool = true) {
        guard hasLoaded, let button = statusItem?.button else { return }
        if panel == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentSize = NSSize(width: 400, height: 680)
            popover.delegate = stats
            popover.contentViewController = NSHostingController(rootView: CompactSwitcherPanel(
                model: model, stats: stats, quota: quota, closePanel: { [weak self] in self?.panel?.close() }
            ))
            panel = popover
        }
        if refreshQuota, !quota.isLoading {
            Task { await quota.refresh(accounts: model.accounts) }
        }
        NSApp.activate(ignoringOtherApps: true)
        stats.accounts = model.accounts
        panel?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        panel?.contentViewController?.view.window?.makeKey()

    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let autosaveName = Self.usesDevEntry ? "CodexAccountSwitcherDev" : "CodexAccountSwitcher"
        // Start near the right edge on a clean install; preserve a user's saved placement.
        let positionKey = "NSStatusItem Preferred Position " + autosaveName
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(0.0, forKey: positionKey)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = autosaveName
        item.isVisible = true
        if let button = item.button {
            button.toolTip = "Codex Account Switcher"
            button.setAccessibilityLabel("Codex Account Switcher")
            button.target = self
            button.action = #selector(togglePanelFromMenuBar)
        }
        statusItem = item
        if let button = item.button {
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in self?.updateStatusItem() }
            }
        }
        updateStatusItem()
    }

    private func modelDidChange() {
        guard hasLoaded else { return }
        updateStatusItem()
        if quotaAccounts != model.accounts {
            quotaAccounts = model.accounts
            Task { await quota.refresh(accounts: model.accounts) }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let status = WeeklyQuotaStatus(accounts: model.accounts, activeID: model.activeAccountID,
            identityConfirmed: model.activeIdentityConfirmed, states: quota.states, now: .now)
        button.image = WeeklyQuotaStatusImage.image(remainingPercent: status.remainingPercent, logo: MenuBarLogo.image,
            isCached: status.isCached, appearance: button.effectiveAppearance)
        button.alternateImage = WeeklyQuotaStatusImage.image(remainingPercent: status.remainingPercent, logo: MenuBarLogo.image,
            isCached: status.isCached, appearance: button.effectiveAppearance, highlighted: true)
        button.toolTip = status.tooltip
        button.setAccessibilityLabel("Codex · 每周剩余 " + (status.remainingPercent.map { "\($0)%" } ?? "暂无数据"))
    }

    @objc private func togglePanelFromMenuBar() {
        if panel?.isShown == true { panel?.performClose(nil) }
        else { showPanel() }
    }
}
