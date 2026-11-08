# Network boundary refactor

## Approved design

The [target architecture](ARCHITECTURE.md) defines the module boundaries.
The host and Finder use the app-owned `NetworkClient` in Common.
The public `Network` product adapts an injected `MovieProviding` implementation
to its own API. The shared `Contracts` package owns the provider interface.
Network selects TMDb internally. Common consumes Network's public API, and
the host and Finder use Common. These app targets have no direct dependency
on TMDb or Contracts. HTTPTransport supplies generic request execution.

## Implementation points

1. Keep the generic transport error behavior from `3465516`. Move HTTP
   transport and TMDb into standalone packages, with their existing tests.
   TMDb exposes its conforming provider entry point and owns its wire types.
2. Define `Contracts` and inject a provider into Network. Verify
   that a second implementation can serve requests through the same API.
   The host, Finder, and Common continue to use the app-owned adapter.
3. Retain test-only wire injection for existing integration scenarios. Update
   disposable package graphs and coverage accounting for the new packages.

The first extraction exposed direct TMDb imports to app callers. A subsequent
iteration encapsulated TMDb in the Network package, but still used a concrete
provider inside the service. Both layouts were superseded by the approved
standalone package and shared contract.

## Compatibility

Existing encoded language strings, observation cases, release evidence, numeric
movie IDs and poster paths retain their existing format. Legacy movie IDs and
artwork are interpreted in TMDb's namespace. The app adapter rejects a result
whose identity cannot be represented in that format. Supporting saved artwork
or identity from a different provider requires a separately approved persistence
design. A definitive identifier miss is distinct from a failed request and
does not authorize title fallback.

## Focused implementation verification

- Run the standalone provider, shared contract, transport, and Network
  contract suites. Verify both default provider composition and substitution.
- Run Common tests for app mapping, matching, recovery, stored values, and
  request history. The focused host and Finder harness covers access-token,
  configuration, poster, and Finder workflows. It excludes unrelated baseline
  test compilation failures only in its disposable copy.
- Build the unsigned host and embedded Finder extension. Resolve the collection,
  recovery, and maintenance probe graphs without running maintenance.
- Verify the coverage reporter accounts for bodyless protocol declarations and
  still requires compiler records for executable code. Full project Validation
  remains a separate approval phase.

Implementation evidence:

- Point 1 renamed the shared packages to `Common` and `Contracts`. The host
  and Finder now reach Network through Common in the Xcode graph. Network's
  provider injection initializer is internal, and its public composition
  selects TMDb.
- After the renames, Network (9), Contracts (3), TMDb (73), HTTPTransport (7),
  the focused Common checks (36 and 5), and the tooling checks (20) passed.
  The unsigned host built with the Finder extension embedded, the Network
  Release build passed, and all three probe graphs resolved.

Earlier implementation evidence:

- The provider substitution and unexpected-error containment checks passed.
  Standalone tests passed for Network (9), Contracts (3), TMDb (73),
  and HTTPTransport (7).
- The unsigned Xcode build passed with the Finder extension embedded. Network
  and its dependencies compiled in Release. Common passed 110 focused tests.
  The disposable harness passed 84 host tests and 25 Finder tests.
- The 20 Python tooling tests passed. The disposable application and three
  probe package graphs resolved all three new packages transitively.
- Focused compiler coverage accounts for every source in all four packages.
  Network was 90.5%, Contracts 95.5%, TMDb 91.9%, and HTTPTransport
  72.1%. The standalone transport remains below the repository's coverage gate.
- Independent review identified an unexpected-error escape at provider
  substitution. The implementation now maps unknown errors to a safe failure
  and preserves cancellation. Its regression test passed. Independent recheck
  and formal Validation remain pending.
