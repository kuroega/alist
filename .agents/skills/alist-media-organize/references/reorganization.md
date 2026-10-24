# Reorganize into 50-video folders

## Count and plan

Operate on each eligible source directory independently, after rename verification in the combined workflow. Fully inventory its direct files and relevant subtitle subfolders. Preserve exclusions and existing season/series boundaries; never flatten a recursive collection. Leave directories containing at most 50 direct video files unchanged. Existing range folders are ordinary scoped directories: leave compliant groups in place and never nest or rebalance them merely because this workflow is run again.

For an oversized directory, let N be its actual direct video-file count and W be the number of decimal digits in N. Sort videos by established season and numeric episode identifiers, then numeric end episode for combined files, then full filename as a deterministic tie-breaker. Count alternate versions and combined episodes as individual video files; do not deduplicate, split, renumber, or infer missing episodes. For movies use natural title/year/filename order. If TV ordering cannot be established, leave the affected directory unchanged and resolve the ordering before moving.

Partition that ordered list into consecutive chunks of at most 50 videos. For chunk starting at one-based file position A, set B = min(A + 49, N). Name the destination with A and B zero-padded to W digits, separated by a hyphen. These bounds are file positions in episode order; with gaps or alternate versions they are not necessarily episode numbers. Preserve every actual episode identifier and disclose this distinction when relevant.

Examples:

- N = 1808: `0001-0050`, `0051-0100`, ..., `1801-1808`.
- N = 219: `001-050`, `051-100`, `101-150`, `151-200`, `201-219`.
- N = 132: `001-050`, `051-100`, `101-132`. If the inventory contains episodes 1–131 plus an extra combined 109–110 video, the last group contains 32 videos and may contain 31 subtitles.
- N = 50: no reorganization. N = 51: `01-50`, `51-51`.

Assign every confidently paired external subtitle to its video's destination, preserving its filename, extension, language, forced, and SDH suffixes. Include nested subtitles only when inside the authorized scope and confidently matched. Count shared subtitle objects once; if a subtitle serves videos assigned to different chunks, do not duplicate it or guess a destination. Resolve that directory's plan before mutation. Ambiguous or unmatched subtitle files remain untouched and must be reported; do not claim all pairing is verified. Leave unrelated files and empty directories unchanged.

Record source and destination full paths, file sizes, available provider IDs, ordering keys, pairing, N, W, and expected per-folder counts in the run directory. Check every planned destination against existing entries and other planned moves under provider case/Unicode rules. Do not merge with arbitrary pre-existing range folders or overwrite conflicting files. Reuse a destination only when the run journal and remote inventory establish that it belongs to this same plan. If existing ranges conflict with a new plan, leave that directory unchanged and report the conflict. Validate the complete directory plan before creating folders or moving files.

## Execute and recover

Re-read source and destination directories immediately before mutation; stop and reconcile concurrent changes. Create only the required range folders. Move videos and their paired subtitles with overwrite disabled, preserving basenames and recording each operation's submitted and verified state in an append-only journal. A move batch can partially succeed; an API success response alone is insufficient evidence that every move is visible or complete.

Refresh both locations and fully paginate results to confirm each file at its expected destination with matching size and available stable identity, and absent from its old location. Provider moves may become visible after the response: use bounded polling (for example, up to 20 refreshes over 60 seconds), checking task status if available. Polling is read-only; never blindly resubmit an unconfirmed move. If still unresolved, stop dependent work, retain the journal, and report the exact pending state.

On timeout, partial failure, or restart, reconcile every submitted source/destination pair against remote state before planning the remaining moves. Resume only objects verified to remain at the source with a free destination. Treat a matching destination with an absent source as completed. If both exist, neither exists, or identity differs, stop that group for investigation. Apply the main skill's recovery constraints; never overwrite or delete objects to force completion.

## Verify

Refresh and fully list every affected source, destination, and subtitle directory. Verify:

- Every planned object exists exactly once at its expected path, with its original size and stable ID where the provider preserves IDs across moves.
- Every resulting directory has at most 50 direct video files, and each planned chunk contains the exact ordered video set and associated subtitles.
- Video and subtitle totals across all affected locations equal the pre-move inventory, including untouched and unresolved objects. A video without a subtitle remains valid; do not invent a subtitle to equalize counts.
- No successfully moved file remains at its old path; excluded and unrelated entries retain their paths and identities. No existing directories or file contents changed.

Save the sanitized final inventory and per-file verification results outside the skill. Report actual folder counts and unresolved objects; do not equate a successful request or a matching aggregate count with verified completion.
