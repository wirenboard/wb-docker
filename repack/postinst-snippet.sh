#!/bin/sh
# Wiren Board Docker integration: /mnt/data layout, symlinks, daemon.json,
# iptables-legacy.
#
# repack/repack-docker-ce.sh inlines the body (minus the shebang) into docker-ce's
# DEBIAN/postinst after `set -e`, ahead of debhelper's start of docker.service,
# and ships the same file as /usr/bin/wb-docker-setup. Dispatch at the bottom.
#
# The setup runs only on a first install of this package or on top of a previous
# run of it — never on a Docker laid out by someone else: moving its data-root to
# /mnt/data would orphan its images and containers.
#
# No postrm/prerm counterpart, by design. Everything this snippet creates is
# meant to outlive package removal: Docker data, configs and daemon.json all
# live under /mnt/data and must survive `apt purge docker-ce`, reinstall and
# firmware upgrade. The /etc/docker and /var/lib/containerd symlinks left
# behind point into /mnt/data and are harmless once the package is gone — a
# reinstall re-validates and re-creates them. Wiping that state is an explicit,
# user-driven action (see the "Удалить" section in README), not something a
# package maintainer script should do automatically.
#
# Structure: config below, then one function per setup step, then the entry
# point dispatch at the bottom.

set -e

PERSISTENT_ROOT=/mnt/data
PERSISTENT_ETC_DOCKER="${PERSISTENT_ROOT}/etc/docker"
PERSISTENT_CONTAINERD="${PERSISTENT_ROOT}/var/lib/containerd"
PERSISTENT_DOCKER_DATA="${PERSISTENT_ROOT}/docker/lib"
# Data-root used by the legacy community installer (wb-docker-manager.sh).
COMMUNITY_LEGACY_DOCKER_DATA="${PERSISTENT_ROOT}/.docker"

ROOTFS_ETC_DOCKER=/etc/docker
ROOTFS_CONTAINERD=/var/lib/containerd
ROOTFS_DOCKER_DATA=/var/lib/docker

DAEMON_JSON_TEMPLATE=/usr/share/wb-docker/daemon.json
DAEMON_JSON_TARGET="${PERSISTENT_ETC_DOCKER}/daemon.json"

log() {
    # dpkg shows postinst stderr in apt output — keep it human-readable.
    printf 'wb-docker: %s\n' "$*" >&2
}

# /mnt/data is the persistent partition on every WB controller. If it is
# missing here we are running on a misconfigured host — fail loudly rather
# than silently scribbling Docker data onto the rootfs.
require_persistent_root() {
    if [ ! -d "$PERSISTENT_ROOT" ]; then
        log "FATAL: ${PERSISTENT_ROOT} does not exist — refusing to seed Docker layout"
        exit 1
    fi
}

# Replace a rootfs path with a symlink into /mnt/data. docker-ce.deb unpacks
# /etc/docker (and sometimes /var/lib/containerd is created by
# containerd.io.deb) — migrate any content to the persistent location,
# skipping conflicts, then symlink.
migrate_rootfs_to_persistent() {
    rootfs_path="$1"
    persistent_path="$2"

    if [ -L "$rootfs_path" ]; then
        current_target=$(readlink "$rootfs_path")
        if [ "$current_target" = "$persistent_path" ]; then
            return 0
        fi
        log "replacing stale symlink ${rootfs_path} (was -> ${current_target})"
        rm -f "$rootfs_path"
    elif [ -d "$rootfs_path" ]; then
        log "migrating contents of ${rootfs_path} into ${persistent_path}"
        mkdir -p "$persistent_path"
        for entry in "$rootfs_path"/.* "$rootfs_path"/*; do
            case "$entry" in
                "$rootfs_path"/.|"$rootfs_path"/..) continue ;;
                "$rootfs_path"/.*\*|"$rootfs_path"/\*) continue ;;
            esac
            base=$(basename "$entry")
            if [ -e "$persistent_path/$base" ]; then
                log "  skip ${base}: already present in ${persistent_path}"
                continue
            fi
            mv -- "$entry" "$persistent_path/"
        done
        rmdir "$rootfs_path" 2>/dev/null || {
            log "WARN: ${rootfs_path} not empty after migration — leaving in place; symlink not created"
            return 1
        }
    elif [ -e "$rootfs_path" ]; then
        log "WARN: ${rootfs_path} exists and is neither symlink nor directory — leaving alone"
        return 1
    fi

    ln -s "$persistent_path" "$rootfs_path"
    log "linked ${rootfs_path} -> ${persistent_path}"
}

# A containerd store is one coherent unit: bolt metadata plus content blobs.
containerd_store_present() {
    [ -d "$1/io.containerd.metadata.v1.bolt" ] || [ -d "$1/io.containerd.content.v1.content" ]
}

# Merging two stores gives the daemon metadata from one and blobs from the other
# ("blob not found"). The rootfs one is live; a live /mnt/data store would sit
# behind the symlink and this code would not run, so that one is orphaned.
set_aside_orphaned_containerd() {
    [ ! -L "$ROOTFS_CONTAINERD" ] && \
    containerd_store_present "$ROOTFS_CONTAINERD" && \
    containerd_store_present "$PERSISTENT_CONTAINERD" || return 0

    orphaned="${PERSISTENT_CONTAINERD}.orphaned-$(date +%Y%m%d%H%M%S)"
    mv "$PERSISTENT_CONTAINERD" "$orphaned"
    log "moved containerd state of an earlier install aside: ${orphaned}"
}

# Migrate /var/lib/containerd onto /mnt/data, then restart containerd if it was
# actually migrated. containerd.io started containerd before this postinst, so
# it has meta.db open on the old rootfs /var/lib/containerd. The migration
# symlinked that onto /mnt/data; restart containerd so it reopens meta.db there
# instead of writing to the now-deleted rootfs inode, which is dropped on reboot
# (losing all image/container metadata). The pre-migration detection has to
# happen before migrate_rootfs_to_persistent turns the path into a symlink.
setup_containerd_symlink() {
    set_aside_orphaned_containerd

    containerd_was_migrated=no
    if [ -L "$ROOTFS_CONTAINERD" ]; then
        [ "$(readlink "$ROOTFS_CONTAINERD")" = "$PERSISTENT_CONTAINERD" ] || containerd_was_migrated=yes
    elif [ -e "$ROOTFS_CONTAINERD" ]; then
        containerd_was_migrated=yes
    fi

    migrate_rootfs_to_persistent "$ROOTFS_CONTAINERD" "$PERSISTENT_CONTAINERD" || true

    if [ "$containerd_was_migrated" = yes ] && \
       [ -L "$ROOTFS_CONTAINERD" ] && \
       [ "$(readlink "$ROOTFS_CONTAINERD")" = "$PERSISTENT_CONTAINERD" ] && \
       [ -d /run/systemd/system ]; then
        systemctl daemon-reload 2>/dev/null || true
        if systemctl is-active --quiet containerd.service 2>/dev/null; then
            log "restarting containerd to reopen meta.db on ${PERSISTENT_CONTAINERD}"
            systemctl restart containerd.service || \
                log "WARN: containerd restart failed — restart it before rebooting"
        fi
    fi
}

# Migrate data laid down by the legacy community installer
# (https://github.com/wirenboard/wb-community/blob/main/scripts/docker-install/wb-docker-manager.sh):
# it kept Docker data-root at /mnt/data/.docker. If that directory still
# exists and our target is empty, move it across. Also patch any daemon.json
# that still points data-root at the legacy location.
#
# Runs AFTER the rootfs symlink migration, on purpose: a community daemon.json
# starts life at /etc/docker/daemon.json and only lands at $DAEMON_JSON_TARGET
# (/mnt/data/etc/docker/daemon.json) once /etc/docker has been migrated into
# /mnt/data. Patching it before that migration was a silent no-op — the target
# did not exist yet — which left dockerd reading a /mnt/data/.docker we had just
# emptied. Keep the data move next to the daemon.json patch so the on-disk path
# and the configured path always agree.
migrate_community_legacy_data() {
    [ -d "$COMMUNITY_LEGACY_DOCKER_DATA" ] && [ ! -L "$COMMUNITY_LEGACY_DOCKER_DATA" ] || return 0

    if [ -f "$DAEMON_JSON_TARGET" ] && \
       grep -q '"data-root".*"/mnt/data/\.docker"' "$DAEMON_JSON_TARGET"; then
        sed -i "s|\"data-root\"[[:space:]]*:[[:space:]]*\"/mnt/data/\.docker\"|\"data-root\": \"${PERSISTENT_DOCKER_DATA}\"|" \
            "$DAEMON_JSON_TARGET"
        log "patched daemon.json data-root: ${COMMUNITY_LEGACY_DOCKER_DATA} -> ${PERSISTENT_DOCKER_DATA}"
    fi

    # shellcheck disable=SC2012
    if [ -z "$(ls -A "$PERSISTENT_DOCKER_DATA" 2>/dev/null || true)" ]; then
        log "migrating ${COMMUNITY_LEGACY_DOCKER_DATA} -> ${PERSISTENT_DOCKER_DATA}"
        for entry in "$COMMUNITY_LEGACY_DOCKER_DATA"/.* "$COMMUNITY_LEGACY_DOCKER_DATA"/*; do
            case "$entry" in
                "$COMMUNITY_LEGACY_DOCKER_DATA"/.|"$COMMUNITY_LEGACY_DOCKER_DATA"/..) continue ;;
                "$COMMUNITY_LEGACY_DOCKER_DATA"/.*\*|"$COMMUNITY_LEGACY_DOCKER_DATA"/\*) continue ;;
            esac
            base=$(basename "$entry")
            if [ -e "$PERSISTENT_DOCKER_DATA/$base" ]; then
                log "  skip ${base}: already present in ${PERSISTENT_DOCKER_DATA}"
                continue
            fi
            mv -- "$entry" "$PERSISTENT_DOCKER_DATA/"
        done
        rmdir "$COMMUNITY_LEGACY_DOCKER_DATA" 2>/dev/null || \
            log "  ${COMMUNITY_LEGACY_DOCKER_DATA} not empty after migration — left in place"
    else
        log "${PERSISTENT_DOCKER_DATA} already has content — leaving ${COMMUNITY_LEGACY_DOCKER_DATA} untouched"
    fi
}

# Seed daemon.json from the WB template only if the user does not already
# have one. Never overwrite.
seed_daemon_json() {
    [ ! -e "$DAEMON_JSON_TARGET" ] || return 0
    if [ -f "$DAEMON_JSON_TEMPLATE" ]; then
        install -m 0644 "$DAEMON_JSON_TEMPLATE" "$DAEMON_JSON_TARGET"
        log "seeded ${DAEMON_JSON_TARGET} from template"
    else
        log "WARN: daemon.json template missing at ${DAEMON_JSON_TEMPLATE} — skipping seed"
    fi
}

# Wiki rule: every Wiren Board release wb-2304 and newer (plus the rolling
# unstable.latest channel) needs the iptables-legacy backend for Docker NAT
# to work. See https://wiki.wirenboard.com/wiki/Docker. Releases that
# already default to legacy or use a different chain backend are skipped.
release_needs_legacy_iptables() {
    wb_release=/etc/wb-release
    [ -f "$wb_release" ] || return 1

    release_name=$(
        # shellcheck source=/dev/null
        . "$wb_release" >/dev/null 2>&1 || exit 1
        printf '%s' "${RELEASE_NAME-}"
    ) || return 1

    case "$release_name" in
        unstable.latest)
            return 0 ;;
        wb-[0-9][0-9][0-9][0-9])
            num=${release_name#wb-}
            [ "$num" -ge 2304 ] ;;
        *)
            log "iptables: unknown release '${release_name}' — legacy backend not pinned"
            return 1 ;;
    esac
}

# Pin iptables/ip6tables to the legacy backend via update-alternatives on the
# releases that need it.
switch_iptables_to_legacy() {
    release_needs_legacy_iptables || return 0

    if ! command -v update-alternatives >/dev/null 2>&1; then
        log "iptables: update-alternatives not available — skipping legacy pin"
        return 0
    fi

    for name in iptables ip6tables; do
        legacy_bin="/usr/sbin/${name}-legacy"
        nft_bin="/usr/sbin/${name}-nft"
        link_path="/usr/sbin/${name}"

        if [ ! -x "$legacy_bin" ]; then
            log "iptables: ${legacy_bin} missing — skipping ${name}"
            continue
        fi

        # On some WB releases (wb-2602/wb7 confirmed) the iptables package
        # leaves the alternatives group unregistered. `update-alternatives
        # --set` then fails with no useful message. Register both candidates
        # explicitly before --set so the operation is deterministic regardless
        # of upstream packaging quirks.
        if ! update-alternatives --query "$name" >/dev/null 2>&1; then
            if [ -x "$nft_bin" ]; then
                update-alternatives --install "$link_path" "$name" "$nft_bin" 10 2>/dev/null || true
            fi
            update-alternatives --install "$link_path" "$name" "$legacy_bin" 20 2>/dev/null || \
                log "iptables: WARN failed to register ${name} alternative"
        fi

        if update-alternatives --set "$name" "$legacy_bin" 2>/dev/null; then
            log "iptables: pinned ${name} -> ${legacy_bin}"
        else
            log "iptables: WARN --set ${name} -> ${legacy_bin} failed"
        fi
    done
}

# Data of a previous Docker sitting unused in the rootfs /var/lib/docker.
orphan_docker_data_present() {
    [ -d "$ROOTFS_DOCKER_DATA" ] && [ ! -L "$ROOTFS_DOCKER_DATA" ] && \
    { [ -d "$ROOTFS_DOCKER_DATA/image" ] || \
      [ -d "$ROOTFS_DOCKER_DATA/overlay2" ] || \
      [ -d "$ROOTFS_DOCKER_DATA/containers" ]; } || return 1

    # Not orphaned if the active daemon.json pins data-root back at
    # /var/lib/docker — then that data is in use, nothing is hidden.
    if [ -f "$DAEMON_JSON_TARGET" ] && \
       grep -q "\"data-root\"[[:space:]]*:[[:space:]]*\"${ROOTFS_DOCKER_DATA}\"" "$DAEMON_JSON_TARGET"; then
        return 1
    fi
}

# We deliberately do not touch that data: a graph store cannot be moved across
# Docker versions/backends reliably (upstream only offers `docker save` from the
# old daemon, which is gone by the time this runs). Just say it is there.
warn_old_docker_not_migrated() {
    orphan_docker_data_present || return 0

    log "WARNING: data of a previous Docker in ${ROOTFS_DOCKER_DATA} is not migrated"
    log "  It is not deleted, but this daemon does not see it: data-root is on"
    log "  /mnt/data. See https://wiki.wirenboard.com/wiki/Docker"
}

run_setup() {
    require_persistent_root
    mkdir -p "$PERSISTENT_ETC_DOCKER" "$PERSISTENT_CONTAINERD" "$PERSISTENT_DOCKER_DATA"

    migrate_rootfs_to_persistent "$ROOTFS_ETC_DOCKER" "$PERSISTENT_ETC_DOCKER" || true
    setup_containerd_symlink
    migrate_community_legacy_data
    seed_daemon_json
    switch_iptables_to_legacy
    warn_old_docker_not_migrated
}

# Our layout on disk. postrm keeps the symlink while the data on /mnt/data lives.
layout_in_place() {
    [ -L "$ROOTFS_ETC_DOCKER" ] || return 1
    [ "$(readlink "$ROOTFS_ETC_DOCKER")" = "$PERSISTENT_ETC_DOCKER" ]
}

decline_setup() {
    log "skipping setup: this Docker was not laid out by this package (was: ${1:-unknown})"
    log "  Its configuration and data are left untouched; it keeps working as before."
    log "  To apply the WB layout deliberately, run: wb-docker-setup"
}

# Our versions always carry the +wbNNN suffix (see versions.env).
our_own_version() {
    case "$1" in
        *+wb[0-9]*) return 0 ;;
        *) return 1 ;;
    esac
}

# The community installer makes the same symlinks; its data-root tells it apart.
community_layout_in_use() {
    [ -d "$COMMUNITY_LEGACY_DOCKER_DATA" ] && [ ! -L "$COMMUNITY_LEGACY_DOCKER_DATA" ]
}

# An empty $1 means a first install — the deliberate act.
dpkg_configure() {
    if [ -z "${1-}" ]; then
        run_setup
    elif our_own_version "$1" && layout_in_place && ! community_layout_in_use; then
        run_setup
    else
        decline_setup "$1"
    fi
}

# The template is the only thing that sets data-root, and it never overwrites.
report_data_root() {
    [ -f "$DAEMON_JSON_TARGET" ] && ! grep -q '"data-root"' "$DAEMON_JSON_TARGET" || return 0

    log "kept your daemon.json: it sets no data-root, so data stays in ${ROOTFS_DOCKER_DATA}"
    log "  add '\"data-root\": \"${PERSISTENT_DOCKER_DATA}\"' to ${DAEMON_JSON_TARGET} to move it"
}

# Manual run: the layout changes under a live Docker, so confirm and restart.
manual_setup() {
    if [ "${1-no}" != yes ] && orphan_docker_data_present; then
        log "images and containers in ${ROOTFS_DOCKER_DATA} will stop being visible"
        log "  (not deleted), and running containers will be stopped."
        if [ ! -t 0 ]; then
            log "  Refusing without a confirmation — re-run with --yes."
            exit 1
        fi
        printf 'wb-docker: continue? [y/N] ' >&2
        read -r reply || reply=""
        case "$reply" in
            y|Y|yes|YES) ;;
            *) log "aborted"; exit 1 ;;
        esac
    fi

    run_setup
    report_data_root

    if [ -d /run/systemd/system ] && systemctl is-active --quiet docker.service 2>/dev/null; then
        log "restarting docker.service"
        systemctl restart docker.service || log "WARN: docker.service restart failed"
    fi
}

usage() {
    cat >&2 <<'USAGE'
Usage: wb-docker-setup [--yes]

Puts Docker onto the Wiren Board layout: data-root, /etc/docker and containerd
state on /mnt/data, daemon.json, iptables-legacy.

  --yes   do not ask for confirmation
USAGE
}

# dpkg passes its maintainer-script action as $1; an operator passes flags.
case "${1-}" in
    configure)  dpkg_configure "${2-}" ;;
    "")         manual_setup no ;;
    --yes|-y)   manual_setup yes ;;
    -h|--help)  usage ;;
    -*)         log "unknown option: $1"; usage; exit 2 ;;
    *)          : ;;
esac
