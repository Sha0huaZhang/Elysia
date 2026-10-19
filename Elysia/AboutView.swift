import AppKit
import SwiftUI

// MARK: - 关于
//
// 与 Voanisa 的「关于」保持同一套内容：图标与名称、一句话简介、用途说明、版本、
// 官网 / GitHub / 许可证 / 日志入口、版权。
//
// 官网放在最前：这是用户从这个页面最可能想去的地方。
struct AboutView: View {
    private static let websiteURL = URL(string: "https://elysia.macwave.org")!
    private static let githubURL = URL(string: "https://github.com/Sha0huaZhang/Elysia")!
    private static let licenseURL = URL(string: "https://github.com/Sha0huaZhang/Elysia/blob/main/LICENSE")!

    var body: some View {
        Form {
            Section("settings.about") {
                HStack(alignment: .top, spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Elysia")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("settings.about.tagline")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                Text("settings.about.description")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // 只显示版本号，不带构建号：界面上的版本一直是这样显示的，构建号留在
                // 日志开头，用来分辨手上装的是哪一次构建
                LabeledContent("settings.about.version") {
                    Text(AppVersion.current)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 14) {
                    Link("settings.about.website", destination: Self.websiteURL)
                    Link("settings.about.github", destination: Self.githubURL)
                    Link("settings.about.license", destination: Self.licenseURL)
                    Button("settings.about.openLog") {
                        NSWorkspace.shared.open(Diagnostics.fileURL)
                    }
                }

                Text("settings.about.copyright")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
