import Contracts
import Testing

/// Providers receive the same canonical language identifier regardless of caller spelling.
@Test func providerLanguageCanonicalizesLanguageAndRegion() throws {
  #expect(try ProviderLanguage("PT-br").rawValue == "pt-BR")
  #expect(ProviderLanguage.english.rawValue == "en-US")
  #expect(throws: MovieProviderError.invalidQuery) { try ProviderLanguage("pt_BR") }
}
