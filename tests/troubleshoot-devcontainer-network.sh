#!/usr/bin/env bash
# Diagnose dev container build failures that come from the network.
#
# Run this on the docker host (for example the WSL shell that VS Code uses),
# not inside the dev container:
#
#   bash tests/troubleshoot-devcontainer-network.sh
#
# It runs the same probe suite twice: once on the default bridge network (what
# `docker build` and the dev container use) and once with --network host (the
# WSL host stack). Comparing the two isolates a docker-bridge problem -- MTU
# or NAT -- from a host egress problem. Every line starts with `troubleshoot:`
# so the output is easy to paste back.

set -uo pipefail

IMAGE="${IMAGE:-mcr.microsoft.com/devcontainers/base:ubuntu-24.04}"

if ! command -v docker >/dev/null 2>&1; then
    echo "troubleshoot: docker not found on PATH" >&2
    exit 1
fi

echo "troubleshoot: image=$IMAGE"
printf 'troubleshoot: %-24s mtu=%s\n' "host eth0" "$(cat /sys/class/net/eth0/mtu 2>/dev/null || echo unknown)"
printf 'troubleshoot: %-24s mtu=%s\n' "host docker0" "$(cat /sys/class/net/docker0/mtu 2>/dev/null || echo 'n/a (docker desktop or custom bridge)')"
printf 'troubleshoot: %-24s %s\n' "host default route" "$(ip route show default 2>/dev/null | head -n 1 || echo unknown)"

run_suite() {
    local mode="$1" netarg="${2:-}"

    echo
    echo "################ $mode ################"

    # shellcheck disable=SC2086
    docker run --rm -i $netarg "$IMAGE" bash -s <<'INNER'
set -uo pipefail

. /etc/os-release
DEB="https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb"
KEY="https://packages.microsoft.com/keys/microsoft.asc"
REPO="https://packages.microsoft.com/ubuntu/${VERSION_ID}/prod/dists/${VERSION_CODENAME}/InRelease"

# probe <label> [curl args...]
probe() {
    local label="$1" out stats err rc
    shift

    out="$(curl -sS -o /dev/null --connect-timeout 5 --max-time 20 \
        -w '\nhttp=%{http_code} remote=%{remote_ip} dns=%{time_namelookup}s connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s' \
        "$@" 2>&1)"
    rc=$?

    stats="$(printf '%s\n' "$out" | awk 'NF' | tail -n 1)"
    err=""
    if [ "$rc" -ne 0 ]; then
        err=" err=$(printf '%s\n' "$out" | awk 'NF' | sed '$d' | tail -n 1)"
    fi

    printf 'troubleshoot: %-24s %s%s\n' "$label" "$stats" "$err"
}

echo "-- dns --"
for host in packages.microsoft.com github.com opencode.ai; do
    printf 'troubleshoot: %-24s A=%-15s AAAA=%s\n' "$host" \
        "$(getent ahostsv4 "$host" | awk 'NR==1{print $1}')" \
        "$(getent ahostsv6 "$host" | awk 'NR==1{print $1}')"
done

echo "-- targets --"
probe "deb (default)" "$DEB"
probe "deb (ipv4)" -4 "$DEB"
probe "signing key" "$KEY"
probe "repo InRelease" "$REPO"
probe "github.com" https://github.com
probe "codeload 1 MB" -r 0-1000000 https://codeload.github.com/git/git/tar.gz/refs/tags/v2.43.0
probe "opencode.ai" https://opencode.ai

echo "-- stability (5x opencode.ai, tls latency shows retransmits) --"
for _ in 1 2 3 4 5; do
    probe "  attempt" https://opencode.ai
done

echo "-- link --"
printf 'troubleshoot: %-24s mtu=%s\n' "eth0" "$(cat /sys/class/net/eth0/mtu 2>/dev/null || echo unknown)"
printf 'troubleshoot: %-24s %s\n' "default route" "$(ip route show default 2>/dev/null | head -n 1 || echo unknown)"
INNER
}

run_suite "bridge (what docker build and the dev container use)"
run_suite "host network" "--network host"

cat <<'HINTS'

How to read this:
  host eth0 mtu < container mtu  -> MSS/MTU mismatch; set docker "mtu" to the host value.
  bridge stalls, host suite ok   -> docker bridge path (MTU or NAT), not the host.
  both suites stall              -> host egress: VPN, router, or ISP.
  opencode.ai tls > 1 s          -> packet loss, usually the same MTU mismatch.
  http=404 on InRelease          -> URL wrong for this distro release.
  http=000 with tls= set         -> handshake completed, response dropped (MTU/middlebox).
HINTS
