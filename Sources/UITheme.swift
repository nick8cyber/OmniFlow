import SwiftUI
import AppKit

// MARK: - Design system
//
// Shared visual language for the Settings window and the Setup wizard: one
// card style, one row style, one banner style. The recording overlay keeps
// its own ported Windows palette and does not use any of this.

/// Standard settings card: accent icon chip + title (optional subtitle),
/// divider, then content rows on an opaque control-background surface.
struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                IconChip(icon: icon)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            Divider().padding(.leading, 48)
            content
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

/// Small rounded square holding a card's SF Symbol, tinted with the accent.
struct IconChip: View {
    let icon: String

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.accentColor)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
    }
}

/// Labelled row with an optional secondary line and a trailing control.
struct FormRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            control
        }
    }
}

/// Tinted inline notice (provider notes, validation hints, advice banners).
struct InfoBanner: View {
    enum Kind {
        case info, success, warning
    }

    let icon: String
    let text: String
    var kind: Kind = .info

    private var tint: Color {
        switch kind {
        case .info: return .accentColor
        case .success: return .green
        case .warning: return .orange
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(tint)
                .padding(.top, 1)
            Text(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.1)))
    }
}

/// Shared copy-to-pasteboard button with the 1.5 s "Copied" reset. Replaces
/// the per-view reimplementations of the same behaviour.
struct CopyButton: View {
    let text: String
    var label: String = "Copy"
    var showsLabel = true

    @State private var copied = false
    @State private var resetWorkItem: DispatchWorkItem?

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            copied = true
            resetWorkItem?.cancel()
            let workItem = DispatchWorkItem { copied = false }
            resetWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
        } label: {
            if showsLabel {
                Label(copied ? "Copied" : label,
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundColor(copied ? .green : .secondary)
            }
        }
    }
}

/// Icon + title + optional hint, used for empty lists and placeholder panes.
struct EmptyStateView: View {
    let icon: String
    let title: String
    var hint: String? = nil

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

/// Shared Fn/emoji-picker advice, previously duplicated in Setup and the
/// shortcut components.
struct FnAdviceBanner: View {
    var body: some View {
        Label("If pressing your shortcut opens the emoji picker instead, set the Globe/Fn key to \"Do Nothing\" in System Settings > Keyboard > Keyboard Shortcuts > Fn Keys.",
              systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundColor(.orange)
    }
}

/// Selectable provider tile (Gemini vs OpenAI-compatible) used in Settings
/// and in the Setup wizard.
struct ProviderCard: View {
    let provider: AIProvider
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: provider.sfSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(provider.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }
}

/// HStack pair of provider tiles filling the available width.
struct ProviderCardPair: View {
    @Binding var selection: AIProvider

    var body: some View {
        HStack(spacing: 12) {
            ForEach(AIProvider.allCases) { provider in
                ProviderCard(provider: provider,
                             isSelected: selection == provider,
                             onSelect: { selection = provider })
            }
        }
    }
}

/// Static replica of the real recording overlay card (dark pill, equalizer,
/// REC pill) for previews inside Settings and Setup.
struct OverlayPreviewCard: View {
    var body: some View {
        HStack(spacing: 10) {
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(LinearGradient(colors: [Self.accentBright, Self.accent],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 3, height: Self.barHeights[index])
                }
            }
            .frame(height: 20)
            Text("Проверка, раз, два, три")
                .font(.system(size: 12))
                .foregroundColor(Self.textBright)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 3) {
                Circle().fill(Color(red: 0.88, green: 0.33, blue: 0.27)).frame(width: 5, height: 5)
                Text("REC")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(red: 1.0, green: 0.56, blue: 0.48))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(red: 0.47, green: 0.16, blue: 0.17).opacity(0.35)))
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(LinearGradient(colors: [Self.cardTop, Self.cardBottom],
                                 startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Self.cardBorder, lineWidth: 1))
    }

    // RecordingOverlay's ported Theme.cs palette, mirrored for the preview.
    private static let cardTop = Color(red: 0.133, green: 0.133, blue: 0.161)
    private static let cardBottom = Color(red: 0.078, green: 0.078, blue: 0.098)
    private static let cardBorder = Color(red: 0.251, green: 0.251, blue: 0.290)
    private static let accent = Color(red: 0.235, green: 0.702, blue: 0.443)
    private static let accentBright = Color(red: 0.502, green: 0.804, blue: 0.620)
    private static let textBright = Color(red: 0.941, green: 0.941, blue: 0.957)
    private static let barHeights: [CGFloat] = [9, 14, 17, 12, 8]
}

/// Shared GitHub branding header: app icon, repo link, star count, avatars.
/// Previously duplicated between Settings and Setup.
struct BrandHeader: View {
    var showsContributors = false

    @EnvironmentObject private var appState: AppState
    @StateObject private var githubCache = GitHubMetadataCache.shared

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppName.displayName)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("v\(appVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                AsyncImage(url: URL(string: "https://avatars.githubusercontent.com/u/992248")) { image in
                    image.resizable().frame(width: 22, height: 22).clipShape(Circle())
                } placeholder: {
                    Circle().fill(Color.secondary.opacity(0.3)).frame(width: 22, height: 22)
                }
                Button("nick8cyber/OmniFlow") {
                    if let url = URL(string: "https://github.com/nick8cyber/OmniFlow") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.system(.caption, design: .monospaced))
                Spacer()
                if let starCount = githubCache.starCount {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill").foregroundColor(.yellow)
                        Text("\(starCount.formatted()) \(starCount == 1 ? "star" : "stars")")
                            .font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                }
                Button("Star") {
                    if let url = URL(string: "https://github.com/nick8cyber/OmniFlow") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.yellow.opacity(0.18)))
            }
            if showsContributors, !githubCache.recentContributors.isEmpty {
                HStack(spacing: -6) {
                    ForEach(githubCache.recentContributors.prefix(15)) { contributor in
                        GitHubAvatarView(avatarURL: contributor.avatarUrl + "?s=44",
                                         profileURL: contributor.htmlUrl)
                    }
                    Spacer()
                }
            } else if !showsContributors, !githubCache.recentStargazers.isEmpty {
                HStack(spacing: -6) {
                    ForEach(githubCache.recentStargazers, id: \.id) { stargazer in
                        GitHubAvatarView(avatarURL: stargazer.user.avatarThumbnailUrl,
                                         profileURL: stargazer.user.htmlUrl)
                    }
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
        .onAppear { Task { await githubCache.fetchIfNeeded() } }
    }
}
