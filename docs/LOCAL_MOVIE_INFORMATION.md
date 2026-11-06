# Explicit identifiers and local movie information

R120-04 implements issue [#18](https://github.com/AIBeCe/MovieFolderPosters/issues/18), part of the 1.2.0
identification sequence. Implementation is in progress on `feature/explicit-identifiers-local-information`;
the [implementation plan](R120-04_IMPLEMENTATION_PLAN.md) records approved scope, checks and phase status.
Formal Validation and Acceptance Testing require separate authorization.

## Sources and opt-in scope

Bracketed identifiers such as `Alien (1979) [tmdb:348]` or `Alien (1979) [imdb:tt0078748]` select a provider
lookup. Arbitrary title numbers are not IDs. TMDb IDs must be positive Int32 values; IMDb IDs use `tt` followed
by 7–10 ASCII digits. Repeated identical IDs collapse; malformed recognized labels and disagreeing IDs cannot
establish a movie. TVDb and Wikidata suffixes remain release-name metadata, not lookup sources.

Settings → Matching Defaults provides three independent options, initially off:

- Read NFO information.
- Read immediate video filenames.
- Read immediate image filenames.

Collection setup/edit can inherit these defaults or supply an override. Source-only saves passively reload
configuration and cancel stale work without scheduling a new visit. Ordinary authorized processing visits
remain the trigger; this feature adds no watcher, polling, recursive scan or background service.

Only selected immediate regular files inside an authorized movie folder are inspected. Symlinks, special files,
replacement races and incomplete captures cannot authorize matching from a collected subset. NFO data is read
within fixed limits. Video and image contents are never opened, and local images are not selected as artwork.
No sidecar or movie-content writes are introduced.

## Supported NFO information

The NFO must be well-formed XML with a `movie` root. Recognized direct fields are `title`, `originaltitle`,
`year`, and labelled `uniqueid` elements with `type="tmdb"` or `type="imdb"`, for example:

```xml
<movie>
  <title>Alien</title>
  <year>1979</year>
  <uniqueid type="tmdb">348</uniqueid>
  <uniqueid type="imdb">tt0078748</uniqueid>
</movie>
```

Identifiers are validated against provider results before assignment. DTDs and entity declarations are
rejected; external resources are never resolved. Malformed, contradictory or unsupported selected information
does not silently establish a movie. UTF-8 and BOM UTF-16 fixtures are covered; UTF-32 is not supported.
Raw NFO contents stay in memory for the current attempt.

## Filename interpretation and limits

Extensions are case insensitive:

| Source | Supported extensions |
| --- | --- |
| Video names | mkv, mp4, m4v, avi, mov, mpg, mpeg, ts |
| Image names | jpg, jpeg, png, webp, heic, tif, tiff, bmp, avif |

Filename stems use the existing conservative release-name parser. Generic names `poster`, `cover`, `folder`,
`fanart`, `sample`, and `trailer` supply no movie identity. The app does not recognize the contents of an image.

Limits per movie folder are inclusive: 1,024 immediate entries, 8 NFO files, 256 KiB per NFO and 1 MiB total
NFO bytes. Every entry except `.` and `..` counts, including hidden/ignored files and directories. Exceeding a limit
makes the capture incomplete, and partial information cannot establish uniqueness.

## Precedence and preservation

All recognized identifiers from the folder and enabled local sources must agree. Without identifiers, title
priority is NFO, video filenames, image filenames, then the folder name. Different equally ranked title/year
interpretations require manual resolution. Lower-ranked titles cannot override a higher-ranked source.
Provider matching retains its conservative title/year, completeness and candidate-budget safeguards.

The freshness path compares a digest of the enabled filenames, identities, metadata and NFO data
before reusing unresolved outcomes and across provider/assignment boundaries. Changed information permits an
unconfirmed assessment to be reconsidered; unchanged information retains existing retry/manual-resolution rules.
Confirmed identities, explicit selections and installed posters remain protected from silent reassignment.
Focused checks and the review of this freshness path are recorded separately in the plan.

Folder details describe **Matched using** a provider-validated identifier, NFO metadata, a video filename, or an
image filename. Genuine conflicting movie information uses the guidance: “The movie information disagrees.
Choose the intended movie manually.” Unchanged conflicts do not enter an automatic retry loop. The existing
Choose Movie flow permits an explicit selection; malformed or incomplete selected information retains separate
manual/inspection guidance rather than claiming the sources disagree.

Settings schema 8, collection outcomes schema 4 and operational cache schema 2 include the new choices.
Existing records use the explicit backup-protected **Migrate Saved Data…** workflow. Normal reads do not migrate
or manufacture missing current fields. See [saved-data migration](STORAGE_SCHEMA_MIGRATION.md).
