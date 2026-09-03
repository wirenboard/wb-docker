#!/usr/bin/env bash
#
# Build the WB Docker package set.
#
# Scope:
#   1. Download official docker-ce, docker-ce-cli, containerd.io,
#      docker-compose-plugin from download.docker.com.
#   2. For docker-ce ONLY:
#        a. inject the WB overlay tree from repack/overlay/ into the .deb's
#           data archive (currently: a daemon.json template), regenerate
#           DEBIAN/md5sums for new files;
#        b. inject the WB setup snippet (repack/postinst-snippet.sh) into the
#           existing docker-ce DEBIAN/postinst, so `apt install docker-ce`
#           seeds /mnt/data layout, symlinks, daemon.json and iptables-legacy
#           BEFORE debhelper's auto-generated start of docker.service;
#        c. inject the WB teardown snippet (repack/postrm-snippet.sh) into the
#           docker-ce DEBIAN/postrm, so `apt purge docker-ce` stops containerd
#           and removes the WB symlinks before the operator wipes Docker state
#           on /mnt/data (a dangling /var/lib/containerd would wedge any other
#           containerd installed later);
#        d. ship the same setup snippet as /usr/bin/wb-docker-setup, for applying
#           the WB layout by hand where postinst declines to do it;
#        e. append `docker-compose-plugin` to Depends — so a single
#           `apt install docker-ce` against our local apt-repo brings in the
#           compose plugin alongside the daemon;
#        f. bump Version in DEBIAN/control with the WB suffix;
#        g. repack with dpkg-deb --root-owner-group.
#   3. docker-ce-cli, containerd.io and docker-compose-plugin are mirrored
#      as-is from src/ into artifacts/ — same upstream filename, same Version,
#      byte-identical contents. They live in the WB apt repo so Docker installs
#      entirely from WB (a stock WB controller has no upstream Docker repo
#      configured) and docker-ce's strict versioned Depends resolve there.
#
# The overlay (see repack/overlay/) ships:
#   /usr/share/wb-docker/daemon.json   — daemon.json template, seeded into
#                                        /mnt/data/etc/docker/ on install.
#   /etc/systemd/system/containerd.service.d/mnt-data.conf — orders containerd
#                                        after /mnt/data is mounted.
#
# Requires: wget, dpkg-deb, md5sum (or gmd5sum from coreutils on macOS), tar.
# On macOS: `brew install wget dpkg coreutils`; all stock on Debian.
# Run from repo root: bash repack/repack-docker-ce.sh

set -euo pipefail

# Single source of truth: auto-source versions.env from the repo root (one level
# up from this script) when present, so a MANUAL run uses the same versions as CI
# instead of silently drifting from the fallback defaults below. CI also sources
# it first; re-sourcing the same file is idempotent. The "${VAR:-default}" lines
# below remain only as a last-resort fallback if versions.env is absent.
_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "${_REPO_ROOT}/versions.env" ]; then
    set -a; . "${_REPO_ROOT}/versions.env"; set +a
fi

# --- Inputs (override via env) ----------------------------------------------
DOCKER_CE_VERSION="${DOCKER_CE_VERSION:-29.5.2}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.2.4}"
COMPOSE_VERSION="${COMPOSE_VERSION:-5.1.4}"
SUITE="${SUITE:-trixie}"          # bullseye | trixie  (bookworm intentionally skipped — WB jumps bullseye → trixie)

# DEBIAN_NUM is derived from SUITE — no override on purpose. A mismatch
# (e.g. SUITE=trixie + DEBIAN_NUM=11) would produce a non-existent upstream
# filename and surface only as a 404 several MB later.
case "${SUITE}" in
    bullseye) DEBIAN_NUM=11 ;;
    trixie)   DEBIAN_NUM=13 ;;
    *) echo "[fail] Unknown SUITE: ${SUITE}" >&2; exit 1 ;;
esac
ARCH="${ARCH:-armhf}"             # armhf | arm64
case "${ARCH}" in
    armhf|arm64) ;;
    *) echo "[fail] Unknown ARCH: ${ARCH} (expected armhf|arm64)" >&2; exit 1 ;;
esac

# WB_SUFFIX is interpolated into both filenames and DEBIAN/control's
# Version: line. Restrict it up front so a typo (e.g. "wb100" without the
# leading "+") fails fast with a clear message instead of producing a
# broken Version string.
WB_SUFFIX="${WB_SUFFIX:-+wb100}"  # WB downstream marker for docker-ce only.
                                  # Leading "+" keeps the suffix inside
                                  # debian-revision
                                  # (1~debian.11~bullseye+wb100), leaving the
                                  # upstream-version field untouched — the
                                  # canonical downstream convention. The
                                  # "1xx" numbering is a counter for WB-side
                                  # iterations on top of the same upstream
                                  # docker-ce: +wb100 first ship, +wb101
                                  # next overlay change, etc. Reset to
                                  # +wb100 when the upstream version is
                                  # bumped. Reserved ranges +wb2xx and
                                  # +wb9xx left for future experimental and
                                  # hotfix streams.
WB_SUFFIX_RE='^\+wb[0-9]+$'
if ! [[ "${WB_SUFFIX}" =~ ${WB_SUFFIX_RE} ]]; then
    echo "[fail] WB_SUFFIX must match '+wb<digits>' (got: '${WB_SUFFIX}')" >&2
    exit 1
fi

# --- Layout ------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${HERE}/src"
OUT_DIR="${HERE}/out"
ART_DIR="${HERE}/artifacts"
OVERLAY_DIR="${HERE}/overlay"
POSTINST_SNIPPET="${HERE}/postinst-snippet.sh"
POSTRM_SNIPPET="${HERE}/postrm-snippet.sh"

# Resolve the md5 tool. GNU coreutils ships `md5sum` on Linux; on macOS
# `brew install coreutils` exposes it as `gmd5sum` (the unprefixed name lives
# under libexec/gnubin, not on PATH by default). Accept either so the macOS
# quick start works without extra PATH surgery.
MD5SUM="$(command -v md5sum || command -v gmd5sum || true)"
if [[ -z "${MD5SUM}" ]]; then
    echo "[fail] need md5sum or gmd5sum on PATH (macOS: 'brew install coreutils' provides gmd5sum)" >&2
    exit 1
fi

DOCKER_CE_UPSTREAM="${DOCKER_CE_VERSION}-1~debian.${DEBIAN_NUM}~${SUITE}"
CONTAINERD_UPSTREAM="${CONTAINERD_VERSION}-1~debian.${DEBIAN_NUM}~${SUITE}"
COMPOSE_UPSTREAM="${COMPOSE_VERSION}-1~debian.${DEBIAN_NUM}~${SUITE}"
BASE_URL="https://download.docker.com/linux/debian/dists/${SUITE}/pool/stable/${ARCH}"

# --- Helpers ----------------------------------------------------------------

# Fetch one upstream .deb. `-nv` keeps the line count low but still prints
# the URL and any HTTP error to stderr — so a wrong DOCKER_CE_VERSION shows
# up as a clear "404 Not Found" instead of an opaque empty file. wget exits
# non-zero on errors and `set -e` propagates that.
fetch_one() {
    local name="$1" upstream="$2"
    local fname="${name}_${upstream}_${ARCH}.deb"
    local url="${BASE_URL}/${fname}"

    if [[ -f "${SRC_DIR}/${fname}" ]]; then
        echo "[cached  ] ${fname}"
        return 0
    fi

    echo "[download] ${url}"
    if ! wget -nv -O "${SRC_DIR}/${fname}" "${url}"; then
        rm -f "${SRC_DIR}/${fname}"
        echo "[fail    ] could not download ${url}" >&2
        exit 1
    fi
}

# Patch DEBIAN/control: Version: 5:<upstream> -> Version: 5:<upstream><WB_SUFFIX>.
#
# docker-ce ships with a Debian epoch `5:` since 2017, when Docker Inc.
# renumbered their releases from 1.13.x to a year-based scheme (17.03.x and
# onward). Without the epoch dpkg would compare "17.03" against "1.13"
# character-by-character and decide the new release is older; the `5:`
# prefix overrides that. The epoch has been stable for the entire 17.x/
# 18.x/19.x/20.x/24.x/26.x/29.x lifetime, so we anchor on it explicitly.
# If upstream ever drops or bumps it, the up-front `grep -Fqx` fails loudly
# with a clear "format changed" message instead of silently writing
# nothing.
patch_version() {
    local control="$1" upstream="$2"
    local old_line="Version: 5:${upstream}"
    local new_line="Version: 5:${upstream}${WB_SUFFIX}"

    # `grep -Fqx`: fixed-string, whole-line match. Without -F the version
    # would be treated as a regex and dots would match any character,
    # turning the "format changed?" guard into a loose check.
    if ! grep -Fqx -- "${old_line}" "${control}"; then
        echo "[fail    ] expected '${old_line}' in ${control}; upstream Version format changed?" >&2
        return 1
    fi

    echo "[version ] ${new_line#Version: }"
    # Escape regex metachars in the sed pattern so a literal dot in the
    # version doesn't match arbitrary characters. The replacement side
    # stays literal because our version strings don't contain `&`, `\` or
    # the chosen sed delimiter `|`.
    local pattern="${old_line//./\\.}"
    sed -i.bak "s|^${pattern}\$|${new_line}|" "${control}"
    rm -f "${control}.bak"
    grep -Fqx -- "${new_line}" "${control}"
}

# Inject the WB overlay tree into the unpacked docker-ce stage:
#   - tar | tar to preserve file modes
#   - append md5sums for newly added files
#   - re-sort DEBIAN/md5sums (dpkg does not require sort, but it keeps the
#     file diffable against upstream).
inject_overlay() {
    local stage="$1" overlay="$2"

    (cd "${overlay}" && tar cf - .) | (cd "${stage}" && tar xpf -)

    local md5sums="${stage}/DEBIAN/md5sums"
    (
        cd "${overlay}"
        find . -type f -print \
            | sed 's|^\./||' \
            | sort \
            | while read -r path; do
                  ( cd "${stage}" && "${MD5SUM}" "${path}" )
              done
    ) >> "${md5sums}"

    sort -k2 -o "${md5sums}" "${md5sums}"
}

# The snippet doubles as the operator-facing command; it dispatches on argv.
install_setup_command() {
    local stage="$1" snippet="$2"
    local dest="usr/bin/wb-docker-setup"

    mkdir -p "${stage}/usr/bin"
    install -m 0755 "${snippet}" "${stage}/${dest}"
    ( cd "${stage}" && "${MD5SUM}" "${dest}" ) >> "${stage}/DEBIAN/md5sums"
    echo "[command ] /${dest}"
}

# Inject a WB snippet into one of docker-ce's maintainer scripts, right after the
# first `set -e` line, wrapped in BEGIN/END markers. Placement matters for the
# postinst: it must run before debhelper's auto-generated start of
# docker.service, so the daemon comes up already pointing at /mnt/data.
#
# The snippets are guarded on their own $1 (`configure`, `purge`, `install`), so
# rollback paths stay no-ops. Asserts a `set -e` line exists — a future upstream
# dropping it fails loudly here instead of silently appending nowhere; a missing
# script is synthesized.
inject_snippet() {
    local stage="$1" name="$2" snippet="$3" label="$4"
    local script="${stage}/DEBIAN/${name}"

    if [[ ! -f "${snippet}" ]]; then
        echo "[fail] ${name} snippet missing at ${snippet}" >&2
        return 1
    fi

    # The upstream script already has a shebang; keep everything after ours.
    local body
    body=$(mktemp)
    sed -e '1{/^#!/d;}' "${snippet}" > "${body}"

    if [[ ! -f "${script}" ]]; then
        {
            echo '#!/bin/sh'
            echo 'set -e'
            echo
            echo "# --- BEGIN wb-docker ${label} ---"
            cat "${body}"
            echo "# --- END wb-docker ${label} ---"
            echo
            echo 'exit 0'
        } > "${script}"
        chmod 0755 "${script}"
        rm -f "${body}"
        return 0
    fi

    if ! grep -q '^set -e' "${script}"; then
        echo "[fail] no 'set -e' line in ${script}; refusing to inject blindly" >&2
        rm -f "${body}"
        return 1
    fi

    local tmp
    tmp=$(mktemp)
    awk -v body_file="${body}" -v label="${label}" '
        BEGIN { injected = 0 }
        {
            print
            if (!injected && $0 ~ /^set -e/) {
                print ""
                print "# --- BEGIN wb-docker " label " ---"
                while ((getline line < body_file) > 0) print line
                close(body_file)
                print "# --- END wb-docker " label " ---"
                injected = 1
            }
        }
        END { if (!injected) exit 1 }
    ' "${script}" > "${tmp}" || {
        echo "[fail] failed to locate '^set -e' insertion point in ${script}" >&2
        rm -f "${tmp}" "${body}"
        return 1
    }
    mv "${tmp}" "${script}"
    chmod 0755 "${script}"
    rm -f "${body}"
}

# Append a new dependency to the Depends: line in DEBIAN/control. Asserts the
# field is single-line (upstream docker-ce keeps it that way; if a future
# upstream rewraps it onto multiple lines, this assertion catches the change
# instead of silently corrupting the file).
append_depends() {
    local control="$1" new_dep="$2"
    local depends_lines
    depends_lines=$(grep -c '^Depends:' "${control}" || true)
    if [[ "${depends_lines}" -ne 1 ]]; then
        echo "[fail] expected exactly one 'Depends:' line in ${control}, found ${depends_lines}"
        return 1
    fi
    sed -i.bak "s|^\(Depends:.*\)\$|\1, ${new_dep}|" "${control}"
    rm -f "${control}.bak"
    grep -q "^Depends:.*${new_dep}" "${control}"
}

# docker-ce: unpack, layer the WB overlay tree, inject the WB postinst and
# postrm snippets, append the docker-compose-plugin Depends, bump Version,
# repack.
repack_docker_ce() {
    local upstream="$1"
    local src="${SRC_DIR}/docker-ce_${upstream}_${ARCH}.deb"
    local stage="${OUT_DIR}/docker-ce"

    echo "[repack  ] docker-ce"
    rm -rf "${stage}"
    dpkg-deb -R "${src}" "${stage}"

    install_setup_command "${stage}" "${POSTINST_SNIPPET}"
    inject_overlay "${stage}" "${OVERLAY_DIR}"
    inject_snippet "${stage}" postinst "${POSTINST_SNIPPET}" "setup" \
        || { echo "[fail    ] postinst injection failed" >&2; exit 1; }
    inject_snippet "${stage}" postrm   "${POSTRM_SNIPPET}"   "teardown" \
        || { echo "[fail    ] postrm injection failed" >&2; exit 1; }
    append_depends "${stage}/DEBIAN/control" \
        "docker-compose-plugin (>= ${COMPOSE_VERSION})" \
        || { echo "[fail    ] Depends patch failed" >&2; exit 1; }
    patch_version "${stage}/DEBIAN/control" "${upstream}" \
        || { echo "[fail    ] Version patch failed for docker-ce" >&2; exit 1; }

    # --root-owner-group: build env runs as the user; without this flag the
    # tarball would carry uid=501 and dpkg --install would refuse it.
    # Output is a directory: dpkg-deb auto-derives the canonical filename
    # `${Package}_${Version}_${Architecture}.deb` from DEBIAN/control, so the
    # WB suffix is preserved in the artifact name.
    dpkg-deb --root-owner-group -b "${stage}" "${ART_DIR}/" >/dev/null

    echo "[ok      ] docker-ce${WB_SUFFIX}"
}

# Mirror an upstream .deb as-is: same filename, same Version, identical bytes.
# Lives in our apt repo so Docker installs entirely from WB (the controller has
# no upstream Docker repo) and docker-ce's strict versioned Depends resolve there.
mirror_one() {
    local name="$1" upstream="$2"
    local fname="${name}_${upstream}_${ARCH}.deb"

    cp -f "${SRC_DIR}/${fname}" "${ART_DIR}/${fname}"
    echo "[mirror  ] ${fname}"
}

# --- Entry point ------------------------------------------------------------

main() {
    mkdir -p "${SRC_DIR}" "${OUT_DIR}" "${ART_DIR}"

    fetch_one docker-ce              "${DOCKER_CE_UPSTREAM}"
    # docker-ce-cli is released by Docker Inc. in lockstep with docker-ce
    # itself and shares the same upstream version string — that's why
    # DOCKER_CE_UPSTREAM is reused for it.
    fetch_one docker-ce-cli          "${DOCKER_CE_UPSTREAM}"
    fetch_one containerd.io          "${CONTAINERD_UPSTREAM}"
    fetch_one docker-compose-plugin  "${COMPOSE_UPSTREAM}"

    repack_docker_ce "${DOCKER_CE_UPSTREAM}"
    mirror_one docker-ce-cli         "${DOCKER_CE_UPSTREAM}"
    mirror_one containerd.io         "${CONTAINERD_UPSTREAM}"
    mirror_one docker-compose-plugin "${COMPOSE_UPSTREAM}"

    echo
    echo "Artefacts:"
    ls -lh "${ART_DIR}"
}

main "$@"
