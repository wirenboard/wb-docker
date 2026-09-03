#!/bin/sh
# dpkg tells install and upgrade apart only here; the postinst gets the same
# `configure <version>` for both.

WB_FIRST_INSTALL_MARKER=/run/wb-docker-first-install

case "$1" in
    install) : > "$WB_FIRST_INSTALL_MARKER" 2>/dev/null || true ;;
    upgrade) rm -f "$WB_FIRST_INSTALL_MARKER" ;;
esac
