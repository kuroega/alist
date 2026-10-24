# Project connections and API details

## Existing access

Resolve repository paths from the project root, not the skill directory.

- Read `tools/vm-ssh.md` for VM access. The existing alias is `alist-vm`; verify the current connection instead of assuming an old LAN address is permanent.
- Use the AList endpoint supplied in the current request. This project's prior backend was `http://10.127.1.109:5244`.
- The project `.env` can supply `ALIST_ADMIN_PASSWORD`; `admin` was the previously used account. Confirm the endpoint belongs to this project before sending its credential.
- TMDB credentials are available from environment variable `TMDB_API_KEY` or `tvos/AListTV/Resources/TMDB.local.plist`, field `APIKey`. Check `tvos/AListTV/Core/TMDB/TMDBClient.swift` for current configuration behavior. Identify whether the supplied credential is a v3 key or v4 read token; do not infer its type solely from its length.

Read secrets in memory. Do not include them in process arguments, reports, journals, or version-controlled files. Keep inventories limited to required non-secret fields; omit signed URLs and full authentication responses. Parse environment/plist data rather than executing it as shell code.

Native `curl` worked in this environment when Python's HTTP client reported `No route to host`. If that recurs, use subprocess argument arrays and supply curl configuration through stdin. Escape curl-config values separately from JSON bodies; never interpolate filenames or credentials into shell programs. Retain normal host-key and TLS verification.

## AList

Responses have an application-level `code`; check it even when HTTP status is 200. Confirm changed contracts in this checkout's `server/handles/fs*.go`.

| Operation | Request | Success handling |
|---|---|---|
| Login | `POST /api/auth/login` with `username`, `password` | Read `data.token`; use it directly as the AList `Authorization` value. |
| List | `POST /api/fs/list` with `path`, `password`, `page`, `per_page`, `refresh` | Accumulate `data.content` until `data.total` is satisfied. |
| Rename | `POST /api/fs/rename` with full source `path`, destination basename `name`, `overwrite: false` | Require application `code: 200`; journal the confirmed change. |
| Create directory | `POST /api/fs/mkdir` with full `path` | Require application `code: 200`, then verify the directory exists. |
| Move | `POST /api/fs/move` with `src_dir`, `dst_dir`, `names` (basenames), `overwrite: false` | Check application `code: 200`; verify every source/destination pair, including on partial failure. |
| Health | `GET /ping` | `pong` verifies server response, not storage-provider availability. |

Use bounded pages, such as 100 entries, and stop on errors or non-progress before claiming inventory completeness. If using `per_page: 0`, confirm this server actually returns all entries. AList directory passwords and account passwords are separate inputs.

A destination name must be a single valid component. AList renames and moves are not transactions across video/subtitle pairs; move batches can partially succeed. Provider listings may lag successful moves. Use refreshed, fully paginated source/destination verification and bounded polling as described in [reorganization.md](reorganization.md); rely on the journal and remote state for recovery.

## TMDB

API base: `https://api.themoviedb.org/3`. A v3 API key uses the `api_key` query parameter; a v4 read token uses `Authorization: Bearer ...`. URL-encode query parameters, honor rate limits, and keep credential-bearing URLs out of logs.

| Resource | Purpose |
|---|---|
| `/search/movie`, `/search/tv` with `query` | Find candidates; search results alone do not settle identity. |
| `/movie/{id}` | Read `original_title`, `original_language`, `release_date`, `production_countries`. |
| `/tv/{id}` | Read `original_name`, `original_language`, `first_air_date`, `origin_country`, `seasons`. |
| `/tv/{id}/season/{number}` | Verify season/episode identifiers and distinguish numbering from cut differences. |
| `/movie/{id}/credits`, `/tv/{id}/credits` | Check cast/crew when required for identity. |

Use `https://www.themoviedb.org/movie/{id}` or `https://www.themoviedb.org/tv/{id}` as evidence links. When using the website, establish the original-language title rather than assuming the page's localized heading is the original.

## Minimal run evidence

Keep a sanitized before/after inventory, a source-to-destination rename/move plan with TMDB evidence when renaming, an append-only success/recovery journal, and per-file verification results. These may be separate files or one coherent run record; they must be sufficient to distinguish no-ops, successes, partial failures, and unresolved entries. Do not reuse collection-specific mappings or fixed expected counts from previous runs.
