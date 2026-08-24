#!/bin/sh
# Wiren Board Docker integration: teardown counterpart of postinst-snippet.sh,
# injected into docker-ce's DEBIAN/postrm by repack/repack-docker-ce.sh (the
# body is inlined after the first `set -e`, wrapped in BEGIN/END markers).
#
# Why stop containerd: on purge the documented next step is wiping Docker
# state on /mnt/data (see README, "Удалить"). containerd.io may still be
# installed at that point — `apt autoremove` only sweeps packages marked
# automatic, and an install from local .deb files (or an explicit
# `apt install containerd.io`) marks them manual. A containerd left running
# keeps the deleted meta.db open and serves ghost metadata afterwards: pulls
# "succeed" without downloading anything, and the next dockerd restart fails
# with "blob ... not found". Stop it while we can, so the wipe happens against
# a quiesced state.
#
# Why remove the symlinks: after the wipe a dangling /var/lib/containerd
# symlink wedges any OTHER containerd installed later — Debian's containerd
# (docker.io) fails `mkdir /var/lib/containerd: file exists` and loops in
# restart. Remove the links our postinst created (only symlinks, only ones
# pointing into /mnt/data — a real directory is somebody else's and stays).
# Data on /mnt/data is NOT touched; a reinstall recreates the links.
# /etc/docker is usually already gone here (dpkg removes it as an owned path),
# the loop below just covers the leftover cases.
#
# Runs ONLY on purge. On upgrade/remove/abort-* paths dpkg passes a different
# $1 and this is a no-op, so routine updates never touch containerd here.
# docker.service/docker.socket need no handling: debhelper's own blocks in
# docker-ce's maintainer scripts have stopped them before purge runs.

if [ "$1" = "purge" ]; then
    if [ -d /run/systemd/system ]; then
        systemctl stop containerd.service 2>/dev/null || true
    fi
    for link in /var/lib/containerd /etc/docker; do
        if [ -L "$link" ]; then
            case "$(readlink "$link")" in
                /mnt/data/*) rm -f "$link" ;;
            esac
        fi
    done
fi
