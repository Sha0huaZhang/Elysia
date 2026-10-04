import SwiftUI
import AppKit

// MARK: - 设置
struct SettingsView: View {
    let songCount: Int
    let isCustomOrder: Bool
    let isRefreshing: Bool
    let lastRefreshed: Date?
    let onResetOrder: () -> Void
    let onRefresh: () -> Void

    @State private var isConfirmingReset = false
    @AppStorage("appLanguage") private var appLanguageRawValue = AppLanguage.system.rawValue
    @State private var isConfirmingRestart = false

    @State private var isCheckingVersion = false
    @State private var versionOutcome: VersionCheck.Outcome? = nil

    var body: some View {
        Form {
            Section("settings.language") {
                Picker("settings.language", selection: $appLanguageRawValue) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language.rawValue)
                    }
                }
                .labelsHidden()
                .onChange(of: appLanguageRawValue) { newValue in
                    (AppLanguage(rawValue: newValue) ?? .system).apply()
                    isConfirmingRestart = true
                }
            }

            Section("settings.library") {
                LabeledContent("settings.songCount") {
                    Text("\(songCount)")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("settings.lastRead") {
                    Text(lastRefreshedText)
                        .foregroundStyle(.secondary)
                }
                Text("settings.library.hint")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("settings.refresh", action: onRefresh)
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(isRefreshing)

                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                        Text("settings.refreshing")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("settings.order") {
                LabeledContent("settings.order.current") {
                    Text(isCustomOrder ? LocalizedStringKey("settings.order.custom") : LocalizedStringKey("settings.order.default"))
                        .foregroundStyle(.secondary)
                }
                Text("settings.order.hint")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("settings.order.restore") {
                    isConfirmingReset = true
                }
                .disabled(!isCustomOrder)
            }

            Section("settings.version") {
                LabeledContent("settings.version.current") {
                    // 只显示版本号。构建号（CFBundleVersion，打包时写成时间戳）不进界面，
                    // 它用于内部辨认构建：见日志开头与「显示简介」。
                    Text(AppVersion.current)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    Button("settings.version.check", action: checkForUpdates)
                        .disabled(isCheckingVersion)

                    if isCheckingVersion {
                        ProgressView()
                            .controlSize(.small)
                        Text("settings.version.checking")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                versionStatus
            }
        }
        .formStyle(.grouped)
        .alert("settings.order.restore.title", isPresented: $isConfirmingReset) {
            Button("common.cancel", role: .cancel) {}
            Button("settings.order.restore.confirm", role: .destructive, action: onResetOrder)
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("settings.order.restore.message")
        }
        .alert("settings.language.restart.title", isPresented: $isConfirmingRestart) {
            Button("common.later", role: .cancel) {}
            Button("common.restart", action: relaunch)
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("settings.language.restart.message")
        }
    }

    /// 查询结果：已是最新、有新版本（附安装指引）、或查询失败
    @ViewBuilder
    private var versionStatus: some View {
        if let outcome = versionOutcome {
            switch outcome {
            case .upToDate:
                Label("settings.version.upToDate", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)

            case .updateAvailable(let latest):
                VStack(alignment: .leading, spacing: 8) {
                    // 不用 "settings.version.available \(latest)"：字符串插值会生成带
                    // 占位符的查找键（settings.version.available %@），和 .strings 里的
                    // 键对不上，查不到就原样显示键名。这里显式取值再用 %@ 填充。
                    Label {
                        Text(verbatim: VersionCheck.availableMessage(latest: latest))
                    } icon: {
                        Image(systemName: "arrow.down.circle.fill")
                    }
                    .font(.callout)
                    .fontWeight(.semibold)
                    Text("settings.version.guide")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("settings.version.download") {
                        NSWorkspace.shared.open(UpdateChecker.downloadPage)
                    }
                }

            case .failed:
                Label("settings.version.failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func checkForUpdates() {
        isCheckingVersion = true
        versionOutcome = nil
        Task {
            let tag = try? await UpdateChecker.latestTag()
            await MainActor.run {
                versionOutcome = VersionCheck.outcome(current: AppVersion.current, latestTag: tag)
                isCheckingVersion = false
            }
        }
    }

    /// 重新启动应用，让新的语言设置生效
    private func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private var lastRefreshedText: String {
        guard let lastRefreshed else { return String(localized: "settings.lastRead.never") }
        return lastRefreshed.formatted(date: .omitted, time: .shortened)
    }
}
