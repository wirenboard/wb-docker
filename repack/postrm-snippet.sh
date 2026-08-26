#!/bin/sh
# Runs ONLY on purge. On upgrade/remove/abort-* paths dpkg passes a different
# $1 and this is a no-op, so routine updates never touch containerd here.
# docker.service/docker.socket need no handling: debhelper's own blocks in
# docker-ce's maintainer scripts have stopped them before purge runs.

if [ "$1" = "purge" ]; then
    if [ -d /run/systemd/system ]; then
        systemctl stop containerd.service 2>/dev/null || true
    fi
    # Remove only dangling links; live /mnt/data data keeps its link.
    for link in /var/lib/containerd /etc/docker; do
        if [ -L "$link" ] && [ ! -e "$link" ]; then
            case "$(readlink "$link")" in
                /mnt/data/*) rm -f "$link" ;;
            esac
        fi
    done
fi
