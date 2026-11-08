import AppKit
import Common
import MovieFolderParsing

/// Submits only the entry still held by a live secure field after confirmation.
@MainActor
protocol AccessTokenSettingsSubmitting: AnyObject {
  /// Clears the entry and tests it against the generation confirmed by the user.
  func saveEnteredAccessToken(expectedState: AccessTokenState)
  /// Removes only the access token generation confirmed by the user.
  func removeSavedAccessToken(expectedState: AccessTokenState)
}

/// Routes access token confirmations and navigation to the Settings flow owner.
@MainActor
protocol AccessTokenSettingsDelegate: AnyObject {
  /// Requests deliberate replacement without including the candidate token in navigation state.
  func accessTokenSettings(_ sender: any AccessTokenSettingsSubmitting, requestReplacement state: AccessTokenState)
  /// Requests deliberate removal of the captured saved access token generation.
  func accessTokenSettings(_ sender: any AccessTokenSettingsSubmitting, requestRemoval state: AccessTokenState)
  /// Requests navigation to the fixed public token-setup page.
  func accessTokenSettingsDidRequestTokenHelp(_ sender: NSViewController)
}

/// Presents secure access token actions and a local matching-data preview.
@MainActor
final class TMDbPane: SettingsTabViewController, AccessTokenSettingsSubmitting, NSTextFieldDelegate {
  /// Model retaining finite access token operations and non-secret presentation state.
  private let viewModel: ConfigurationViewModel
  /// Coordinator owning confirmation sheets and external navigation.
  weak var delegate: (any AccessTokenSettingsDelegate)?
  /// The only view state that holds the candidate until submission.
  private let tokenField = NSSecureTextField()
  /// Tests the entered candidate before saving it.
  private let saveButton = NSButton(title: "Test and Save Token", target: .none, action: .none)
  /// Tests the token currently in secure storage without changing it.
  private let testButton = NSButton(title: "Test Saved Token", target: .none, action: .none)
  /// Requests confirmation before deleting the saved token.
  private let removeButton = NSButton(title: "Remove Token…", target: .none, action: .none)
  /// Requests cooperative cancellation of the finite access token operation.
  private let cancelButton = NSButton(title: "Cancel", target: .none, action: .none)
  /// Reports presence separately from provider validation.
  private let stateLabel = NSTextField(wrappingLabelWithString: "Access token state not loaded.")
  /// Displays only fixed, allowlisted operation feedback.
  private let resultLabel = NSTextField(wrappingLabelWithString: " ")
  /// Unpersisted sample folder name, independent of configured collection authorization.
  private let sampleField = NSTextField()
  /// Local parser output explaining which matching fields a search would disclose.
  private let previewLabel = NSTextField(wrappingLabelWithString: "Enter a folder name to preview its title and year.")
  /// Existing production parser; previewing does not enumerate folders or contact TMDb.
  private let parser = ReleaseNameParser()

  /// Creates the access token pane backed by the shared configuration model.
  /// - Parameter viewModel: Owner of access token actions and safe status.
  init(viewModel: ConfigurationViewModel) {
    self.viewModel = viewModel
    super.init(nibName: .none, bundle: .none)
  }

  /// Archive construction cannot supply the required model.
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  /// Builds guidance, explicit actions, and the local parser preview.
  override func loadView() {
    let help = NSButton(title: "Open TMDb API Settings…", target: self, action: #selector(openTokenHelp))
    let guidance = NSTextField(wrappingLabelWithString:
      "In your TMDb account’s API settings, copy the API Read Access Token. "
      + "Paste the token without the Bearer prefix.")
    guidance.textColor = .secondaryLabelColor
    tokenField.placeholderString = "TMDb API Read Access Token"
    tokenField.setAccessibilityLabel("TMDb API Read Access Token")
    tokenField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    saveButton.target = self
    saveButton.action = #selector(requestSave)
    testButton.target = self
    testButton.action = #selector(testSavedToken)
    removeButton.target = self
    removeButton.action = #selector(requestRemoval)
    cancelButton.target = self
    cancelButton.action = #selector(cancelAccessTokenAction)
    let actions = NSStackView(views: [saveButton, testButton, removeButton, cancelButton])
    actions.orientation = .horizontal
    actions.spacing = 8
    let note = NSTextField(wrappingLabelWithString:
      "A successful test does not resume processing or clear recovery restrictions. "
      + "Replacement preserves collections and saved movie decisions.")
    note.textColor = .secondaryLabelColor
    let previewHeading = NSTextField(labelWithString: "Matching-data preview")
    previewHeading.font = .boldSystemFont(ofSize: 13)
    sampleField.placeholderString = "Example: Alien.1979.1080p.BluRay"
    sampleField.setAccessibilityLabel("Folder name for local matching preview")
    sampleField.delegate = self
    previewLabel.textColor = .secondaryLabelColor
    previewLabel.maximumNumberOfLines = 4
    resultLabel.maximumNumberOfLines = 3
    let content = makeContent(heading("TMDb", detail: "Keep the movie provider token in secure storage.") + [
      guidance, help, stateLabel, tokenField, actions, resultLabel, note,
      previewHeading, sampleField, previewLabel
    ])
    for field in [guidance, stateLabel, tokenField, resultLabel, note, sampleField, previewLabel] {
      field.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }
    updatePresentation()
  }

  /// Erases draft entry when leaving the pane; no candidate is persisted as view-model state.
  override func viewDidDisappear() {
    super.viewDidDisappear()
    tokenField.stringValue = ""
    sampleField.stringValue = ""
    updateLocalPreview()
  }

  /// Renders safe status and disables overlapping actions while cancellation drains.
  override func updatePresentation() {
    let state = viewModel.accessTokenState
    stateLabel.stringValue = state.map {
      $0.isConfigured ? "Saved token present. Use Test Saved Token to verify access." : "No token saved."
    } ?? "Access token state unavailable. Reopen Settings to try again."
    let available = !viewModel.isBusy && state != .none
    saveButton.title = state?.isConfigured == true ? "Test and Replace Token…" : "Test and Save Token"
    tokenField.isEnabled = available
    saveButton.isEnabled = available
    testButton.isEnabled = available && state?.isConfigured == true
    removeButton.isEnabled = available && state?.isConfigured == true
    cancelButton.isEnabled = viewModel.isAccessTokenActionRunning && !viewModel.isCancellingAccessTokenAction
    cancelButton.title = viewModel.isCancellingAccessTokenAction ? "Cancelling…" : "Cancel"
    resultLabel.stringValue = viewModel.accessTokenMessage ?? " "
    resultLabel.textColor = viewModel.isAccessTokenError ? .systemRed : .secondaryLabelColor
  }

  /// Copies the current entry once, clears it, and starts the approved test-before-save operation.
  /// - Parameter expectedState: Generation frozen before confirmation.
  func saveEnteredAccessToken(expectedState: AccessTokenState) {
    guard !viewModel.isBusy else { return }
    let candidate = tokenField.stringValue
    guard !candidate.isEmpty else { return }
    tokenField.stringValue = ""
    Task { await viewModel.saveAccessToken(candidate, expectedState: expectedState) }
  }

  /// Starts the removal confirmed for the captured generation.
  /// - Parameter expectedState: Generation frozen before confirmation.
  func removeSavedAccessToken(expectedState: AccessTokenState) {
    Task { await viewModel.removeAccessToken(expectedState: expectedState) }
  }

  /// Sends replacement through the coordinator while allowing explicit first-time setup directly.
  @objc private func requestSave() {
    guard !viewModel.isBusy, !tokenField.stringValue.isEmpty, let state = viewModel.accessTokenState else { return }
    if state.isConfigured {
      delegate?.accessTokenSettings(self, requestReplacement: state)
    } else {
      saveEnteredAccessToken(expectedState: state)
    }
  }

  /// Requests deliberate removal without placing access token text in the event.
  @objc private func requestRemoval() {
    guard !viewModel.isBusy, let state = viewModel.accessTokenState, state.isConfigured else { return }
    delegate?.accessTokenSettings(self, requestRemoval: state)
  }

  /// Starts only an explicit saved-token diagnostic.
  @objc private func testSavedToken() { Task { await viewModel.testSavedAccessToken() } }
  /// Cancels the active operation while leaving its model admission held until completion.
  @objc private func cancelAccessTokenAction() { viewModel.cancelAccessTokenAction() }
  /// Requests the coordinator-owned public help navigation.
  @objc private func openTokenHelp() { delegate?.accessTokenSettingsDidRequestTokenHelp(self) }

  /// Updates the local preview on each edit without initiating a search.
  func controlTextDidChange(_ notification: Notification) {
    guard notification.object as? NSTextField === sampleField else { return }
    updateLocalPreview()
  }

  /// Renders only parsed supported fields and explicit uncertainty from the existing parser.
  private func updateLocalPreview() {
    guard !sampleField.stringValue.isEmpty else {
      previewLabel.stringValue = "Enter a folder name to preview its title and year."
      return
    }
    switch parser.parse(sampleField.stringValue) {
    case .parsed(let parsed):
      previewLabel.stringValue = "A movie search would send title ‘\(parsed.title)’; year: "
        + "\(parsed.year.map(String.init) ?? "not supplied"). Technical suffixes are omitted. "
        + "Database-code suffixes are not used as lookup identifiers. This preview stays on your Mac."
    case .unresolved:
      previewLabel.stringValue = "The folder name cannot be parsed confidently. No automatic movie search "
        + "would be made from this name. Choose Movie lets you enter a title and optional year explicitly."
    }
  }
}
