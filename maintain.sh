maintain() {
    # ══════════════════════════════════════════════════════════════════════════
    #  HELPERS
    # ══════════════════════════════════════════════════════════════════════════
    _has()  { command -v "$1" &>/dev/null; }
    _ok()   { echo "   ✅ $*"; }
    _warn() { echo "   ⚠️  $*"; }
    _skip() { echo "   ⏭️  $*"; }
    _info() { echo "   ℹ️  $*"; }
    _head() {
        CURRENT_STEP=$(( CURRENT_STEP + 1 ))
        echo ""
        echo "┌─────────────────────────────────────────────────────────────"
        echo "│ Step $CURRENT_STEP/$TOTAL_STEPS — $*"
        echo "└─────────────────────────────────────────────────────────────"
    }
    _run() {
        if ! "$@" 2>/tmp/maintain_err; then
            _warn "Failed: $*"
            _warn "$(head -3 /tmp/maintain_err)"
            FAILED_STEPS=$(( FAILED_STEPS + 1 ))
            return 1
        fi
    }
    _section() { echo "   ── $* ──"; }

    # Safe recursive delete — works in both bash and zsh even when dir is empty
    _clean_dir()      { find "$1"      -mindepth 1 -exec rm -rf {} + 2>/dev/null || true; }
    _clean_dir_sudo() { sudo find "$1" -mindepth 1 -exec rm -rf {} + 2>/dev/null || true; }

    # ══════════════════════════════════════════════════════════════════════════
    #  PRE-FLIGHT
    # ══════════════════════════════════════════════════════════════════════════
    if ! sudo -v 2>/dev/null; then
        echo "❌ sudo privileges required. Aborting."
        return 1
    fi

    # Keep sudo alive for the full run — killed explicitly at the end.
    # NOTE: trap RETURN is bash-only; zsh does not support it, so we kill manually.
    ( while true; do sudo -v; sleep 50; done ) &
    SUDO_KEEPALIVE_PID=$!

    CURRENT_STEP=0
    FAILED_STEPS=0
    TOTAL_STEPS=30
    START_TIME=$(date +%s)
    DISK_BEFORE=$(df / --output=used | tail -1)

    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║        🛠️  Full System Maintenance                             ║"
    echo "║        $(date '+%A %d %B %Y, %H:%M')                          ║"
    echo "╚════════════════════════════════════════════════════════════════╝"

    # ══════════════════════════════════════════════════════════════════════════
    #  1 — APT
    # ══════════════════════════════════════════════════════════════════════════
    _head "APT — Update, upgrade, and fix broken packages"
    _run sudo apt-get update -qq
    _run sudo apt-get --fix-broken install -y
    _run sudo apt-get full-upgrade -y
    _run sudo apt-get autoremove --purge -y
    _run sudo apt-get autoclean
    _run sudo apt-get clean
    _ok "APT done."

    # ══════════════════════════════════════════════════════════════════════════
    #  2 — RESIDUAL CONFIG FILES
    # ══════════════════════════════════════════════════════════════════════════
    _head "APT — Purge residual config files from removed packages"
    RC_PKGS=$(dpkg -l | awk '/^rc/ {print $2}')
    if [ -n "$RC_PKGS" ]; then
        echo "$RC_PKGS" | _run sudo xargs dpkg --purge
        _ok "Purged residual configs."
    else
        _ok "No residual config files found."
    fi

    # ══════════════════════════════════════════════════════════════════════════
    #  3 — OLD KERNELS
    # ══════════════════════════════════════════════════════════════════════════
    _head "APT — Remove old/unused kernels (keep current + 1 previous)"
    CURRENT_KERNEL=$(uname -r)
    OLD_KERNELS=$(dpkg -l 'linux-image-[0-9]*' 'linux-headers-[0-9]*' 'linux-modules-[0-9]*' 2>/dev/null \
        | awk '/^ii/ {print $2}' \
        | grep -v "$CURRENT_KERNEL" \
        | grep -v "$(echo "$CURRENT_KERNEL" | sed 's/-generic//')" \
        | sort -V \
        | head -n -2)
    if [ -n "$OLD_KERNELS" ]; then
        echo "$OLD_KERNELS" | _run sudo xargs apt-get remove --purge -y
        _ok "Old kernels removed."
    else
        _ok "No old kernels to remove (current: $CURRENT_KERNEL)."
    fi

    # ══════════════════════════════════════════════════════════════════════════
    #  4 — FIRMWARE UPDATES
    # FIX: previous grep for "No updates" missed fwupd's actual output phrasing.
    #      Now relies on fwupdmgr exit code: 2 = nothing to do, 0 = updates exist.
    # ══════════════════════════════════════════════════════════════════════════
    _head "fwupd — Firmware updates"
    if _has fwupdmgr; then
        _run sudo fwupdmgr refresh --force
        fwupdmgr get-updates &>/tmp/fwupd_out 2>&1
        FWUPD_EXIT=$?
        # Exit code 2 means "no updates available" in fwupd
        if [ "$FWUPD_EXIT" -eq 2 ]; then
            _ok "No firmware updates available."
        elif [ "$FWUPD_EXIT" -eq 0 ]; then
            _run sudo fwupdmgr update -y && _ok "Firmware updated."
        else
            _warn "fwupdmgr get-updates exited with code $FWUPD_EXIT — skipping firmware update."
        fi
        rm -f /tmp/fwupd_out
    else
        _skip "fwupd not installed. Install with: sudo apt install fwupd"
    fi

    # ══════════════════════════════════════════════════════════════════════════
    #  5 — SNAP
    # FIX: some snap revisions fail to remove due to leftover /root/snap dirs
    #      (a known snapd bug). Demoted to a soft warning — not counted as a
    #      script failure. User is shown the manual fix command.
    # ══════════════════════════════════════════════════════════════════════════
    _head "Snap — Refresh and remove disabled revisions"
    if _has snap; then
        _run sudo snap refresh
        _run sudo systemctl restart snapd

        SNAP_REMOVED=0
        SNAP_FAILED=0
        while IFS=' ' read -r snapname revision; do
            if sudo snap remove "$snapname" --revision="$revision" 2>/tmp/maintain_err; then
                SNAP_REMOVED=$(( SNAP_REMOVED + 1 ))
            else
                _warn "Could not remove $snapname rev $revision: $(head -1 /tmp/maintain_err)"
                SNAP_FAILED=$(( SNAP_FAILED + 1 ))
            fi
        done < <(LANG=C snap list --all | awk '/disabled/ {print $1, $3}')
        _ok "Removed $SNAP_REMOVED old Snap revision(s)."
        [ "$SNAP_FAILED" -gt 0 ] && _info "$SNAP_FAILED revision(s) stuck — fix with: sudo rm -rf /root/snap/<name>"
    else
        _skip "Snap not installed."
    fi

    # ══════════════════════════════════════════════════════════════════════════
    #  6 — FLATPAK
    # ══════════════════════════════════════════════════════════════════════════
    _head "Flatpak — Update and remove unused runtimes"
    if _has flatpak; then
        _run flatpak update -y
        _run flatpak uninstall --unused -y
        _run flatpak repair --user
        _ok "Flatpak done."
    else
        _skip "Flatpak not installed."
    fi

    # ══════════════════════════════════════════════════════════════════════════
    #  7 — DOCKER
    # ══════════════════════════════════════════════════════════════════════════
    _head "Docker — Prune containers, images, volumes, networks, build cache"
    if _has docker; then
        if sudo docker info &>/dev/null; then
            _section "Stopped containers"
            _run sudo docker container prune -f
            _section "Unused networks"
            _run sudo docker network prune -f
            _section "Dangling images"
            _run sudo docker image prune -f
            _section "Unused volumes"
            _run sudo docker volume prune -f
            _section "Full system prune (all unused images + build cache)"
            _run sudo docker system prune -af --volumes
            _ok "Docker pruned."
        else
            _warn "Docker is installed but the daemon is not running. Skipping."
        fi
    else
        _skip "Docker not installed."
    fi

    # ══════════════════════════════════════════════════════════════════════════
    #  8 — PODMAN
    # ══════════════════════════════════════════════════════════════════════════
    _head "Podman — Prune all unused data"
    if _has podman; then
        _run podman system prune -af --volumes
        _ok "Podman pruned."
    else
        _skip "Podman not installed."
    fi

    # ══════════════════════════════════════════════════════════════════════════
    #  9 — LXD / LXC
    # ══════════════════════════════════════════════════════════════════════════
    _head "LXD — Clean unused images and instances"
    if _has lxc; then
        lxc image list --format csv | awk -F',' '{print $1}' | \
            xargs -I{} lxc image delete {} 2>/dev/null || true
        _ok "LXD images cleaned."
    else
        _skip "LXD not installed."
    fi

    # ══════════════════════════════════════════════════════════════════════════
    #  10 — VAGRANT
    # ══════════════════════════════════════════════════════════════════════════
    _head "Vagrant — Remove outdated boxes"
    if _has vagrant; then
        _run vagrant box prune -f
        _ok "Vagrant boxes pruned."
    else
        _skip "Vagrant not installed."
    fi

    # ══════════════════════════════════════════════════════════════════════════
    #  11 — NODE.JS / NPM / YARN / PNPM / BUN
    # ══════════════════════════════════════════════════════════════════════════
    _head "Node.js — Clean package manager caches"
    if _has npm; then
        _section "npm cache"
        _run npm cache clean --force
        _ok "npm cache cleared."
    else
        _skip "npm not installed."
    fi
    if _has yarn; then
        _section "Yarn cache"
        _run yarn cache clean --all
        _ok "Yarn cache cleared."
    else
        _skip "Yarn not installed."
    fi
    if _has pnpm; then
        _section "pnpm store"
        _run pnpm store prune
        _ok "pnpm store pruned."
    else
        _skip "pnpm not installed."
    fi
    if _has bun; then
        _section "Bun cache"
        _clean_dir "${HOME}/.bun/install/cache"
        _ok "Bun cache cleared."
    else
        _skip "Bun not installed."
    fi

    # ══════════════════════════════════════════════════════════════════════════
    #  12 — PYTHON
    # ══════════════════════════════════════════════════════════════════════════
    _head "Python — Clean pip cache and compiled bytecode"
    if _has pip3; then
        _section "pip cache"
        _run pip3 cache purge
        _ok "pip cache purged."
    elif _has pip; then
        _run pip cache purge
        _ok "pip cache purged."
    else
        _skip "pip not installed."
    fi

    _section "__pycache__ and .pyc files in home"
    find "${HOME}" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
    find "${HOME}" -name "*.pyc" -delete 2>/dev/null || true
    _ok "Python bytecode cleaned."

    if _has conda; then
        _section "Conda"
        _run conda clean --all -y
        _ok "Conda cleaned."
    fi

    # ══════════════════════════════════════════════════════════════════════════
    #  13 — RUST / CARGO
    # ══════════════════════════════════════════════════════════════════════════
    _head "Rust — Clean Cargo registry and target caches"
    if _has cargo; then
        if _has cargo-cache; then
            _run cargo cache --autoclean
            _ok "Cargo cache auto-cleaned."
        else
            _clean_dir "${HOME}/.cargo/registry/src"
            _ok "Cargo registry source cache cleared (install cargo-cache for deeper cleaning)."
        fi
    else
        _skip "Cargo not installed."
    fi

    # ══════════════════════════════════════════════════════════════════════════
    #  14 — RUBY / GEM
    # ══════════════════════════════════════════════════════════════════════════
    _head "Ruby — Remove old gem versions"
    if _has gem; then
        _run gem cleanup
        _ok "Old gem versions removed."
    else
        _skip "RubyGems not installed."
    fi

    # ══════════════════════════════════════════════════════════════════════════
    #  15 — GO
    # ══════════════════════════════════════════════════════════════════════════
    _head "Go — Clean module and build caches"
    if _has go; then
        _run go clean -modcache
        _run go clean -cache
        _run go clean -fuzzcache
        _ok "Go caches cleared."
    else
        _skip "Go not installed."
    fi

    # ══════════════════════════════════════════════════════════════════════════
    #  16 — JAVA (Maven / Gradle)
    # ══════════════════════════════════════════════════════════════════════════
    _head "Java — Clean Maven and Gradle caches"
    _section "Maven local repository snapshots"
    if [ -d "${HOME}/.m2/repository" ]; then
        find "${HOME}/.m2/repository" -name "*.lastUpdated" -delete 2>/dev/null || true
        find "${HOME}/.m2/repository" -name "*-SNAPSHOT" -type d \
            -mtime +30 -exec rm -rf {} + 2>/dev/null || true
        _ok "Maven stale snapshots cleaned."
    else
        _skip "Maven local repo not found."
    fi

    _section "Gradle caches (build daemons + old distributions)"
    if [ -d "${HOME}/.gradle" ]; then
        find "${HOME}/.gradle/caches" -maxdepth 1 -name "build-cache-*" \
            -exec rm -rf {} + 2>/dev/null || true
        [ -d "${HOME}/.gradle/daemon" ]        && rm -rf "${HOME}/.gradle/daemon"
        [ -d "${HOME}/.gradle/wrapper/dists" ] && rm -rf "${HOME}/.gradle/wrapper/dists"
        _ok "Gradle cache cleaned."
    else
        _skip "Gradle home not found."
    fi

    # ══════════════════════════════════════════════════════════════════════════
    #  17 — NIX
    # ══════════════════════════════════════════════════════════════════════════
    _head "Nix — Garbage collect old generations"
    if _has nix-collect-garbage; then
        _run nix-collect-garbage -d
        _ok "Nix garbage collected."
    else
        _skip "Nix not installed."
    fi

    # ══════════════════════════════════════════════════════════════════════════
    #  18 — HOMEBREW (Linuxbrew)
    # ══════════════════════════════════════════════════════════════════════════
    _head "Homebrew — Update, upgrade, and clean"
    if _has brew; then
        _run brew update
        _run brew upgrade
        _run brew cleanup --prune=7
        _run brew autoremove
        _ok "Homebrew cleaned."
    else
        _skip "Homebrew not installed."
    fi

    # ══════════════════════════════════════════════════════════════════════════
    #  19 — SYSTEMD JOURNAL, COREDUMPS, CRASH REPORTS
    # ══════════════════════════════════════════════════════════════════════════
    _head "Systemd — Vacuum journal, coredumps, and crash reports"
    _run sudo journalctl --vacuum-time=7d
    _run sudo journalctl --vacuum-size=500M

    _section "Coredump archives"
    if [ -d /var/lib/systemd/coredump ]; then
        _clean_dir_sudo /var/lib/systemd/coredump
        _ok "Coredumps removed."
    else
        _skip "No coredump directory found."
    fi

    _section "Crash reports"
    if [ -d /var/crash ]; then
        _clean_dir_sudo /var/crash
        _ok "Crash reports removed."
    else
        _skip "No crash directory found."
    fi

    _run sudo systemd-tmpfiles --clean
    _ok "Journal and crash data cleaned."

    # ══════════════════════════════════════════════════════════════════════════
    #  20 — /tmp AND /var/tmp
    # ══════════════════════════════════════════════════════════════════════════
    _head "Temporary files — /tmp and /var/tmp"
    _section "Old files in /tmp (untouched > 3 days)"
    sudo find /tmp -mindepth 1 -atime +3 -exec rm -rf {} + 2>/dev/null || true

    _section "Old files in /var/tmp (untouched > 7 days)"
    sudo find /var/tmp -mindepth 1 -atime +7 -exec rm -rf {} + 2>/dev/null || true
    _ok "Temp directories cleaned."

    # ══════════════════════════════════════════════════════════════════════════
    #  21 — LOG FILES
    # FIX: logrotate exits non-zero when a log file referenced in a config doesn't
    #      exist (e.g. clamav.log after uninstalling clamav). This is harmless —
    #      logrotate still processes all other rules. Run outside _run so a
    #      missing log file doesn't inflate the failure counter.
    # ══════════════════════════════════════════════════════════════════════════
    _head "Log files — Rotate, compress, and remove stale logs"
    sudo logrotate --force /etc/logrotate.conf 2>/dev/null || \
        _warn "logrotate had warnings (likely missing logs from uninstalled packages — harmless)."

    _section "Stale compressed/old logs older than 14 days"
    sudo find /var/log -name "*.gz"  -mtime +14 -delete 2>/dev/null || true
    sudo find /var/log -name "*.old" -mtime +14 -delete 2>/dev/null || true
    sudo find /var/log -name "*.1"   -mtime +14 -delete 2>/dev/null || true
    _ok "Logs rotated and stale compressed logs removed."

    # ══════════════════════════════════════════════════════════════════════════
    #  22 — USER CACHE / TRASH / THUMBNAILS
    # ══════════════════════════════════════════════════════════════════════════
    _head "User data — Trash, thumbnails, and general ~/.cache"

    _section "Trash"
    _clean_dir "${HOME}/.local/share/Trash/files"
    _clean_dir "${HOME}/.local/share/Trash/info"
    _ok "Trash emptied."

    _section "Thumbnail cache"
    _clean_dir "${HOME}/.cache/thumbnails"
    _ok "Thumbnails cleared."

    _section "Browser caches (Chromium / Chrome / Firefox / Brave / Edge)"
    for BROWSER_CACHE in \
        "${HOME}/.cache/chromium" \
        "${HOME}/.cache/google-chrome" \
        "${HOME}/.cache/BraveSoftware" \
        "${HOME}/.cache/microsoft-edge" \
        "${HOME}/.cache/mozilla"; do
        if [ -d "$BROWSER_CACHE" ]; then
            _clean_dir "$BROWSER_CACHE"
            _info "Cleared: $BROWSER_CACHE"
        fi
    done

    _section "General ~/.cache entries older than 30 days"
    find "${HOME}/.cache" -mindepth 1 -maxdepth 1 -atime +30 \
        -not -name "thumbnails" \
        -exec rm -rf {} + 2>/dev/null || true
    _ok "User cache cleaned."

    # ══════════════════════════════════════════════════════════════════════════
    #  23 — DNS CACHE
    # FIX: Ubuntu 22.04+ dropped `systemd-resolve` in favour of `resolvectl`.
    #      The old code checked for systemd-resolved activity, then tried
    #      systemd-resolve (missing), printed the failure, but still printed ✅.
    #      Now tries resolvectl first, then falls back to systemd-resolve.
    # ══════════════════════════════════════════════════════════════════════════
    _head "Network — Flush DNS cache"
    if systemctl is-active systemd-resolved &>/dev/null; then
        if _has resolvectl; then
            _run sudo resolvectl flush-caches
            _ok "DNS cache flushed via resolvectl."
        elif _has systemd-resolve; then
            _run sudo systemd-resolve --flush-caches
            _ok "DNS cache flushed via systemd-resolve."
        else
            _warn "systemd-resolved is active but neither resolvectl nor systemd-resolve was found."
        fi
    elif _has nscd; then
        _run sudo systemctl restart nscd
        _ok "nscd restarted (DNS cache cleared)."
    else
        _skip "No recognised DNS cache manager found."
    fi

    # ══════════════════════════════════════════════════════════════════════════
    #  24 — APPARMOR
    # ══════════════════════════════════════════════════════════════════════════
    _head "AppArmor — Reload profiles and clear cache"
    if _has apparmor_parser && systemctl is-active apparmor &>/dev/null; then
        _run sudo apparmor_parser -r /etc/apparmor.d/ 2>/dev/null
        _clean_dir_sudo /var/cache/apparmor
        _ok "AppArmor profiles reloaded and cache cleared."
    else
        _skip "AppArmor not active."
    fi

    # ══════════════════════════════════════════════════════════════════════════
    #  25 — FONT AND ICON CACHES
    # ══════════════════════════════════════════════════════════════════════════
    _head "Desktop — Rebuild font, icon, MIME, and desktop-entry caches"
    if _has fc-cache; then
        _run sudo fc-cache -f 2>/dev/null
        _ok "Font cache rebuilt."
    else
        _skip "fc-cache not found."
    fi

    if _has gtk-update-icon-cache; then
        for d in /usr/share/icons/*/; do
            [ -f "${d}index.theme" ] && sudo gtk-update-icon-cache -q "$d" 2>/dev/null || true
        done
        _ok "Icon caches updated."
    else
        _skip "gtk-update-icon-cache not found."
    fi

    if _has update-mime-database; then
        _run sudo update-mime-database /usr/share/mime
        _ok "MIME database updated."
    else
        _skip "update-mime-database not found."
    fi

    if _has update-desktop-database; then
        _run sudo update-desktop-database /usr/share/applications
        _ok "Desktop database updated."
    else
        _skip "update-desktop-database not found."
    fi

    # ══════════════════════════════════════════════════════════════════════════
    #  26 — LOCATE DATABASE
    # ══════════════════════════════════════════════════════════════════════════
    _head "Locate — Rebuild file search database"
    if _has updatedb; then
        _run sudo updatedb
        _ok "locate database updated."
    else
        _skip "mlocate/plocate not installed."
    fi

    # ══════════════════════════════════════════════════════════════════════════
    #  27 — SHARED LIBRARY CACHE
    # ══════════════════════════════════════════════════════════════════════════
    _head "System — Refresh shared library (ldconfig) cache"
    _run sudo ldconfig
    _ok "ldconfig cache refreshed."

    # ══════════════════════════════════════════════════════════════════════════
    #  28 — GRUB
    # FIX: the original used a `_has A && { ... } || _has B && { ... }` chain.
    #      In shell, `&&/||` chains bind left-to-right so after the first block
    #      succeeded, the `||` still evaluated its right side. Replaced with a
    #      proper if/elif/else which is unambiguous in both bash and zsh.
    # ══════════════════════════════════════════════════════════════════════════
    _head "GRUB — Update bootloader configuration"
    if [ -f /boot/grub/grub.cfg ] || [ -d /boot/grub2 ]; then
        if _has update-grub; then
            _run sudo update-grub
            _ok "GRUB updated."
        elif _has grub2-mkconfig; then
            _run sudo grub2-mkconfig -o /boot/grub2/grub.cfg
            _ok "GRUB2 config updated."
        else
            _skip "GRUB update command not found."
        fi
    else
        _skip "GRUB not detected on this system."
    fi

    # ══════════════════════════════════════════════════════════════════════════
    #  29 — SSD TRIM / PAGE CACHE / SWAP
    # ══════════════════════════════════════════════════════════════════════════
    _head "Memory & Storage — SSD trim, drop caches, cycle swap"

    _section "SSD TRIM"
    _run sudo fstrim -av

    _section "Drop page/dentry/inode cache"
    sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
    _ok "RAM cache dropped."

    _section "Swap"
    SWAP_USED=$(free | awk '/Swap/ {print $3}')
    if [ "${SWAP_USED:-0}" -gt 0 ]; then
        _run sudo swapoff -a && _run sudo swapon -a
        _ok "Swap cycled (was ${SWAP_USED} kB used)."
    else
        _ok "Swap is empty — no cycle needed."
    fi

    # ══════════════════════════════════════════════════════════════════════════
    #  30 — SMART DISK HEALTH CHECK
    # ══════════════════════════════════════════════════════════════════════════
    _head "Disk health — SMART self-test check"
    if _has smartctl; then
        while IFS= read -r DISK; do
            SMART_STATUS=$(sudo smartctl -H "$DISK" 2>/dev/null | grep -i "overall-health\|result")
            if echo "$SMART_STATUS" | grep -qi "PASSED\|OK"; then
                _ok "$DISK — SMART: PASSED"
            elif [ -n "$SMART_STATUS" ]; then
                _warn "$DISK — SMART: $SMART_STATUS  ← Investigate immediately!"
            fi
        done < <(lsblk -dpno NAME | grep -E '^/dev/(sd|nvme|hd|vd)')
    else
        _skip "smartmontools not installed. Install with: sudo apt install smartmontools"
    fi

    # ══════════════════════════════════════════════════════════════════════════
    #  FINAL SUMMARY
    # ══════════════════════════════════════════════════════════════════════════
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    rm -f /tmp/maintain_err

    END_TIME=$(date +%s)
    ELAPSED=$(( END_TIME - START_TIME ))
    ELAPSED_FMT="$(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"
    DISK_AFTER=$(df / --output=used | tail -1)
    DISK_FREED=$(( (DISK_BEFORE - DISK_AFTER) / 1024 ))

    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                  📊 SYSTEM HEALTH SUMMARY                     ║"
    echo "╚════════════════════════════════════════════════════════════════╝"

    _info "Completed in ${ELAPSED_FMT}"

    if [ "$DISK_FREED" -gt 0 ]; then
        _ok "Disk freed this run: ~${DISK_FREED} MiB"
    else
        _info "No measurable disk space freed."
    fi

    DISK_USAGE=$(df -h / | awk 'NR==2 {print $5 " used — " $4 " free of " $2}')
    _info "Root partition: $DISK_USAGE"

    if [ "$FAILED_STEPS" -gt 0 ]; then
        _warn "$FAILED_STEPS step(s) had errors — scroll up to review."
    else
        _ok "All steps completed without errors."
    fi

    # FIX: `grep -c` exits with code 1 when the count is 0, causing `|| echo 0`
    #      to run and produce "0\n0" — not a valid integer for the [ -gt ] test.
    #      Replaced with awk which always exits 0 and always prints a number.
    FAILED_SVCS=$(systemctl --failed --no-pager --plain 2>/dev/null \
        | awk '/●/{count++} END{print count+0}')
    if [ "${FAILED_SVCS}" -gt 0 ]; then
        _warn "$FAILED_SVCS failed systemd service(s). Run: systemctl --failed"
    else
        _ok "All systemd services are healthy."
    fi

    if _has sensors; then
        CPU_TEMP=$(sensors 2>/dev/null | awk '/^(Core|CPU Temp|Package)/ {print $1, $2, $3; exit}')
        [ -n "$CPU_TEMP" ] && _info "CPU temp: $CPU_TEMP"
    fi

    _info "Uptime: $(uptime -p)"

    if [ -f /var/run/reboot-required ]; then
        _warn "A reboot is required to apply updates."
        if [ -f /var/run/reboot-required.pkgs ]; then
            _info "Triggered by: $(tr '\n' ' ' < /var/run/reboot-required.pkgs)"
        fi
    else
        _ok "No reboot required."
    fi

    echo "════════════════════════════════════════════════════════════════"
}
