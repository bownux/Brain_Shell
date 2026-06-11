#!/bin/bash
# 2026-06-11 (rog): hyprshutdown isn't packaged on Gentoo — fall back to plain
# systemd so the power menu actually works. hyprshutdown (graceful app close)
# is used when present.
run_power() {
    local post="$1"
    if command -v hyprshutdown >/dev/null 2>&1; then
        (setsid bash -c "hyprshutdown --post-cmd '$post'" &>/dev/null &)
    else
        (setsid bash -c "$post" &>/dev/null &)
    fi
}
case "$1" in
    shutdown) run_power "systemctl poweroff" ;;
    reboot)   run_power "systemctl reboot" ;;
    logout)   run_power "loginctl terminate-user $USER" ;;
    *) exit 1 ;;
esac
