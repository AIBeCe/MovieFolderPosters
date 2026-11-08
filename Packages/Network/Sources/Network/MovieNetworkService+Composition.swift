import Foundation
internal import Contracts
internal import TMDb

extension MovieNetworkService {
  /// Configures the default live provider and optional request observer.
  public init(token: String, requestDelegate: (any NetworkRequestDelegate)? = .none) throws {
    let observer = requestDelegate.map { ProviderRequestObserverAdapter(delegate: $0) }
    do {
      self.init(provider: try TMDbProvider(token: token, requestDelegate: observer))
    } catch let error as MovieProviderError {
      throw MovieNetworkError(error)
    }
  }

  /// Checks the default provider's token syntax without making a request.
  public static func validateAccessToken(_ token: String) throws {
    do {
      try TMDbProvider.validateAccessToken(token)
    } catch let error as MovieProviderError {
      throw MovieNetworkError(error)
    }
  }

  #if DEBUG
    /// Configures the default provider with isolated, explicitly selected fixtures.
    public init(token: String, fixturePosterData: Data) throws {
      do {
        self.init(provider: try TMDbProvider(token: token, fixturePosterData: fixturePosterData))
      } catch let error as MovieProviderError {
        throw MovieNetworkError(error)
      }
    }
  #endif

  /// Configures the default provider with a controlled transport for wire-level integration tests.
  @_spi(Testing) public init(
    token: String, testTransport: any NetworkTestTransport, requestDelegate: (any NetworkRequestDelegate)? = .none
  ) throws {
    let observer = requestDelegate.map { ProviderRequestObserverAdapter(delegate: $0) }
    do {
      self.init(provider: try TMDbProvider(token: token,
        transport: NetworkTestTransportAdapter(transport: testTransport), requestDelegate: observer))
    } catch let error as MovieProviderError {
      throw MovieNetworkError(error)
    }
  }
}
