---
name: alist-media-rename
description: Rename or correct AList movie and TV filenames and matching subtitles to TMDB original-language titles. Use for individual folders or recursive collections with exclusions and post-rename verification.
---

# AList Media Rename

Correct filenames to the work's original-language title, verify the result against TMDB, and preserve video/subtitle pairing. This skill changes filenames; folder names and file contents stay unchanged unless the user requests otherwise.

Read [references/project-api.md](references/project-api.md) when connecting to this project's AList backend or accessing TMDB. Keep run-specific inventories and journals in a separate temporary directory, outside the installed skill.

## Establish the scope

Use the current request's target URL/path, recursion, exclusions, and naming preferences. Do not carry collection-specific exclusions forward from previous runs. A rename request authorizes changes within that scope; a preview request does not authorize mutation.

For URLs, decode each path component once and reject decoded separators rather than accidentally changing directory boundaries. Confirm the actual directory spelling: simplified/traditional characters and Unicode variants are not interchangeable. If a path is missing, inspect its parent for candidates; ask when the intended directory is ambiguous.

Traverse the entire requested scope with complete pagination. Prune excluded directories before descending: compare exact paths for path exclusions, or exact directory components for bare folder names. Inventory videos, external subtitles, and untouched entries with their names, sizes, and stable provider IDs when available. Do not rename from an incomplete listing.

## Match works to TMDB

Search using existing titles, aliases, years, and folder context, then retrieve the selected movie or series details. Distinguish live action from animation, remakes, sequels, and movies bundled with TV seasons. Confirm identity using dates, country, language, and cast or director evidence as needed; verify credits when the user's request specifies a director.

Use movie `original_title` or TV `original_name`, not the translated display title or a guessed transliteration. Cross-check that the original language and country fit the identified work. For coproductions or an original title that conflicts with the requested language, resolve the discrepancy instead of inventing a translation.

Retrieve season metadata to establish season/episode numbering. An episode-count mismatch can indicate a different distribution cut: retain existing identifiers and report the discrepancy rather than inferring missing episodes or renumbering by count. If identity or numbering remains uncertain, leave those files unchanged, seek focused clarification, and continue independently resolved groups.

If TMDB is inaccessible, preserve the inventory and proposed matches without applying unverified renames. Use an existing credential or accessible TMDB pages; do not require the user to buy a service.

## Prepare filenames

- Replace the title while retaining existing season/episode identifiers, subtitle language/forced/SDH suffixes, extensions, and technical release information.
- For files containing only episode numbers, add the verified series original name and explicit season/episode identifiers: `Original Name (Series Year) S01E01.ext`. Use the series start year for this format, including later seasons.
- For movies, use `Original Title (Year).ext`. Preserve existing years by default and disclose TMDB discrepancies; correct years when the user requests that correction.
- Pair subtitles by the full video stem plus any recognized subtitle suffix. For nested seasons and differently named subtitles, use evidence sufficient to establish the same episode; do not pair by a broad title prefix. Leave ambiguous pairs unchanged together.
- Keep TMDB spelling and punctuation where the storage provider permits it. Document any provider-required replacement of forbidden characters; retain the exact original title in the match record.

Record each proposed source, destination, size/ID, TMDB type/ID, original title, evidence URL, and optional season/episode. Check all destinations against the entire directory, including unchanged files. Reject collisions, invalid basenames, excluded paths, and paths outside scope; account for provider case and Unicode behavior. Treat an already-correct filename as a no-op.

## Apply and recover

Re-read affected directories before mutation and reconcile changes since inventory. Use single-file renames with overwrite disabled and append each confirmed success to a journal immediately. Keep each video and its subtitles together as an execution group.

If a response times out, inspect both source and destination before retrying. Resume from the journal and verified remote state, not by replaying the original plan blindly. If a group partially fails, restore confirmed changes in reverse order only when the source identity is established and the old destination is free. Otherwise stop that group and report its exact state; continue only independent resolved groups. Never overwrite or delete an object to force recovery.

## Verify and report

Refresh and fully re-list affected directories. Compare the expected names, sizes, IDs where available, and counts against the inventory and journal. Confirm subtitle pairing, removal of successfully renamed old names, and preservation of untouched entries and directory names.

After renaming, retrieve fresh TMDB details for every distinct work and compare the resulting filename titles to `original_title`/`original_name`. Correct an established mismatch within the same scope and repeat verification. Allow at most two corrective renames per file; stop on persistent failures or uncertain identity and report unresolved items.

Report video/subtitle rename counts, already-correct or skipped files, exclusions, TMDB links, and year/episode-count discrepancies. Distinguish filename verification from playback or content verification. Do not claim completion for entries that could not be checked.
