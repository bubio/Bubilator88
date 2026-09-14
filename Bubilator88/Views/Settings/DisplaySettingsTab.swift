import Bubilator88Core
import SwiftUI
import Translation

struct DisplaySettingsTab: View {
  let viewModel: EmulatorViewModel
  @Environment(Settings.self) private var settings
  @State private var availableLanguages: [TranslationLanguage] = TranslationLanguage.defaultList

  var body: some View {
    // `@Environment` hands back the object, not bindings; this is the
    // Observation-era way to get `$settings` back inside the body.
    @Bindable var settings = settings
    Form {
      Section("Fullscreen") {
        Picker("Scaling Mode", selection: $settings.fullscreenIntegerScaling) {
          Text("Fit to Screen").tag(false)
          Text("Integer Scaling").tag(true)
        }
        .pickerStyle(.radioGroup)
        Text(settings.fullscreenIntegerScaling
          ? "Pixel-perfect display with black borders. No scaling artifacts."
          : "Fill the screen as much as possible while maintaining aspect ratio.")
          .settingsDescriptionStyle()
      }

      Section("Translation Overlay") {
        Picker("Target Language", selection: $settings.translationTargetLanguage) {
          ForEach(availableLanguages, id: \.identifier) { lang in
            Text(lang.localizedName).tag(lang.identifier)
          }
        }
        .pickerStyle(.menu)
        .onChange(of: settings.translationTargetLanguage) {
          guard viewModel.translationManager.isSessionActive else { return }
          viewModel.translationManager.hardReset()
          viewModel.toggleTranslation(true)
        }
        Text("Translates Japanese text detected on screen. Requires language download in System Settings.")
          .settingsDescriptionStyle()
      }

      Section {
        Toggle("Show Tape Icon", isOn: $settings.showTapeInStatusBar)
      }

      Section {
        Toggle("Play dissolve animation on reset", isOn: $settings.resetAnimationEnabled)
      }
    }
    .formStyle(.grouped)
    .task {
      availableLanguages = await TranslationLanguage.fetchAvailable()
    }
  }
}

struct TranslationLanguage: Identifiable {
  let identifier: String
  let localizedName: String
  var id: String { identifier }

  /// Fallback list before async API call completes.
  static let defaultList: [TranslationLanguage] = [
    TranslationLanguage(identifier: "en-Latn-US", localizedName: "English (Latin, United States)")
  ]

  /// Fetch languages available for ja→X translation via LanguageAvailability API.
  ///
  /// `@concurrent` so `LanguageAvailability` (non-Sendable) stays confined to a
  /// background executor. Plain `nonisolated` is not enough under approachable
  /// concurrency: the function would inherit the caller's (main actor)
  /// isolation and the instance would still have to cross it.
  @concurrent nonisolated static func fetchAvailable() async -> [TranslationLanguage] {
    let availability = LanguageAvailability()
    let japanese = Locale.Language(identifier: "ja")
    let supported = await availability.supportedLanguages
    var results: [TranslationLanguage] = []

    for lang in supported {
      guard lang != japanese else { continue }
      let status = await availability.status(from: japanese, to: lang)
      guard status != .unsupported else { continue }
      let identifier = lang.maximalIdentifier
      let name = Locale.current.localizedString(forIdentifier: identifier) ?? identifier
      results.append(TranslationLanguage(identifier: identifier, localizedName: name))
    }

    return results.sorted { $0.localizedName < $1.localizedName }
  }
}
