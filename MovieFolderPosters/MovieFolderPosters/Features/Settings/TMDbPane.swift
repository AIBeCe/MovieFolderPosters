import AppKit
import MovieFolderCommon
import MovieFolderParsing

/// Submits only the entry still held by a live secure field after confirmation.
@MainActor
protocol CredentialSettingsSubmitting: AnyObject {
  /// Clears the entry and tests it against the generation confirmed by the user.
  func saveEnteredCredential(expectedState: CredentialState)
  /// Removes only the credential generation confirmed by the user.
  func removeSavedCredential(expectedState: CredentialState)
}

/// Routes credential confirmations and navigation to the Settings flow owner.
@MainActor
protocol CredentialSettingsDelegate: AnyObject {
  /// Requests deliberate replacement without including the candidate token in navigation state.
  func credentialSettings(_ sender: any CredentialSettingsSubmitting, requestReplacement state: CredentialState)
  /// Requests deliberate removal of the captured saved credential generation.
  func credentialSettings(_ sender: any CredentialSettingsSubmitting, requestRemoval state: CredentialState)
  /// Requests navigation to the fixed public token-setup page.
  func credentialSettingsDidRequestTokenHelp(_ sender: NSViewController)
}

/// Presents secure credential actions and a local identification-data preview.
@MainActor
final class TMDbPane: SettingsPaneController, CredentialSettingsSubmitting, NSTextFieldDelegate {
  /// Model retaining finite credential operations and non-secret presentation state.
  private let viewModel: ConfigurationViewModel
  /// Coordinator owning confirmation sheets and external navigation.
  weak var delegate: (any CredentialSettingsDelegate)?
  /// The only view state that holds the candidate until submission.
  private let tokenField = NSSecureTextField()
  /// Tests the entered candidate before saving it.
  private let saveButton = NSButton(title: "Test and Save Token", target: .none, action: .none)
  /// Tests the token currently in secure storage without changing it.
  private let testButton = NSButton(title: "Test Saved Token", target: .none, action: .none)
  /// Requests confirmation before deleting the saved token.
  private let removeButton = NSButton(title: "Remove Token…", target: .none, action: .none)
  /// Requests cooperative cancellation of the finite credential operation.
  private let cancelButton = NSButton(title: "Cancel", target: .none, action: .none)
  /// Reports presence separately from provider validation.
  private let stateLabel = NSTextField(wrappingLabelWithString: "Credential state not loaded.")
  /// Displays only fixed, allowlisted operation feedback.
  private let resultLabel = NSTextField(wrappingLabelWithString: " ")
  /// Unpersisted sample folder name, independent of configured collection authorization.
  private let sampleField = NSTextField()
  /// Local parser output explaining which identification fields a search would disclose.
  private let previewLabel = NSTextField(wrappingLabelWithString: "Enter a folder name to preview its title and year.")
  /// Existing production parser; previewing does not enumerate folders or contact TMDb.
  private let parser = ReleaseNameParser()

  /// Creates the credential pane backed by the shared configuration model.
  /// - Parameter viewModel: Owner of credential actions and safe status.
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
    cancelButton.action = #selector(cancelCredentialAction)
    let actions = NSStackView(views: [saveButton, testButton, removeButton, cancelButton])
    actions.orientation = .horizontal
    actions.spacing = 8
    let note = NSTextField(wrappingLabelWithString:
      "A successful test does not resume processing or clear recovery restrictions. "
      + "Replacement preserves collections and saved movie decisions.")
    note.textColor = .secondaryLabelColor
    let previewHeading = NSTextField(labelWithString: "Identification-data preview")
    previewHeading.font = .boldSystemFont(ofSize: 13)
    sampleField.placeholderString = "Example: Alien.1979.1080p.BluRay"
    sampleField.setAccessibilityLabel("Folder name for local identification preview")
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
    let state = viewModel.credentialState
    stateLabel.stringValue = state.map {
      $0.isConfigured ? "Saved token present. Use Test Saved Token to verify access." : "No token saved."
    } ?? "Credential state unavailable. Reopen Settings to try again."
    let available = !viewModel.isBusy && state != .none
    saveButton.title = state?.isConfigured == true ? "Test and Replace Token…" : "Test and Save Token"
    tokenField.isEnabled = available
    saveButton.isEnabled = available
    testButton.isEnabled = available && state?.isConfigured == true
    removeButton.isEnabled = available && state?.isConfigured == true
    cancelButton.isEnabled = viewModel.isCredentialOperationRunning && !viewModel.isCancellingCredentialOperation
    cancelButton.title = viewModel.isCancellingCredentialOperation ? "Cancelling…" : "Cancel"
    resultLabel.stringValue = viewModel.credentialMessage ?? " "
    resultLabel.textColor = viewModel.isCredentialError ? .systemRed : .secondaryLabelColor
  }

  /// Copies the current entry once, clears it, and starts the approved test-before-save operation.
  /// - Parameter expectedState: Generation frozen before confirmation.
  func saveEnteredCredential(expectedState: CredentialState) {
    guard !viewModel.isBusy else { return }
    let candidate = tokenField.stringValue
    guard !candidate.isEmpty else { return }
    tokenField.stringValue = ""
    Task { await viewModel.saveCredential(candidate, expectedState: expectedState) }
  }

  /// Starts the removal confirmed for the captured generation.
  /// - Parameter expectedState: Generation frozen before confirmation.
  func removeSavedCredential(expectedState: CredentialState) {
    Task { await viewModel.removeCredential(expectedState: expectedState) }
  }

  /// Sends replacement through the coordinator while allowing explicit first-time setup directly.
  @objc private func requestSave() {
    guard !viewModel.isBusy, !tokenField.stringValue.isEmpty, let state = viewModel.credentialState else { return }
    if state.isConfigured {
      delegate?.credentialSettings(self, requestReplacement: state)
    } else {
      saveEnteredCredential(expectedState: state)
    }
  }

  /// Requests deliberate removal without placing credential text in the event.
  @objc private func requestRemoval() {
    guard !viewModel.isBusy, let state = viewModel.credentialState, state.isConfigured else { return }
    delegate?.credentialSettings(self, requestRemoval: state)
  }

  /// Starts only an explicit saved-token diagnostic.
  @objc private func testSavedToken() { Task { await viewModel.testSavedCredential() } }
  /// Cancels the active operation while leaving its model admission held until completion.
  @objc private func cancelCredentialAction() { viewModel.cancelCredentialOperation() }
  /// Requests the coordinator-owned public help navigation.
  @objc private func openTokenHelp() { delegate?.credentialSettingsDidRequestTokenHelp(self) }

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
