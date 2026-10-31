#!/usr/bin/env bash
#
# fedora-snapper-setup.sh
#
# Btrfs + Snapper + DNF5 snapshot hooks + grub-btrfs on Fedora 44, automated.
#
# Based on "Fedora 44 + Btrfs + Snapper Tutorial" by hasanabs:
#   https://gist.github.com/hasanabs/817e2922e86f7222bbfe54869976dc47
# plus fixes for problems found while following it (see CHANGES FROM THE GIST).
#
# USAGE
#   sudo ./fedora-snapper-setup.sh --dry-run           # show what would happen
#   sudo ./fedora-snapper-setup.sh                     # default phases
#   sudo ./fedora-snapper-setup.sh snapper hook        # only these phases
#   sudo ./fedora-snapper-setup.sh fstab --dry-run     # preview an opt-in phase
#
# PHASES (run in this order; default set marked *)
#   packages *       install snapper, libdnf5-plugin-actions, build tools
#   fstab            opt-in: add noatime / compress=zstd:1 to Btrfs fstab lines
#   snapper *        create the 'root' config, set retention, enable timers
#   hook *           DNF5 pre/post snapshots via libdnf5-plugin-actions
#   default-subvol * set '@' as the default subvolume (only if root is on '@')
#   grub-btrfs *     build, configure for Fedora, regenerate GRUB, enable daemon
#   rollback *       install snapper-rollback (only for '@' + '@snapshots')
#   assistant        opt-in: Btrfs Assistant (GUI, pulls in Qt)
#   test-hook        opt-in: real dnf install/remove to prove the hook works
#   verify *         read-only health check
#
# NOT AUTOMATED (do these by hand, following the gist)
#   - Phase 1: Anaconda partitioning and Btrfs subvolume creation
#   - A wholesale fstab rewrite (gist 2.3); the fstab phase only edits options
#   - The "reinstall without touching user data" bonus
#
# CHANGES FROM THE GIST
#   - DNF helper scripts have no backslash line continuations (a broken
#     continuation produced pre snapshots with empty descriptions and no post),
#     log to the journal (journalctl -t snapper-dnf5), validate the pre-number,
#     and never block a dnf transaction.
#   - grub-btrfs ships its Fedora settings commented out; the defaults point at
#     /boot/grub, which fails on Fedora. They are written as an active managed
#     block at the end of the config, and grub2-mkconfig output is checked for
#     errors from 41_snapshots-btrfs.
#   - grub-btrfs is built in a temp dir (minimal installs have no ~/Downloads).
#   - /.snapshots is never removed with rm -rf. A leftover plain directory is
#     removed with rmdir, which refuses if it is not empty.
#   - Steps specific to the gist's '@' layout are skipped on other layouts.
#   - snapper-rollback validates its argument, refuses to run from a booted
#     snapshot, and restores the original @ if creating the new one fails.
#
# ENVIRONMENT
#   GRUB_BTRFS_REPO   git URL for grub-btrfs (default: upstream)
#   GRUB_BTRFS_REF    tag or branch to build (default: upstream default branch;
#                     pin a release tag for reproducible installs)
#
# Log: /var/log/fedora-snapper-setup.log

set -Eeuo pipefail

readonly SCRIPT_NAME=${0##*/}
readonly LOG_FILE=/var/log/fedora-snapper-setup.log
readonly GRUB_CFG=/boot/grub2/grub.cfg
readonly SNAP_CONFIG=root
readonly PRE_HELPER=/usr/local/bin/snapper-dnf5-pre
readonly POST_HELPER=/usr/local/bin/snapper-dnf5-post
readonly ROLLBACK_BIN=/usr/local/bin/snapper-rollback
readonly ACTIONS_FILE=/etc/dnf/libdnf5-plugins/actions.d/snapper.actions
readonly GRUB_BTRFS_CONFIG=/etc/default/grub-btrfs/config
readonly BASELINE_DESC='fedora-snapper-setup baseline'

GRUB_BTRFS_REPO=${GRUB_BTRFS_REPO:-https://github.com/Antynea/grub-btrfs.git}
GRUB_BTRFS_REF=${GRUB_BTRFS_REF:-}

DRY_RUN=0
ASSUME_YES=0
REINSTALL_GRUB_BTRFS=0
WORKDIR=""
ROOT_DEV=""
ROOT_SUBVOL=""
LAYOUT_AT=0
FAILS=0

readonly DEFAULT_PHASES=(packages snapper hook default-subvol grub-btrfs rollback verify)
readonly ALL_PHASES=(packages fstab snapper hook default-subvol grub-btrfs rollback assistant test-hook verify)

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_AMBER=$'\033[33m'
    C_CYAN=$'\033[36m'
    C_RESET=$'\033[0m'
else
    C_RED=''
    C_GREEN=''
    C_AMBER=''
    C_CYAN=''
    C_RESET=''
fi

log()  { printf '%s[ .. ]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_AMBER" "$C_RESET" "$*" >&2; }
die()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

dry() { printf '%s[dry ]%s %s\n' "$C_AMBER" "$C_RESET" "$*"; }

# run <cmd...>: echo the command, execute it unless --dry-run.
run() {
    if (( DRY_RUN )); then
        dry "$*"
        return 0
    fi
    printf '+ %s\n' "$*"
    "$@"
}

# confirm <question>: auto-yes with --yes or --dry-run.
confirm() {
    local reply
    if (( ASSUME_YES || DRY_RUN )); then
        return 0
    fi
    read -r -p "$1 [y/N] " reply
    [[ $reply =~ ^[Yy]$ ]]
}

backup_file() {
    local f=$1 stamp
    [[ -e $f ]] || return 0
    stamp=$(date +%Y%m%d-%H%M%S)
    run cp -a -- "$f" "${f}.bak-${stamp}"
}

# write_file <path> <mode>: atomically write stdin to <path>.
write_file() {
    local path=$1 mode=$2 tmp
    if (( DRY_RUN )); then
        dry "write ${path} (mode ${mode})"
        cat > /dev/null
        return 0
    fi
    install -d -m 0755 "$(dirname "$path")"
    tmp=$(mktemp "${path}.XXXXXX")
    cat > "$tmp"
    chmod "$mode" "$tmp"
    mv -f -- "$tmp" "$path"
    printf '+ wrote %s\n' "$path"
}

# managed_block <file> <tag>: replace (or append) a delimited block, body on stdin.
# Idempotent: running twice leaves the file byte-for-byte identical.
managed_block() {
    local file=$1 tag=$2 begin end body tmp
    begin="# >>> ${tag} (managed) >>>"
    end="# <<< ${tag} <<<"
    body=$(cat)
    if (( DRY_RUN )); then
        dry "set managed block '${tag}' in ${file}:"
        printf '%s\n' "$body"
        return 0
    fi
    [[ -f $file ]] || die "$file does not exist"
    tmp=$(mktemp)
    # Drop any old block and trailing blank lines, then append the new block.
    awk -v b="$begin" -v e="$end" '
        $0 == b { skip = 1; blanks = 0; next }
        $0 == e { skip = 0; next }
        skip    { next }
        /^$/    { blanks++; next }
        {
            while (blanks > 0) { print ""; blanks-- }
            print
        }
    ' "$file" > "$tmp"
    printf '\n%s\n%s\n%s\n' "$begin" "$body" "$end" >> "$tmp"
    if cmp -s "$tmp" "$file"; then
        rm -f "$tmp"
        ok "${file}: managed block '${tag}' already up to date"
        return 0
    fi
    backup_file "$file"
    install -m 0644 "$tmp" "$file"
    rm -f "$tmp"
    ok "${file}: managed block '${tag}' written"
}

cleanup() {
    if [[ -n $WORKDIR && -d $WORKDIR ]]; then
        rm -rf -- "$WORKDIR"
    fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
    local os_id os_ver
    [[ $EUID -eq 0 ]] || die "Run as root: sudo ./${SCRIPT_NAME}"
    os_id=$(. /etc/os-release && printf '%s' "${ID:-}")
    os_ver=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
    [[ $os_id == fedora ]] || die "This script targets Fedora (found: ${os_id:-unknown})"
    if [[ $os_ver != 44 ]]; then
        warn "Written for Fedora 44; found ${os_ver:-unknown}. Continuing."
    fi
    command -v dnf > /dev/null || die "dnf not found"
    [[ $(findmnt -no FSTYPE /) == btrfs ]] || die "The root filesystem is not Btrfs"

    ROOT_DEV=$(findmnt -no SOURCE / | sed 's/\[.*//')
    ROOT_SUBVOL=$(findmnt -no OPTIONS / | tr ',' '\n' | sed -n 's/^subvol=//p')
    ROOT_SUBVOL=${ROOT_SUBVOL#/}

    case $ROOT_SUBVOL in
        *snapshots*)
            die "Booted into a snapshot (root subvolume: ${ROOT_SUBVOL}). Reboot into the normal entry first."
            ;;
    esac
    if [[ $ROOT_SUBVOL == "@" ]]; then
        LAYOUT_AT=1
    fi
    log "Root device: ${ROOT_DEV}; root subvolume: '${ROOT_SUBVOL:-<top level>}'"
    if (( LAYOUT_AT )); then
        log "Layout: '@' style (gist layout)"
    else
        warn "Root is not on subvolume '@'. Steps that assume the gist's layout will be skipped."
    fi
    if [[ ! -d /boot/grub2 ]]; then
        warn "/boot/grub2 not found. Is /boot mounted? The grub-btrfs phase will refuse to run."
    fi
}

# ---------------------------------------------------------------------------
# Phase: packages
# ---------------------------------------------------------------------------
phase_packages() {
    log "Installing required packages"
    run dnf install -y snapper libdnf5-plugin-actions btrfs-progs git make inotify-tools gawk
}

# ---------------------------------------------------------------------------
# Phase: fstab (opt-in)
# ---------------------------------------------------------------------------

# tune_fstab_stream <fstab>: print a copy with noatime on every Btrfs line and
# compress=zstd:1 on / and /home. Lines that already choose an atime or compress
# option are left alone.
tune_fstab_stream() {
    awk '
        BEGIN { OFS = "  " }
        /^[[:space:]]*#/ || NF < 4 { print; next }
        $3 != "btrfs"              { print; next }
        {
            orig = $0
            opts = $4
            if (opts !~ /(^|,)(no|rel|strict)?atime(,|$)/) {
                opts = opts ",noatime"
            }
            if (($2 == "/" || $2 == "/home") && opts !~ /(^|,)compress(-force)?(=|,|$)/) {
                opts = opts ",compress=zstd:1"
            }
            if (opts == $4) { print orig; next }
            $4 = opts
            print
        }
    ' "$1"
}

phase_fstab() {
    local fstab=/etc/fstab tmp
    log "Tuning Btrfs mount options in ${fstab}"
    if grep -Eq '^[^#]*[[:space:]]/mnt/sysroot' "$fstab"; then
        die "fstab looks like raw Anaconda web-installer output (/mnt/sysroot paths). Replace it using the template in gist section 2.3 first; this script will not guess your subvolume layout."
    fi
    tmp=$(mktemp)
    tune_fstab_stream "$fstab" > "$tmp"
    if cmp -s "$tmp" "$fstab"; then
        rm -f "$tmp"
        ok "fstab already has the intended options"
        return 0
    fi
    printf -- '--- proposed changes ---\n'
    diff -u "$fstab" "$tmp" || true
    if ! findmnt --verify --tab-file "$tmp"; then
        warn "findmnt --verify reported issues with the proposed file (see above)"
    fi
    if ! confirm "Install the modified fstab? A timestamped backup is kept."; then
        rm -f "$tmp"
        warn "fstab left unchanged"
        return 0
    fi
    backup_file "$fstab"
    if (( DRY_RUN )); then
        rm -f "$tmp"
        return 0
    fi
    install -m 0644 "$tmp" "$fstab"
    rm -f "$tmp"
    run systemctl daemon-reload
    ok "fstab updated; the new options apply after the next reboot"
}

# ---------------------------------------------------------------------------
# Phase: snapper
# ---------------------------------------------------------------------------
snapper_config_exists() {
    snapper list-configs 2> /dev/null | awk -v c="$SNAP_CONFIG" 'NR > 2 && $1 == c { found = 1 } END { exit !found }'
}

apply_snapper_tuning() {
    local kv
    local -a settings=(
        TIMELINE_CREATE=yes
        TIMELINE_LIMIT_HOURLY=3
        TIMELINE_LIMIT_DAILY=5
        TIMELINE_LIMIT_WEEKLY=3
        TIMELINE_LIMIT_MONTHLY=1
        TIMELINE_LIMIT_YEARLY=0
        NUMBER_LIMIT=5
        NUMBER_LIMIT_IMPORTANT=10
        EMPTY_PRE_POST_CLEANUP=yes
    )
    log "Applying retention settings to the '${SNAP_CONFIG}' config"
    for kv in "${settings[@]}"; do
        run snapper -c "$SNAP_CONFIG" set-config "$kv"
    done
}

make_baseline() {
    if snapper -c "$SNAP_CONFIG" list 2> /dev/null | grep -q "$BASELINE_DESC"; then
        ok "Baseline snapshot already exists"
    else
        run snapper -c "$SNAP_CONFIG" create --description "$BASELINE_DESC"
    fi
}

phase_snapper() {
    local remount=0
    command -v snapper > /dev/null || die "snapper is not installed (run the 'packages' phase first)"

    if snapper_config_exists; then
        ok "Snapper config '${SNAP_CONFIG}' already exists"
    else
        if mountpoint -q /.snapshots; then
            remount=1
            log "/.snapshots is a mount point (dedicated @snapshots subvolume)"
            confirm "Unmount /.snapshots so Snapper can create its config, then mount it back?" || die "Aborted"
            run umount /.snapshots
            run rmdir /.snapshots || {
                mount /.snapshots 2> /dev/null || true
                die "/.snapshots is not empty underneath the mount (snapshots written into @ before it was mounted?). Nothing was deleted; inspect it."
            }
        elif [[ -e /.snapshots ]]; then
            if btrfs subvolume show /.snapshots > /dev/null 2>&1; then
                die "/.snapshots is already a subvolume but has no Snapper config. Inspect it (sudo btrfs subvolume show /.snapshots) before continuing."
            fi
            log "/.snapshots is a plain directory (the 'not a btrfs subvolume' case)"
            run rmdir /.snapshots || die "/.snapshots is a non-empty plain directory. Nothing was deleted; inspect it."
        fi
        run snapper -c "$SNAP_CONFIG" create-config /
        if (( remount )); then
            run mount /.snapshots || die "Could not mount /.snapshots; check its /etc/fstab entry."
        fi
    fi

    apply_snapper_tuning
    run systemctl enable --now snapper-timeline.timer snapper-cleanup.timer
    if [[ -d /.snapshots ]]; then
        run restorecon -Rv /.snapshots
    fi
    log "No Snapper config is created for /home (per the gist: /home is never rolled back)."
    make_baseline
}

# ---------------------------------------------------------------------------
# Phase: hook (DNF5 pre/post snapshots)
# ---------------------------------------------------------------------------
phase_hook() {
    rpm -q --quiet libdnf5-plugin-actions || die "libdnf5-plugin-actions is not installed (run the 'packages' phase first)"

    write_file "$PRE_HELPER" 0755 << 'PRE_EOF'
#!/bin/bash
# Called by libdnf5-plugin-actions before every DNF5 transaction.
# Creates a Snapper "pre" snapshot and records its number for the post hook.
# Never blocks the transaction: failures are logged and ignored.
STATE=${SNAPPER_DNF_STATE:-/run/snapper-dnf-pre-number}
CMD=$(tr '\0' ' ' < "/proc/$PPID/cmdline" 2>/dev/null | sed 's/[[:space:]]*$//')
DESC=${CMD:-dnf5 transaction}

rm -f "$STATE"
if NUM=$(snapper -c root create --type pre --cleanup-algorithm number --print-number --description "$DESC"); then
    echo "$NUM" > "$STATE"
    logger -t snapper-dnf5 "pre snapshot $NUM created: $DESC"
else
    logger -t snapper-dnf5 "FAILED to create pre snapshot: $DESC"
fi
exit 0
PRE_EOF

    write_file "$POST_HELPER" 0755 << 'POST_EOF'
#!/bin/bash
# Called by libdnf5-plugin-actions after every DNF5 transaction.
# Pairs a Snapper "post" snapshot with the recorded "pre" snapshot.
STATE=${SNAPPER_DNF_STATE:-/run/snapper-dnf-pre-number}
PRE=$(cat "$STATE" 2>/dev/null)
if [[ ! "$PRE" =~ ^[0-9]+$ ]]; then
    logger -t snapper-dnf5 "no pre snapshot recorded, skipping post"
    exit 0
fi
CMD=$(tr '\0' ' ' < "/proc/$PPID/cmdline" 2>/dev/null | sed 's/[[:space:]]*$//')
DESC=${CMD:-dnf5 transaction}

if NUM=$(snapper -c root create --type post --pre-number "$PRE" --cleanup-algorithm number --print-number --description "$DESC"); then
    logger -t snapper-dnf5 "post snapshot $NUM paired with pre $PRE"
else
    logger -t snapper-dnf5 "FAILED to create post snapshot for pre $PRE"
fi
rm -f "$STATE"
exit 0
POST_EOF

    # Hook file: HOOK:PKG_FILTER:DIRECTION:OPTIONS:CMD (libdnf5-plugin-actions).
    # The plugin uses execv, so no shell syntax is allowed in CMD.
    write_file "$ACTIONS_FILE" 0644 << 'ACTIONS_EOF'
pre_transaction::::/usr/local/bin/snapper-dnf5-pre
post_transaction::::/usr/local/bin/snapper-dnf5-post
ACTIONS_EOF

    if (( ! DRY_RUN )); then
        bash -n "$PRE_HELPER" && bash -n "$POST_HELPER" || die "A helper script failed its syntax check"
    fi
    run restorecon -v "$PRE_HELPER" "$POST_HELPER" "$ACTIONS_FILE"
    ok "DNF5 hook installed. Descriptions will be the dnf command line, e.g. 'dnf5 install cowsay'."
}

# ---------------------------------------------------------------------------
# Phase: test-hook (opt-in): prove the hook works with a real transaction
# ---------------------------------------------------------------------------
phase_test_hook() {
    local before after
    command -v snapper > /dev/null || die "snapper is not installed"
    before=$(snapper -c "$SNAP_CONFIG" list | wc -l)
    log "Running a real install/remove of 'cowsay' to exercise the hook"
    run dnf install -y cowsay
    run dnf remove -y cowsay
    if (( DRY_RUN )); then
        return 0
    fi
    after=$(snapper -c "$SNAP_CONFIG" list | wc -l)
    snapper -c "$SNAP_CONFIG" list | tail -n 6
    journalctl -t snapper-dnf5 -n 10 --no-pager || true
    if (( after - before >= 4 )); then
        ok "Two pre/post pairs were created"
    else
        warn "Expected 4 new snapshots, found $(( after - before )). See: journalctl -t snapper-dnf5"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Phase: default-subvol ('@' layouts only)
# ---------------------------------------------------------------------------
phase_default_subvol() {
    local id current
    if (( ! LAYOUT_AT )); then
        log "Root subvolume is '${ROOT_SUBVOL:-<top level>}', not '@': leaving the default subvolume alone"
        return 0
    fi
    id=$(btrfs subvolume list / | awk '$NF == "@" { print $2 }')
    [[ -n $id ]] || die "Could not find a subvolume named '@'"
    current=$(btrfs subvolume get-default / | awk '{ print $NF }')
    if [[ $current == "@" ]]; then
        ok "'@' is already the default subvolume"
        return 0
    fi
    confirm "Set '@' (ID ${id}) as the default subvolume?" || { warn "Skipped"; return 0; }
    run btrfs subvolume set-default "$id" /
    run dracut --force --regenerate-all
}

# ---------------------------------------------------------------------------
# Phase: grub-btrfs
# ---------------------------------------------------------------------------
build_grub_btrfs() {
    local -a clone_args=(--depth 1)
    if [[ -n $GRUB_BTRFS_REF ]]; then
        clone_args+=(--branch "$GRUB_BTRFS_REF")
    fi
    WORKDIR=$(mktemp -d /var/tmp/grub-btrfs.XXXXXX)
    log "Building grub-btrfs in ${WORKDIR}"
    run git clone "${clone_args[@]}" "$GRUB_BTRFS_REPO" "$WORKDIR/grub-btrfs"
    run make -C "$WORKDIR/grub-btrfs" install
}

configure_grub_btrfs() {
    local mkconfig lib='' cand lib_line=''
    mkconfig=$(command -v grub2-mkconfig) || die "grub2-mkconfig not found"
    for cand in /usr/share/grub/grub-mkconfig_lib /usr/share/grub2/grub-mkconfig_lib; do
        if [[ -f $cand ]]; then
            lib=$cand
            break
        fi
    done
    if [[ -n $lib ]]; then
        lib_line="GRUB_BTRFS_MKCONFIG_LIB=\"${lib}\""
    else
        warn "grub-mkconfig_lib not found in the usual places; leaving GRUB_BTRFS_MKCONFIG_LIB at its default"
    fi
    managed_block "$GRUB_BTRFS_CONFIG" fedora-snapper-setup << EOF
GRUB_BTRFS_GRUB_DIRNAME="/boot/grub2"
GRUB_BTRFS_MKCONFIG="${mkconfig}"
GRUB_BTRFS_SCRIPT_CHECK="grub2-script-check"
${lib_line}
EOF
}

regen_grub() {
    local out
    log "Regenerating ${GRUB_CFG}"
    if (( DRY_RUN )); then
        dry "grub2-mkconfig -o ${GRUB_CFG}"
        return 0
    fi
    if ! out=$(grub2-mkconfig -o "$GRUB_CFG" 2>&1); then
        printf '%s\n' "$out"
        die "grub2-mkconfig failed"
    fi
    printf '%s\n' "$out"
    # os-prober "fsconfig() failed" warnings are harmless (common in VMs).
    if grep -Eq '41_snapshots-btrfs: .*(No such file|not found|rror)' <<< "$out"; then
        die "grub-btrfs reported an error while generating the menu (see output above). Check ${GRUB_BTRFS_CONFIG}."
    fi
    if [[ ! -s /boot/grub2/grub-btrfs.cfg ]]; then
        warn "/boot/grub2/grub-btrfs.cfg is missing or empty (expected once snapshots exist)"
    fi
}

phase_grub_btrfs() {
    [[ -d /boot/grub2 ]] || die "/boot/grub2 not found; is /boot mounted and is GRUB installed?"
    [[ -d /.snapshots ]] || die "/.snapshots does not exist; run the 'snapper' phase first"
    if [[ -x /etc/grub.d/41_snapshots-btrfs && -x /usr/bin/grub-btrfsd ]] && (( ! REINSTALL_GRUB_BTRFS )); then
        ok "grub-btrfs is already installed (use --reinstall-grub-btrfs to rebuild)"
    else
        build_grub_btrfs
    fi
    configure_grub_btrfs
    run restorecon -v /etc/grub.d/41_snapshots-btrfs
    regen_grub
    run systemctl enable --now grub-btrfsd.service
    if (( ! DRY_RUN )) && ! systemctl is-active --quiet grub-btrfsd.service; then
        warn "grub-btrfsd is not running. Inspect: journalctl -u grub-btrfsd -n 30 --no-pager"
    fi
}

# ---------------------------------------------------------------------------
# Phase: rollback ('@' + '@snapshots' layouts only)
# ---------------------------------------------------------------------------
phase_rollback() {
    if (( ! LAYOUT_AT )); then
        warn "Root subvolume is '${ROOT_SUBVOL:-<top level>}', not '@': skipping snapper-rollback (it assumes '@' and '@snapshots' at the top level)."
        return 0
    fi
    if ! btrfs subvolume list / | awk '$NF == "@snapshots" { found = 1 } END { exit !found }'; then
        warn "No top-level '@snapshots' subvolume: skipping snapper-rollback."
        return 0
    fi

    write_file "$ROLLBACK_BIN" 0755 << 'ROLLBACK_EOF'
#!/bin/bash
# snapper-rollback - replace subvolume @ with a copy of a Snapper snapshot.
# Layout assumed: top-level subvolumes @ (mounted at /) and @snapshots
# (mounted at /.snapshots). The previous @ is kept as @.old-<timestamp>.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo snapper-rollback <snapshot-id>"
SNAP_ID=${1:-}
[[ $SNAP_ID =~ ^[0-9]+$ ]] || die "Usage: sudo snapper-rollback <snapshot-id>"

ROOT_OPTS=$(findmnt -n -o OPTIONS /)
[[ $ROOT_OPTS =~ (^|,)subvol=/@(,|$) ]] || die "Root is not subvolume @ (booted into a snapshot?). Reboot into the normal entry first."

DEV=$(findmnt -n -o SOURCE / | sed 's/\[.*//')
TOPDIR=$(mktemp -d)
cleanup() {
    umount "$TOPDIR" 2>/dev/null || true
    rmdir "$TOPDIR" 2>/dev/null || true
}
trap cleanup EXIT
mount -o subvolid=5 "$DEV" "$TOPDIR"

SNAP_PATH="$TOPDIR/@snapshots/$SNAP_ID/snapshot"
btrfs subvolume show "$SNAP_PATH" > /dev/null 2>&1 || die "Snapshot #$SNAP_ID not found at @snapshots/$SNAP_ID/snapshot"

BACKUP="@.old-$(date +%Y%m%d-%H%M%S)"
echo "Saving current @ as $BACKUP..."
mv "$TOPDIR/@" "$TOPDIR/$BACKUP"

echo "Creating new @ from snapshot #$SNAP_ID..."
if ! btrfs subvolume snapshot "$SNAP_PATH" "$TOPDIR/@"; then
    mv "$TOPDIR/$BACKUP" "$TOPDIR/@"
    die "Could not create the new @; the original @ was restored."
fi
btrfs property set "$TOPDIR/@" ro false

NEW_DEFAULT=$(btrfs subvolume list "$TOPDIR" | awk '$NF == "@" { print $2 }')
[[ -n $NEW_DEFAULT ]] || die "Could not find the new @ subvolume ID"
btrfs subvolume set-default "$NEW_DEFAULT" "$TOPDIR"

echo
echo "Done. Reboot to apply:  sudo reboot"
echo
echo "The old @ is kept as $BACKUP. Delete it once you are satisfied:"
echo "  sudo mount -o subvolid=5 $DEV /mnt"
echo "  sudo btrfs subvolume delete /mnt/$BACKUP"
echo "  sudo umount /mnt"
ROLLBACK_EOF

    run restorecon -v "$ROLLBACK_BIN"
}

# ---------------------------------------------------------------------------
# Phase: assistant (opt-in)
# ---------------------------------------------------------------------------
phase_assistant() {
    log "Installing Btrfs Assistant (GUI; pulls in Qt, so it is opt-in on a minimal install)"
    run dnf install -y btrfs-assistant
}

# ---------------------------------------------------------------------------
# Phase: verify (read-only)
# ---------------------------------------------------------------------------
check() {
    local desc=$1
    shift
    if "$@" > /dev/null 2>&1; then
        ok "$desc"
    else
        warn "$desc"
        FAILS=$(( FAILS + 1 ))
    fi
}

helpers_ok()           { [[ -x $PRE_HELPER && -x $POST_HELPER ]]; }
grub_btrfs_cfg_ok()    { grep -Eq '^GRUB_BTRFS_GRUB_DIRNAME="?/boot/grub2"?' "$GRUB_BTRFS_CONFIG"; }
zram_active()          { [[ $(swapon --show=NAME --noheadings) == *zram* ]]; }

phase_verify() {
    FAILS=0
    log "Verification"
    check "Snapper config '${SNAP_CONFIG}' exists"          snapper_config_exists
    check "snapper-timeline.timer enabled"                  systemctl is-enabled --quiet snapper-timeline.timer
    check "snapper-cleanup.timer enabled"                   systemctl is-enabled --quiet snapper-cleanup.timer
    check "/.snapshots is a Btrfs subvolume"                btrfs subvolume show /.snapshots
    check "libdnf5-plugin-actions installed"                rpm -q --quiet libdnf5-plugin-actions
    check "DNF5 snapper actions file present"               test -f "$ACTIONS_FILE"
    check "DNF5 helper scripts executable"                  helpers_ok
    check "grub-btrfs installed"                            test -x /etc/grub.d/41_snapshots-btrfs
    check "grub-btrfs Fedora settings active"               grub_btrfs_cfg_ok
    check "grub-btrfsd running"                             systemctl is-active --quiet grub-btrfsd.service
    check "GRUB menu contains the snapshot hook"            grep -q 41_snapshots-btrfs "$GRUB_CFG"
    check "zram swap active"                                zram_active

    printf '\n'
    btrfs subvolume get-default / || true
    snapper -c "$SNAP_CONFIG" list 2> /dev/null | tail -n 6 || true
    if command -v podman > /dev/null; then
        podman --version
    else
        log "podman not installed (optional; gist phase 9). Install with: sudo dnf install podman"
    fi

    printf '\n'
    if (( FAILS > 0 )); then
        warn "${FAILS} check(s) need attention"
        return 1
    fi
    ok "All checks passed. Reboot, then confirm the 'Fedora snapshots' submenu appears in GRUB."
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
usage() {
    cat << EOF
Usage: sudo ./${SCRIPT_NAME} [options] [phase ...]

Options:
  -n, --dry-run             print actions without changing anything
  -y, --yes                 do not ask for confirmation
      --reinstall-grub-btrfs  rebuild grub-btrfs even if it is installed
  -h, --help                show this help

Phases (default: ${DEFAULT_PHASES[*]}):
  ${ALL_PHASES[*]}

Opt-in phases (never run by default): fstab, assistant, test-hook.
Environment: GRUB_BTRFS_REPO, GRUB_BTRFS_REF.
EOF
}

is_phase() {
    local p
    for p in "${ALL_PHASES[@]}"; do
        [[ $p == "$1" ]] && return 0
    done
    return 1
}

main() {
    local -a phases=()
    local p
    while (( $# )); do
        case $1 in
            -n|--dry-run)           DRY_RUN=1 ;;
            -y|--yes)               ASSUME_YES=1 ;;
            --reinstall-grub-btrfs) REINSTALL_GRUB_BTRFS=1 ;;
            -h|--help)              usage; exit 0 ;;
            -*)                     usage >&2; die "Unknown option: $1" ;;
            *)                      phases+=("$1") ;;
        esac
        shift
    done
    if (( ${#phases[@]} == 0 )); then
        phases=("${DEFAULT_PHASES[@]}")
    fi
    for p in "${phases[@]}"; do
        is_phase "$p" || die "Unknown phase: ${p} (valid: ${ALL_PHASES[*]})"
    done

    [[ $EUID -eq 0 ]] || die "Run as root: sudo ./${SCRIPT_NAME}"
    exec > >(tee -a "$LOG_FILE") 2>&1
    trap cleanup EXIT
    trap 'warn "Error on line ${LINENO} (exit status $?)"' ERR

    if (( DRY_RUN )); then
        warn "DRY RUN: nothing will be changed"
    fi
    preflight
    for p in "${phases[@]}"; do
        printf '\n'
        log "=== phase: ${p} ==="
        "phase_${p//-/_}"
    done
    printf '\n'
    ok "Done. Log: ${LOG_FILE}"
}

# Run only when executed, so the functions can be sourced for testing.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
