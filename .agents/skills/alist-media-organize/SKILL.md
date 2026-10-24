---
name: alist-media-organize
description: Rename AList movie and TV files and matching subtitles to TMDB original-language titles, then organize folders into groups of at most 50 video files. Use for individual folders or recursive collections, including rename-only, reorganization-only, previews, exclusions, and verified recovery.
---

# AList Media Organize

Correct filenames to the work's original-language title, verify the result against TMDB, then organize oversized folders into numbered groups while preserving video/subtitle pairing. Never alter file contents. Preserve existing folder names; reorganization creates range subfolders and moves files into them.

Read [references/project-api.md](references/project-api.md) when connecting to this project's AList backend or accessing TMDB. Keep run-specific inventories and journals in a separate temporary directory, outside the installed skill.

## Establish the scope

Use the current request's target URL/path, recursion, exclusions, and naming preferences. Do not carry collection-specific exclusions forward from previous runs. Default to rename, verify, then reorganize within that scope. Honor explicit rename-only, reorganization-only, and preview requests; a preview never authorizes mutation. For reorganization-only, skip TMDB matching and filename changes, retaining existing identifiers.

For URLs, decode each path component once and reject decoded separators rather than accidentally changing directory boundaries. Confirm the actual directory spelling: simplified/traditional characters and Unicode variants are not interchangeable. If a path is missing, inspect its parent for candidates; ask when the intended directory is ambiguous.

Traverse the entire requested scope with complete pagination. Prune excluded directories before descending: compare exact paths for path exclusions, or exact directory components for bare folder names. Inventory videos, external subtitles, and untouched entries with their names, sizes, and stable provider IDs when available. Do not rename or move from an incomplete listing. Count actual video files in each source directory separately; subtitles do not consume the 50-video allowance. Do not combine unrelated directories or seasons to fill groups.

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

## Verify renames, then reorganize

Refresh and fully re-list affected directories. Compare the expected names, sizes, IDs where available, and counts against the inventory and journal. Confirm subtitle pairing, removal of successfully renamed old names, and preservation of untouched entries and existing directory names.

After renaming, retrieve fresh TMDB details for every distinct work and compare the resulting filename titles to `original_title`/`original_name`. Correct an established mismatch within the same scope and repeat verification. Allow at most two corrective renames per file; stop on persistent failures or uncertain identity and report unresolved items.

After successful rename verification, read [references/reorganization.md](references/reorganization.md) and apply its 50-video grouping rules unless the request is rename-only. Build the move plan from the verified post-rename inventory. Do not move unresolved rename or pairing groups; if that prevents complete grouping, report the directory as incomplete. Reorganization-only uses the same reference directly and does not require TMDB access.

## Report

Report video/subtitle rename and move counts, already-correct or skipped files, exclusions, TMDB links when used, and year/episode-count discrepancies. Include each resulting range folder's video/subtitle counts and the final conservation check. Distinguish filename/location verification from playback or content verification. Do not claim completion for entries that could not be checked.
