import SwiftUI

/// Core 阅读器的完整版面、列表外观设置。
/// 持久化键与取值范围保持不变，Core 和 Go 切换共享视图后继续读取原有偏好。
public struct ReadBoardReaderPane: View {
    @AppStorage("reading.theme") private var themeRaw: String = "claude"
    @AppStorage("reading.themeMode") private var themeModeRaw: String = ReadingTheme.Mode.system.rawValue
    @AppStorage("reading.font") private var fontRaw: String = "system"
    @AppStorage("reading.fontSize") private var fontSize: Double = 16
    @AppStorage("reading.titleFontSize") private var titleFontSize: Double = 24
    @AppStorage("reading.metaFontSize") private var metaFontSize: Double = 12
    @AppStorage("reading.summaryFontSize") private var summaryFontSize: Double = 14
    @AppStorage("reading.lineSpacing") private var lineSpacing: Double = 6
    @AppStorage("reading.contentWidth") private var contentWidth: Double = 720
    @AppStorage("reading.uiFontScale") private var uiFontScale: Double = 1.0

    @AppStorage("list.density") private var density: String = "comfortable"
    @AppStorage("list.showSource") private var showSource: Bool = true
    @AppStorage("list.showDate") private var showDate: Bool = true
    @AppStorage("list.unreadBold") private var unreadBold: Bool = true
    @AppStorage("list.dateFormat") private var dateFormat: String = "absolute"

    public init() {}

    public var body: some View {
        Form {
            Section("阅读区版面") {
                Picker("主题", selection: $themeRaw) {
                    ForEach(ReadingTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme.rawValue)
                    }
                }
                .tint(ReadBoardDesign.C.accent)

                Picker("亮暗", selection: $themeModeRaw) {
                    ForEach(ReadingTheme.Mode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .tint(ReadBoardDesign.C.accent)

                Picker("正文/标题字体", selection: $fontRaw) {
                    ForEach(ReadingFont.presets, id: \.self) { font in
                        Text(font.displayName).tag(fontKey(font))
                    }
                    Divider()
                    ForEach(ReadingFont.availableFontFamilies, id: \.self) { family in
                        Text(family)
                            .font(.custom(family, size: 13))
                            .tag("custom:\(family)")
                    }
                }
                .tint(ReadBoardDesign.C.accent)

                settingSlider("正文字号 \(Int(fontSize))", value: $fontSize, range: 12...32, step: 1)
                settingSlider("标题字号 \(Int(titleFontSize))", value: $titleFontSize, range: 16...36, step: 1)
                settingSlider("信息字号 \(Int(metaFontSize))", value: $metaFontSize, range: 8...28, step: 1)
                settingSlider("摘要字号 \(Int(summaryFontSize))", value: $summaryFontSize, range: 8...28, step: 1)
                settingSlider("行距 \(Int(lineSpacing))", value: $lineSpacing, range: 0...20, step: 1)
                settingSlider("内容宽度 \(Int(contentWidth))", value: $contentWidth, range: 600...1200, step: 50)
                settingSlider(
                    "界面缩放 \(Int(uiFontScale * 100))%",
                    value: $uiFontScale,
                    range: 0.8...1.6,
                    step: 0.05)
            }

            Section("文章列表") {
                Picker("列表密度", selection: $density) {
                    Text("舒适").tag("comfortable")
                    Text("紧凑").tag("compact")
                }
                .tint(ReadBoardDesign.C.accent)
                Toggle("显示来源名", isOn: $showSource)
                    .tint(ReadBoardDesign.C.accent)
                Toggle("显示日期", isOn: $showDate)
                    .tint(ReadBoardDesign.C.accent)
                if showDate {
                    Picker("日期格式", selection: $dateFormat) {
                        Text("绝对（2026-07-25）").tag("absolute")
                        Text("相对（3 小时前）").tag("relative")
                    }
                    .tint(ReadBoardDesign.C.accent)
                }
                Toggle("未读文章标题加粗", isOn: $unreadBold)
                    .tint(ReadBoardDesign.C.accent)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func settingSlider(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        HStack {
            Text(label)
                .frame(width: 96, alignment: .leading)
            Slider(value: value, in: range, step: step)
                .tint(ReadBoardDesign.C.accent)
        }
    }

    private func fontKey(_ font: ReadingFont) -> String {
        switch font {
        case .system: return "system"
        case .heiti: return "heiti"
        case .kaiti: return "kaiti"
        case .fangsong: return "fangsong"
        case .custom(let name): return "custom:\(name)"
        }
    }
}
