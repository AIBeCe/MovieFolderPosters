import AppKit
import MovieFolderCommon
import Network
import Testing
@testable import MovieFolderPosters

/// A native menu preserves any valid saved regional choice beyond its initial local catalog.
@Test @MainActor func languagePickerPreservesSavedRegionalChoice() throws {
  let picker = MovieSearchLanguagePicker()
  let language = try TMDbLanguage("fr-BE")
  picker.display(language)
  #expect(picker.selectedLanguage == language)
  #expect(picker.selectedItem?.title.contains("fr-BE") == true)
  picker.display(.english)
  #expect(picker.selectedLanguage == .english)
  picker.display(language)
  #expect(picker.selectedLanguage == language)
  #expect(picker.itemArray.filter { $0.title.contains("fr-BE") }.count == 1)
}

/// Inheritance displays the effective choice disabled; an explicit draft can edit it without discarding other choices.
@Test @MainActor func collectionLanguageDraftInheritsAndRetainsOtherChoices() throws {
  let defaults = MovieMatchingConfiguration(requiresReleaseYearForAutomaticMatching: true,
    comparesOriginalTitles: false, searchLanguage: try TMDbLanguage("pt-BR"))
  let model = CollectionSetupViewModel(service: ConfigurationServiceFake(), applicationConfiguration: defaults)
  let controller = CollectionSetupViewController(viewModel: model)
  let picker = try #require(nativeViews(in: controller.view).compactMap { $0 as? MovieSearchLanguagePicker }.first)
  #expect(picker.selectedLanguage == defaults.searchLanguage)
  #expect(!picker.isEnabled)
  let inherit = try #require(nativeViews(in: controller.view).compactMap { $0 as? NSButton }
    .first { $0.title == "Use application matching settings" })
  inherit.performClick(.none)
  #expect(picker.isEnabled)
  picker.display(try TMDbLanguage("fr-BE"))
  let action = try #require(picker.action)
  _ = NSApplication.shared.sendAction(action, to: picker.target, from: picker)
  #expect(model.overrideConfiguration.searchLanguage == (try TMDbLanguage("fr-BE")))
  #expect(model.overrideConfiguration.requiresReleaseYearForAutomaticMatching)
  #expect(!model.overrideConfiguration.comparesOriginalTitles)
  model.cancel()
  #expect(!model.canAdd)
}
