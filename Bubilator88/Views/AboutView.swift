import SwiftUI

struct AboutView: View {
    @Environment(\.openURL) private var openURL

    private let appVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }()

    private let buildNumber: String = {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }()

    private struct Credit: Identifiable {
        let id = UUID()
        let category: String
        let title: String
        let author: String?
        let url: String?
    }

    private let credits: [Credit] = [
        Credit(category: String(localized: "FM Synthesis", comment: "About credit category"), title: "fmgen", author: "cisc", url: "http://retropc.net/cisc/sound/"),
        Credit(category: String(localized: "Reference", comment: "About credit category"), title: "QUASI88", author: "S.Fukunaga", url: "https://www.eonet.ne.jp/~showtime/quasi88/"),
        Credit(category: String(localized: "Reference", comment: "About credit category"), title: "common source code project", author: "Takeda Toshiya", url: "https://takeda-toshiya.my.coocan.jp/common/index.html"),
        Credit(category: String(localized: "Reference", comment: "About credit category"), title: "X88000", author: "Manuke", url: "https://quagma.sakura.ne.jp/manuke/x88000.html"),
        Credit(category: String(localized: "Technical Docs", comment: "About credit category"), title: "PC-8801についてのページ", author: "youkan", url: "http://www.maroon.dti.ne.jp/youkan/pc88/"),
        Credit(category: String(localized: "Technical Docs", comment: "About credit category"), title: "PC-8801 VRAM情報", author: nil, url: "http://mydocuments.g2.xrea.com/html/p8/vraminfo.html"),
        Credit(category: String(localized: "Scaling", comment: "About credit category"), title: "xBRZ", author: "Zenju", url: "https://sourceforge.net/projects/xbrz/"),
        Credit(category: String(localized: "AI Upscale", comment: "About credit category"), title: "Real-ESRGAN", author: nil, url: "https://github.com/xinntao/Real-ESRGAN"),
        Credit(category: String(localized: "AI Coding", comment: "About credit category"), title: "Claude Code", author: "Anthropic", url: "https://claude.ai/code"),
    ]

    var body: some View {
        VStack(spacing: 12) {
            if let icon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }

            Text("Bubilator88")
                .font(.title)
                .fontWeight(.bold)

            Text("NEC PC-8801mkIISR Emulator for macOS", comment: "About dialog subtitle")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Version \(appVersion) (\(buildNumber))", comment: "About dialog version")
                .font(.callout)
                .foregroundStyle(.tertiary)

            Divider()
                .padding(.horizontal, 20)

            ScrollView {
                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 8) {
                    ForEach(credits) { credit in
                        GridRow {
                            Text(credit.category)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)

                            VStack(alignment: .leading, spacing: 2) {
                                if let urlString = credit.url {
                                    Button {
                                        if let linkURL = URL(string: urlString) {
                                            openURL(linkURL)
                                        }
                                    } label: {
                                        Text(credit.title)
                                            .font(.callout)
                                            .underline()
                                    }
                                    .buttonStyle(.plain)
                                    .onHover { hovering in
                                        if hovering {
                                            NSCursor.pointingHand.push()
                                        } else {
                                            NSCursor.pop()
                                        }
                                    }
                                } else {
                                    Text(credit.title)
                                        .font(.callout)
                                }

                                if let author = credit.author {
                                    Text("by \(author)")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 260)

            Divider()
                .padding(.horizontal, 20)

            Text("© 2026 bubio. Licensed under GPL v2.0", comment: "About dialog copyright")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 460)
    }
}
