import Foundation
import Testing

@testable import MovieFolderCommon

/// Configuration defaults preserve established timing while custom policies reject unsafe values.
struct MovieFolderProcessorConfigurationTests {
  /// The standard policy retains the timing values used before configuration injection.
  @Test func standardPolicyPreservesExistingIntervals() {
    let configuration = MovieFolderProcessorConfiguration.standard

    #expect(configuration.incompleteSearchRetryInterval == 86_400)
    #expect(configuration.transientFailureRetryInterval == 600)
    #expect(configuration.queryCacheLifetime == 86_400)
    #expect(configuration.minimumProviderRetryInterval == 60)
    #expect(configuration.maximumProviderRetryInterval == 86_400)
  }

  /// A custom instance keeps its values without changing the shared standard policy.
  @Test func customPolicyIsIndependentOfStandardPolicy() throws {
    let configuration = try MovieFolderProcessorConfiguration(
      incompleteSearchRetryInterval: 45, transientFailureRetryInterval: 15,
      queryCacheLifetime: 120, minimumProviderRetryInterval: 5,
      maximumProviderRetryInterval: 300)

    #expect(configuration.incompleteSearchRetryInterval == 45)
    #expect(configuration.transientFailureRetryInterval == 15)
    #expect(configuration.queryCacheLifetime == 120)
    #expect(configuration.minimumProviderRetryInterval == 5)
    #expect(configuration.maximumProviderRetryInterval == 300)
    #expect(MovieFolderProcessorConfiguration.standard.transientFailureRetryInterval == 600)
  }

  /// Invalid time values and inverted provider bounds cannot enter a processor.
  @Test(arguments: [Double.zero, -1, .infinity, -.infinity, .nan])
  func rejectsNonPositiveOrNonFiniteIntervals(_ interval: TimeInterval) {
    #expect(throws: MovieFolderProcessorConfigurationError.invalidInterval) {
      _ = try MovieFolderProcessorConfiguration(
        incompleteSearchRetryInterval: interval, transientFailureRetryInterval: 15,
        queryCacheLifetime: 120, minimumProviderRetryInterval: 5,
        maximumProviderRetryInterval: 300)
    }
  }

  /// A provider maximum must not be lower than its minimum.
  @Test func rejectsInvertedProviderBounds() {
    #expect(throws: MovieFolderProcessorConfigurationError.invertedProviderRetryRange) {
      _ = try MovieFolderProcessorConfiguration(
        incompleteSearchRetryInterval: 45, transientFailureRetryInterval: 15,
        queryCacheLifetime: 120, minimumProviderRetryInterval: 301,
        maximumProviderRetryInterval: 300)
    }
  }
}
