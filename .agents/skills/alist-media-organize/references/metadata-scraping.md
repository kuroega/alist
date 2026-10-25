# TMDB metadata scraping compatibility

## Verify both identity and parsing

The acceptance criteria are the correct TMDB work, the correct episode mapping, and a filename the target scraper can parse. A matching original-language title satisfies only the first criterion. Confirm the original title, series start year, TMDB ID, and relevant season metadata before proposing names.

Use `Original Name (Series Year) S01E01 - Optional Suffix.ext` for TV and `Original Title (Year).ext` for movies. Preserve dub, release, subtitle, and accessibility labels after the identifying tokens. Do not leave bare TV numbers such as `0001`, assume a range folder supplies a season, or insert a season marker merely to make an uncertain mapping look valid. Specials use TMDB's actual season and episode identifiers, not an assumed main-season sequence.

When the consuming application or its source is available, inspect or exercise its filename parser. Check that it extracts the intended title, year, season, and episode without absorbing dub labels or range folders into the title. A source-code inspection or format check is useful evidence but is not an end-to-end scraper test. Do not change application code, folders, or scraper settings as part of a filename-only task. Add provider-ID tags only if the target scraper documents support for that exact syntax; a tag cannot repair incorrect episode numbering.

## Resolve distribution cuts before naming

Retrieve the relevant TMDB season and episode metadata; absolute anime and dubbed release numbers may diverge from TMDB numbering. Compare episode titles, plots, air dates, and known special-length episodes around suspected boundaries. A directory's file count is not a season episode count.

If metadata alone is insufficient, inspect read-only media metadata and a small sample of title cards or scenes around the suspected boundary. Use existing authorized access; keep signed media URLs and authentication out of logs. Duration can identify a possible split but does not prove episode identity. Confirm anchors before and after a proposed offset and check for additional splits, omissions, reordered episodes, or combined releases throughout the affected span. Do not extrapolate one discrepancy across unrelated seasons or folders.

Record an explicit mapping for every affected file: original filename and source number, TMDB series ID, season, episode or episode range, part if applicable, and the evidence supporting that mapping. Correct identifiers only when this evidence establishes the correspondence. If it does not, preserve the affected files unchanged and report the precise ambiguity while continuing resolved groups.

For multiple files containing parts of one TMDB episode, retain both files and use the same season/episode token with distinct part suffixes. For example, when supported by the target scraper:

```text
Original Name (1996) S01E11 - Mandarin Dub - pt1.mp4
Original Name (1996) S01E11 - Mandarin Dub - pt2.mp4
Original Name (1996) S01E12 - Mandarin Dub.mp4
```

This illustrates a verified distribution split, not a fixed mapping for any series. Check the target application's handling of parts: recognizing both files as the same episode does not prove seamless stacking or playback. If the app's required naming is unknown, disclose that limitation rather than promise part support. Do not merge, split, duplicate, or re-encode media. Keep subtitles attached to the correct physical part, and treat the related parts and subtitles as one execution group for recovery.

For a file spanning multiple TMDB episodes, use a multi-episode token such as `S01E01-E02` only when both the content mapping and target parser support it. Otherwise leave that group unresolved instead of assigning a misleading single episode.

## Acceptance checks

Before mutation, check every planned filename for parsed identity and season/episode values, collisions, and preservation of relevant suffixes. An existing original-language filename with an unrecognized episode token is a rename candidate, not an already-correct no-op.

After mutation, verify each remote filename, size, stable ID where available, source-name removal, and subtitle pairing. Recheck fresh TMDB work details and the recorded episode mapping. Confirm every physical file is conserved; two parts of one TMDB episode remain two video files for the 50-video grouping limit.

Report separately what was established: TMDB identity and numbering, filename-parser compatibility, actual scraper refresh results if tested, and any sampled media evidence. Do not equate a syntactically valid `S01E##` token with verified content correspondence, or a file listing with successful metadata scraping.
