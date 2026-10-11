# Network service and conservative matching

Phase 4 adds a local SwiftPM package, `Packages/Network`, and an application-owned `MovieMatcher`.
Both use Swift 6 with immutable Sendable values. There are no third-party dependencies.
The host and its unit-test target link Network; Finder integration remains a later phase.

## Service boundary

Network owns transport, TMDb request construction, response decoding, poster retrieval, and network errors.
It returns metadata and image Data. It never writes files, stores credentials, chooses movies, or sets icons.
The application owns movie matching and will coordinate Network with FileSystem and Persistence later.
The package itself grants no sandbox access. The host enables outgoing-network access; extension permissions
are unchanged until automatic processing is approved.

Public API:

```swift
let client = TMDbClient(token: try TMDbAccessToken(accessToken))
let search = try await client.searchMovies(title: title, year: year)
let match = MovieMatcher().match(title: title, year: year, search: search)
if case let .matched(movie) = match, let path = movie.posterPath {
    let posterData = try await client.downloadPoster(path: path)
    // The later processing workflow decides whether and where to assign this image.
}
```

`accessToken` is supplied by the caller in memory. No default credential, source-code credential, or committed
credential file exists. The token's textual descriptions are redacted, and provider errors omit response bodies.
This phase adds no credential-entry UI or persistent credential storage. Host credential configuration, including
Keychain storage if persistence is needed, belongs to the later configuration work. No real token was required
for the controlled tests, and no live TMDb request was made.

## TMDb behavior

Search uses `GET /3/search/movie`, an encoded title, optional year, `include_adult=false`, and English response
language. Bearer authorization is an HTTP header, never a URL query parameter. The first page is decoded into
IDs, title, original title, optional release year, and poster path. Invalid IDs, invalid dates, malformed data,
and provider failures produce typed errors. Empty or missing release dates map to an unknown year.

A `MovieSearchResult` includes `hasMorePages`. Additional pages are not fetched automatically in this phase.
An incomplete search cannot establish a unique match, so callers receive an unresolved result.

Poster retrieval requests TMDb's configuration, validates the image origin and supported `w500` size, then
constructs the image URL from a validated filename. Image requests carry no bearer token. The result must be
a decodable PNG or JPEG. Downloaded data stays in memory, with no filesystem changes or persistent caching.

The default transport uses an ephemeral URLSession, finite timeouts, no cookies or URL cache, and declines
redirects. Responses are bounded to 10 MiB. Cancellation propagates before and after transport operations.
Interrupted or oversized downloads cancel their underlying tasks, and transport teardown invalidates its session.
Configuration rejects unexpected URL credentials, ports, queries, and fragments. Image validation requires
complete image data before accepting decoded pixels.
Rate-limit responses expose Retry-After without retrying automatically; retry policy belongs to processing.

## Matching rules

1. Reject empty or non-alphanumeric query titles and years outside 1888 through 2099.
2. Return unresolved for a search with more pages.
3. Normalize case, diacritics, punctuation separators, and repeated whitespace. Preserve numbers and words.
4. Compare the complete normalized query with the returned title or original title.
5. Require exact release-year agreement when the query includes a year. Unknown years cannot satisfy it.
6. Require a unique movie ID. Identical duplicate records do not create a tie; conflicting records remain unresolved.
7. Check poster availability only after identity is resolved. A missing poster cannot break an identity tie.

There is no fuzzy similarity, popularity ranking, approximate-year acceptance, or automatic first-result choice.
Alternative titles not present in the returned title/original title are unresolved. Additional detail requests or
scoring should follow concrete examples and separate approval. TMDb searches translated and alternative titles,
but that alone does not establish that a returned candidate matches the folder.

## Verification

Run the package suite and the application matching fixtures:

```sh
rtk proxy swift test --package-path Packages/Network
rtk proxy scripts/test-matching.sh
rtk proxy xcodebuild -project MovieFolderPosters/MovieFolderPosters.xcodeproj -scheme MovieFolderPosters \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/MovieFolderPosters-Phase4 build-for-testing
```

The matching script compiles the actual application source and its actual Xcode test fixtures in a disposable
SwiftPM harness with the production Network dependency. This avoids the hosted Xcode result-finalization problem
observed in Phase 3. Xcode compilation is verified separately; the harness does not exercise Finder or AppKit.

Matching TDD began with four basic tests: three failed against a stub, then all passed. Expanded tests produced
14 assertion failures before normalization, international title comparison, missing-poster handling, duplicate
handling, query validation, and incomplete-search refusal were implemented.

Final verification on 2026-10-11:

- Network: 21 test functions and 39 fixture cases passed, including controlled URLSession behavior.
- Matching: 19 test functions and 25 fixture cases passed.
- Signed normal and test builds passed. The final app signature and outgoing-network entitlement were verified.
- Independent review returned PASS after fixing five findings involving transport lifetime/cancellation,
  configuration origin validation, truncated image acceptance, behavioral test coverage, and pagination consistency.
- Swift source and test files meet the 120-character line limit; whitespace and shell syntax checks passed.

Live authentication, live search results, provider availability, and real-poster rendering remain unverified.
No Phase 5 persistence or automatic processing was implemented.

## References

- [TMDb search](https://developer.themoviedb.org/reference/search-movie)
- [TMDb bearer authentication](https://developer.themoviedb.org/docs/authentication-application)
- [TMDb configuration](https://developer.themoviedb.org/reference/configuration-details)
- [TMDb image URLs](https://developer.themoviedb.org/docs/image-basics)
- [Apple URLSession](https://developer.apple.com/documentation/foundation/urlsession)
