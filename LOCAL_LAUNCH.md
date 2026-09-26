# Local AList Go backend + web UI

Run from the repository root. See [AGENT.md](AGENT.md) for the local network/proxy rule.

## Why the first launch failed

`public/public.go` uses `//go:embed all:dist`: the frontend under `public/dist` is copied **at Go build time**. A checkout may contain only `public/dist/README.md`; building then succeeds but the resulting binary fails at startup with `index.html not exist`. Copying frontend files *after* building does not fix that binary. In the earlier attempt, `go build ... && nohup ... &` backgrounded the whole build/launch chain, so the subsequent check still used the old binary. Build synchronously first; start the server in a separate command.

## Build and launch (macOS / local checkout)

```sh
# 1. Ensure frontend exists before compiling. This local archive contains dist/index.html.
if [ ! -f public/dist/index.html ]; then
  test -f tmp/alist-web-dist.tar.gz || { echo 'Missing frontend archive: supply a web dist first'; exit 1; }
  tar -xzf tmp/alist-web-dist.tar.gz -C public
fi
test -f public/dist/index.html || exit 1

# 2. Wait for the build to finish successfully; do NOT append '&' here.
go build -tags=jsoniter -o /tmp/alist-local . || exit 1

# 3. Launch separately with proxy variables disabled (see AGENT.md).
env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    -u http_proxy -u https_proxy -u all_proxy \
    NO_PROXY='*' no_proxy='*' \
    nohup /tmp/alist-local server --data ./data > /tmp/alist-local.log 2>&1 < /dev/null &
echo "AList PID: $!"
```

Default UI (per `data/config.json`, `scheme.http_port`): **http://localhost:5244/**. If that config changes, use its configured port instead. Check the actual listener and HTML, not just a build exit code:

```sh
lsof -nP -iTCP:5244 -sTCP:LISTEN
curl --noproxy '*' -fsS http://127.0.0.1:5244/ -o /tmp/alist-response.html
rg -n '<title>|/assets/' /tmp/alist-response.html
# If startup fails, inspect /tmp/alist-local.log.
# Per AGENT.md, verify no active socket connects to 127.0.0.1:7897:
lsof -nP -iTCP | grep alist-local
```

`curl --noproxy '*'` prevents an unrelated shell proxy from returning a misleading 502 when the server isn't listening. Nonfatal startup warnings about unavailable qBittorrent/aria2/Transmission are not the same as the missing-index fatal error.

Stop only the process started above (use its PID, or confirm the command with `lsof`/`ps` before killing it); then check port 5244 is no longer listening. Frontend assets under `public/dist` are ignored by git except `README.md`; avoid deleting that tracked file.
