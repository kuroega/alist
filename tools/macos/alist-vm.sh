#!/bin/sh
# Portable OpenSSH helper for macOS and Linux. See ../vm-ssh.md.
set -eu

usage() {
    cat <<'EOF'
Usage: sh tools/macos/alist-vm.sh [--dry-run] MODE [COMMAND]
Modes:
  shell          Open an interactive VM shell (default).
  exec 'COMMAND' Execute one quoted remote shell command; preserve its exit code.
  doctor         Verify SSH authentication and report the VM toolchain.
  tunnel         Forward local HTTP to the running AList instance.
  debug-tunnel   Forward local HTTP to development AList, plus Delve.
Environment:
  ALIST_VM_HOST                 Default: 10.127.1.109 (also accepts an SSH alias)
  ALIST_VM_USER                 Default: kuroega
  ALIST_VM_SSH_PORT             Default: 22
  ALIST_VM_IDENTITY_FILE        Optional private key path
  ALIST_VM_KNOWN_HOSTS_FILE     Optional known_hosts path
  ALIST_VM_LOCAL_HTTP_PORT      Default: 15244
  ALIST_VM_REMOTE_HTTP_PORT     Default: 5244; debug-tunnel: 5245
  ALIST_VM_LOCAL_DEBUG_PORT     Default: 12345
  ALIST_VM_REMOTE_DEBUG_PORT    Default: 2345
First connect with plain ssh and verify the host fingerprint. This helper
requires an already trusted host key. Tunnel modes stay in the foreground;
press Ctrl-C to close them. No SSH configuration files are modified.
EOF
}

fail() { printf '%s\n' "$*" >&2; exit 2; }
port() {
    case "$2" in ''|*[!0-9]*) fail "$1 must be a port number." ;; esac
    [ "${#2}" -le 5 ] && [ "$2" -ge 1 ] && [ "$2" -le 65535 ] || fail "$1 must be 1..65535."
}

dry_run=false
if [ "${1:-}" = '--dry-run' ]; then dry_run=true; shift; fi
mode=${1:-shell}
if [ "$#" -gt 0 ]; then shift; fi
case "$mode" in help|-h|--help) usage; exit 0 ;; esac
remote_command=
case "$mode" in
    exec) [ "$#" -eq 1 ] && [ -n "$1" ] || fail "exec requires one quoted command."; remote_command=$1 ;;
    shell|doctor|tunnel|debug-tunnel) [ "$#" -eq 0 ] || fail "Unexpected arguments for $mode." ;;
    *) usage >&2; fail "Unknown mode: $mode" ;;
esac

vm_host=${ALIST_VM_HOST:-10.127.1.109}
vm_user=${ALIST_VM_USER:-kuroega}
case "$vm_host" in ''|-*|*[!a-zA-Z0-9._:-]*) fail 'Invalid ALIST_VM_HOST.' ;; esac
case "$vm_user" in ''|-*|*[!a-zA-Z0-9._-]*) fail 'Invalid ALIST_VM_USER.' ;; esac
ssh_port=${ALIST_VM_SSH_PORT:-22}
port ALIST_VM_SSH_PORT "$ssh_port"
set -- -o StrictHostKeyChecking=yes -o ConnectTimeout=10 \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -p "$ssh_port" -l "$vm_user"
if [ -n "${ALIST_VM_IDENTITY_FILE:-}" ]; then
    [ -f "$ALIST_VM_IDENTITY_FILE" ] || fail 'Identity file does not exist.'
    set -- "$@" -i "$ALIST_VM_IDENTITY_FILE" -o IdentitiesOnly=yes
fi
if [ -n "${ALIST_VM_KNOWN_HOSTS_FILE:-}" ]; then
    [ -f "$ALIST_VM_KNOWN_HOSTS_FILE" ] || fail 'Known hosts file does not exist.'
    set -- "$@" -o "UserKnownHostsFile=$ALIST_VM_KNOWN_HOSTS_FILE"
fi
case "$mode" in
    shell) set -- "$@" -t ;;
    exec|doctor) set -- "$@" -o BatchMode=yes -T ;;
    tunnel|debug-tunnel)
        local_http=${ALIST_VM_LOCAL_HTTP_PORT:-15244}
        default_http=5244
        [ "$mode" != debug-tunnel ] || default_http=5245
        remote_http=${ALIST_VM_REMOTE_HTTP_PORT:-$default_http}
        port ALIST_VM_LOCAL_HTTP_PORT "$local_http"
        port ALIST_VM_REMOTE_HTTP_PORT "$remote_http"
        set -- "$@" -N -T -o ExitOnForwardFailure=yes \
            -L "127.0.0.1:$local_http:127.0.0.1:$remote_http"
        if [ "$mode" = debug-tunnel ]; then
            local_debug=${ALIST_VM_LOCAL_DEBUG_PORT:-12345}
            remote_debug=${ALIST_VM_REMOTE_DEBUG_PORT:-2345}
            port ALIST_VM_LOCAL_DEBUG_PORT "$local_debug"
            port ALIST_VM_REMOTE_DEBUG_PORT "$remote_debug"
            [ "$local_debug" != "$local_http" ] || fail 'Local HTTP and debug ports must differ.'
            set -- "$@" -L "127.0.0.1:$local_debug:127.0.0.1:$remote_debug"
        fi
        printf 'Local AList URL: http://127.0.0.1:%s\n' "$local_http" >&2
        ;;
esac
set -- "$@" "$vm_host"
case "$mode" in
    exec) set -- "$@" "$remote_command" ;;
    doctor) set -- "$@" 'set -e; hostname; id; uname -sm; command -v git; go version; if command -v dlv; then dlv version; else printf "Delve is not installed (optional).\n"; fi' ;;
esac
if "$dry_run"; then
    printf 'ssh'; printf ' [%s]' "$@"; printf '\n'
    exit 0
fi
exec ssh "$@"
