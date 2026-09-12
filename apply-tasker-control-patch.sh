#!/usr/bin/env bash
#
# apply-tasker-control-patch.sh
#
# Patches a sing-box-for-android source tree so that:
#   1-3) an EXPORTED broadcast receiver (ControlReceiver) lets Tasker (direct
#        Intent, or `am broadcast` via Shizuku/rish) start/stop the proxy while
#        the screen is off / locked / in the background;
#   3b)  the service returns START_STICKY, so Android itself restarts it after
#        the process is killed (does not survive a force-stop; never fires after
#        a normal stop, which calls stopSelf());
#   3c)  the app REPORTS its state: it broadcasts SERVICE_STARTED when the proxy
#        is up and SERVICE_STOPPED (extra "reason" = user|error) when it stops
#        on purpose. A kill by the system sends nothing - so "notification gone
#        without SERVICE_STOPPED" == killed. Tasker mirrors these into a variable
#        with two "Intent Received" profiles (no permission needed).
#   3d)  the self-updater's pre-install stop is marked "for update": no STOPPED
#        broadcast, and Settings.startedByUser is kept, so upstream's own
#        BootReceiver (MY_PACKAGE_REPLACED) restarts the proxy after the update;
#   4)   (optional, --update-repo) the app's built-in GitHub updater checks
#        YOUR repository's Releases instead of SagerNet/sing-box, so the phone
#        self-updates from your own auto-built APKs.
#
# Intended for CI: the GitHub Actions workflow checks out upstream source fresh
# and runs this at build time only, so nothing here is ever committed to a
# fork. It also runs locally in git-bash for a local build.
#
# Usage:
#   bash apply-tasker-control-patch.sh                                  # apply 1-3d (idempotent)
#   bash apply-tasker-control-patch.sh --update-repo OWNER/REPO         # apply 1-4
#   bash apply-tasker-control-patch.sh --revert                         # remove everything
#   bash apply-tasker-control-patch.sh --repo-root DIR ...              # point at a tree elsewhere
#   SFA_UPDATE_REPO=OWNER/REPO bash apply-tasker-control-patch.sh       # same as --update-repo
#
# Design: anchors only on stable landmarks (`object Action {`, `</application>`,
# `companion object {`, `status.postValue(Status.Started)`, `status.value =
# Status.Stopping`, `Settings.startedByUser = false`, `BoxService.stop()`, the
# RELEASES_URL constant) -- never line numbers -- so it keeps working after
# upstream source upgrades, and FAILS LOUDLY when an anchor is gone (so CI
# never ships a half-patched APK). ASCII-only on purpose.
#
set -euo pipefail

REVERT=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
UPDATE_REPO="${SFA_UPDATE_REPO:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --revert)         REVERT=1; shift ;;
        --repo-root)      REPO_ROOT="$2"; shift 2 ;;
        --repo-root=*)    REPO_ROOT="${1#*=}"; shift ;;
        --update-repo)    UPDATE_REPO="$2"; shift 2 ;;
        --update-repo=*)  UPDATE_REPO="${1#*=}"; shift ;;
        -h|--help)        sed -n '2,/^set -euo/p' "$0" | sed 's/^#\{0,1\} \{0,1\}//;$d'; exit 0 ;;
        *)                echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ -n "$UPDATE_REPO" ] && ! printf '%s' "$UPDATE_REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
    echo "--update-repo must look like OWNER/REPO (got: $UPDATE_REPO)" >&2
    exit 2
fi

ACTION_FILE="$REPO_ROOT/app/src/main/java/io/nekohasekai/sfa/constant/Action.kt"
RECEIVER_FILE="$REPO_ROOT/app/src/main/java/io/nekohasekai/sfa/bg/ControlReceiver.kt"
MANIFEST_FILE="$REPO_ROOT/app/src/main/AndroidManifest.xml"
BOX_FILE="$REPO_ROOT/app/src/main/java/io/nekohasekai/sfa/bg/BoxService.kt"
INSTALLER_FILES=(
    "$REPO_ROOT/app/src/other/java/io/nekohasekai/sfa/vendor/ApkInstaller.kt"
    "$REPO_ROOT/app/src/otherLegacy/java/io/nekohasekai/sfa/vendor/ApkInstaller.kt"
)
UPDATER_FILE="$REPO_ROOT/app/src/github/java/io/nekohasekai/sfa/vendor/GitHubUpdateChecker.kt"
UPSTREAM_REPO="SagerNet/sing-box"

for f in "$ACTION_FILE" "$MANIFEST_FILE" "$BOX_FILE"; do
    if [ ! -f "$f" ]; then
        echo "Not found: $f" >&2
        echo "Run from the repo root, or pass --repo-root DIR." >&2
        exit 1
    fi
done

die() { echo "$*" >&2; exit 1; }

# Prints OWNER/REPO the updater currently points at, or nothing if unknown. Never fails.
updater_repo() {
    [ -f "$UPDATER_FILE" ] || return 0
    grep -Eo 'RELEASES_URL[[:space:]]*=[[:space:]]*"https://api\.github\.com/repos/[^"/]+/[^"/]+/releases"' "$UPDATER_FILE" \
        | sed -E 's#.*/repos/([^"/]+/[^"/]+)/releases".*#\1#' | head -n1 || true
}

# Lines this patch adds to BoxService.kt (matched verbatim by the revert regexes below).
BC_STARTED='service.sendBroadcast(Intent(Action.SERVICE_STARTED))'
BC_STOPPED_USER='if (!stoppingForUpdate) service.sendBroadcast(Intent(Action.SERVICE_STOPPED).putExtra("reason", "user"))'
BC_STOPPED_ERR='service.sendBroadcast(Intent(Action.SERVICE_STOPPED).putExtra("reason", "error"))'

apply_patch() {
    # 1) Action.kt: insert the four constants right after `object Action {`
    if grep -q 'SERVICE_STOPPED' "$ACTION_FILE"; then
        echo '[=] Action.kt already has the constants, skipping'
    else
        # (drop leftovers of an older 2-constant version of this patch first)
        perl -0777 -i -pe 's/[ \t]*const val SERVICE_(START|STOP) = "io\.nekohasekai\.sfa\.SERVICE_(START|STOP)"\n//g' "$ACTION_FILE"
        perl -0777 -i -pe 's/(object\s+Action\s*\{[^\n]*\n)/$1    const val SERVICE_START = "io.nekohasekai.sfa.SERVICE_START"\n    const val SERVICE_STOP = "io.nekohasekai.sfa.SERVICE_STOP"\n    const val SERVICE_STARTED = "io.nekohasekai.sfa.SERVICE_STARTED"\n    const val SERVICE_STOPPED = "io.nekohasekai.sfa.SERVICE_STOPPED"\n/' "$ACTION_FILE"
        grep -q 'SERVICE_STOPPED' "$ACTION_FILE" || die "Anchor 'object Action {' not found in Action.kt; patch by hand."
        echo '[+] Action.kt: inserted SERVICE_START / STOP / STARTED / STOPPED'
    fi

    # 2) ControlReceiver.kt: write (overwrite)
    mkdir -p "$(dirname "$RECEIVER_FILE")"
    cat > "$RECEIVER_FILE" <<'EOF'
package io.nekohasekai.sfa.bg

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.nekohasekai.sfa.constant.Action
import kotlinx.coroutines.DelicateCoroutinesApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch

class ControlReceiver : BroadcastReceiver() {
    @OptIn(DelicateCoroutinesApi::class)
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Action.SERVICE_START -> GlobalScope.launch(Dispatchers.Main) { BoxService.start() }
            Action.SERVICE_STOP -> GlobalScope.launch(Dispatchers.Main) { BoxService.stop() }
        }
    }
}
EOF
    echo '[+] wrote bg/ControlReceiver.kt'

    # 3) AndroidManifest.xml: insert <receiver> just before </application>
    if grep -q 'ControlReceiver' "$MANIFEST_FILE"; then
        echo '[=] AndroidManifest.xml already has ControlReceiver, skipping'
    else
        RECV_BLOCK=$'        <receiver\n            android:name=".bg.ControlReceiver"\n            android:exported="true">\n            <intent-filter>\n                <action android:name="io.nekohasekai.sfa.SERVICE_START" />\n                <action android:name="io.nekohasekai.sfa.SERVICE_STOP" />\n            </intent-filter>\n        </receiver>\n'
        RECV_BLOCK="$RECV_BLOCK" perl -0777 -i -pe 's/^([ \t]*<\/application>)/$ENV{RECV_BLOCK}\n$1/m' "$MANIFEST_FILE"
        grep -q 'ControlReceiver' "$MANIFEST_FILE" || die "Anchor '</application>' not found in AndroidManifest.xml; patch by hand."
        echo '[+] AndroidManifest.xml: inserted ControlReceiver'
    fi

    # Hard check: BoxService.start()/stop() are the only upstream API ControlReceiver relies on
    grep -Eq 'fun[[:space:]]+start[[:space:]]*\(' "$BOX_FILE" && grep -Eq 'fun[[:space:]]+stop[[:space:]]*\(' "$BOX_FILE" \
        || die "BoxService.start()/stop() not found - upstream refactored; ControlReceiver.kt needs an update."

    # 3b) BoxService.kt: START_NOT_STICKY -> START_STICKY on the standalone final `return` of
    #     onStartCommand (the one-line "already running" guard `if (...) return ...` is left alone)
    if grep -Eq '^[[:space:]]+return Service\.START_STICKY[[:space:]]*$' "$BOX_FILE"; then
        echo '[=] BoxService.kt already returns START_STICKY, skipping'
    else
        grep -Eq '^[[:space:]]+return Service\.START_NOT_STICKY[[:space:]]*$' "$BOX_FILE" \
            || die "Anchor 'return Service.START_NOT_STICKY' (standalone line) not found in BoxService.kt."
        perl -i -pe 's/^(\s+)return Service\.START_NOT_STICKY(\s*)$/$1return Service.START_STICKY$2/' "$BOX_FILE"
        echo '[+] BoxService.kt: onStartCommand now returns START_STICKY'
    fi

    # 3c/3d) BoxService.kt: state broadcasts + "stopping for update" flag
    if grep -q 'stoppingForUpdate' "$BOX_FILE"; then
        echo '[=] BoxService.kt already has state broadcasts / stopForUpdate, skipping'
    else
        # (i) companion: flag + stopForUpdate()
        perl -0777 -i -pe 's/^([ \t]+)companion object \{\n/${1}companion object {\n${1}    \@Volatile var stoppingForUpdate = false\n\n${1}    fun stopForUpdate() {\n${1}        stoppingForUpdate = true\n${1}        stop()\n${1}    }\n\n/m' "$BOX_FILE"
        grep -q 'fun stopForUpdate()' "$BOX_FILE" || die "Anchor 'companion object {' not found in BoxService.kt."

        # (ii) proxy is up -> SERVICE_STARTED
        BC="$BC_STARTED" perl -0777 -i -pe 's/^([ \t]+)status\.postValue\(Status\.Started\)\n/${1}status.postValue(Status.Started)\n${1}$ENV{BC}\n/m' "$BOX_FILE"
        grep -qF "$BC_STARTED" "$BOX_FILE" || die "Anchor 'status.postValue(Status.Started)' not found in BoxService.kt."

        # (iii) deliberate stop (user / Tasker / tile / notification button) -> SERVICE_STOPPED reason=user
        BC="$BC_STOPPED_USER" perl -0777 -i -pe 's/^([ \t]+)status\.value = Status\.Stopping\n/${1}status.value = Status.Stopping\n${1}$ENV{BC}\n/m' "$BOX_FILE"
        grep -qF "$BC_STOPPED_USER" "$BOX_FILE" || die "Anchor 'status.value = Status.Stopping' not found in BoxService.kt."

        # (iv) in stopService(): keep startedByUser when stopping for an update, then clear the flag
        perl -0777 -i -pe 's/^([ \t]+)Settings\.startedByUser = false\n(?=[ \t]+withContext\(Dispatchers\.Main\) \{\n[ \t]+status\.value = Status\.Stopped\n)/${1}if (!stoppingForUpdate) Settings.startedByUser = false\n${1}stoppingForUpdate = false\n/m' "$BOX_FILE"
        grep -q 'if (!stoppingForUpdate) Settings.startedByUser = false' "$BOX_FILE" || die "Anchor 'Settings.startedByUser = false' (in stopService) not found in BoxService.kt."

        # (v) stop because of an error (bad config, missing permission...) -> SERVICE_STOPPED reason=error
        BC="$BC_STOPPED_ERR" perl -0777 -i -pe 's/^([ \t]+)Settings\.startedByUser = false\n(?=[ \t]+val pfd = fileDescriptor\n)/${1}Settings.startedByUser = false\n${1}$ENV{BC}\n/m' "$BOX_FILE"
        grep -qF "$BC_STOPPED_ERR" "$BOX_FILE" || die "Anchor 'Settings.startedByUser = false' (in stopAndAlert) not found in BoxService.kt."

        echo '[+] BoxService.kt: SERVICE_STARTED / SERVICE_STOPPED broadcasts + stopForUpdate()'
    fi

    # 3d) ApkInstaller.kt: the pre-install stop is a stop "for update". The otherLegacy flavor's
    #     installer has no pre-install stop at all (checked at 1.14.0), so "nothing to do" is fine
    #     there; the `other` flavor -- the one we ship -- must end up patched.
    for f in "${INSTALLER_FILES[@]}"; do
        [ -f "$f" ] || continue
        FLAVOR="$(echo "$f" | sed -E 's#.*/app/src/([^/]+)/.*#\1#')"
        if grep -q 'BoxService.stopForUpdate()' "$f"; then
            echo "[=] ApkInstaller.kt ($FLAVOR) already uses stopForUpdate(), skipping"
        elif grep -q 'BoxService.stop()' "$f"; then
            perl -i -pe 's/BoxService\.stop\(\)/BoxService.stopForUpdate()/g' "$f"
            echo "[+] ApkInstaller.kt ($FLAVOR): pre-install stop -> stopForUpdate()"
        else
            echo "[=] ApkInstaller.kt ($FLAVOR) has no pre-install BoxService.stop(), nothing to do"
        fi
    done
    grep -q 'BoxService.stopForUpdate()' "${INSTALLER_FILES[0]}" \
        || die "ApkInstaller.kt (other) does not call BoxService.stopForUpdate() - anchor 'BoxService.stop()' missing (upstream changed?)."

    # 4) GitHubUpdateChecker.kt: point the built-in updater at OWNER/REPO (only if asked)
    if [ -n "$UPDATE_REPO" ]; then
        [ -f "$UPDATER_FILE" ] || die "Not found: $UPDATER_FILE (needed for --update-repo); upstream may have moved it."
        if [ "$(updater_repo)" = "$UPDATE_REPO" ]; then
            echo "[=] GitHubUpdateChecker.kt already points at $UPDATE_REPO, skipping"
        else
            UPDATE_REPO="$UPDATE_REPO" perl -0777 -i -pe 's{(RELEASES_URL\s*=\s*"https://api\.github\.com/repos/)[^"/]+/[^"/]+(/releases")}{${1}$ENV{UPDATE_REPO}${2}}' "$UPDATER_FILE"
            [ "$(updater_repo)" = "$UPDATE_REPO" ] || die "Anchor 'RELEASES_URL = \"https://api.github.com/repos/.../releases\"' not found in GitHubUpdateChecker.kt; patch by hand."
            echo "[+] GitHubUpdateChecker.kt: updater now reads releases of $UPDATE_REPO"
        fi
    fi
}

revert_patch() {
    # 1) Action.kt: remove the constants
    perl -0777 -i -pe 's/[ \t]*const val SERVICE_(START|STOP|STARTED|STOPPED) = "io\.nekohasekai\.sfa\.SERVICE_(START|STOP|STARTED|STOPPED)"\n//g' "$ACTION_FILE"
    echo '[-] Action.kt: removed constants (if present)'

    # 2) ControlReceiver.kt: delete
    if [ -f "$RECEIVER_FILE" ]; then rm -f "$RECEIVER_FILE"; echo '[-] deleted ControlReceiver.kt'; else echo '[=] ControlReceiver.kt not present'; fi

    # 3) AndroidManifest.xml: remove the <receiver> block
    perl -0777 -i -pe 's/[ \t]*<receiver\s+android:name="\.bg\.ControlReceiver".*?<\/receiver>[ \t]*\n(\n)?//s' "$MANIFEST_FILE"
    echo '[-] AndroidManifest.xml: removed ControlReceiver (if present)'

    # 3b) START_STICKY -> START_NOT_STICKY
    perl -i -pe 's/^(\s+)return Service\.START_STICKY(\s*)$/$1return Service.START_NOT_STICKY$2/' "$BOX_FILE"
    echo '[-] BoxService.kt: restored START_NOT_STICKY (if present)'

    # 3c/3d) BoxService.kt
    perl -0777 -i -pe 's/^[ \t]+\@Volatile var stoppingForUpdate = false\n\n[ \t]+fun stopForUpdate\(\) \{\n[ \t]+stoppingForUpdate = true\n[ \t]+stop\(\)\n[ \t]+\}\n\n//m' "$BOX_FILE"
    BC="$BC_STARTED"      perl -0777 -i -pe 's/^[ \t]+\Q$ENV{BC}\E\n//m' "$BOX_FILE"
    BC="$BC_STOPPED_USER" perl -0777 -i -pe 's/^[ \t]+\Q$ENV{BC}\E\n//m' "$BOX_FILE"
    BC="$BC_STOPPED_ERR"  perl -0777 -i -pe 's/^[ \t]+\Q$ENV{BC}\E\n//m' "$BOX_FILE"
    perl -0777 -i -pe 's/^([ \t]+)if \(!stoppingForUpdate\) Settings\.startedByUser = false\n[ \t]+stoppingForUpdate = false\n/${1}Settings.startedByUser = false\n/m' "$BOX_FILE"
    echo '[-] BoxService.kt: removed state broadcasts / stopForUpdate (if present)'
    for f in "${INSTALLER_FILES[@]}"; do
        [ -f "$f" ] || continue
        perl -i -pe 's/BoxService\.stopForUpdate\(\)/BoxService.stop()/g' "$f"
    done
    echo '[-] ApkInstaller.kt: restored BoxService.stop() (if present)'

    # 4) GitHubUpdateChecker.kt: point the updater back at upstream
    if [ -f "$UPDATER_FILE" ]; then
        UPSTREAM_REPO="$UPSTREAM_REPO" perl -0777 -i -pe 's{(RELEASES_URL\s*=\s*"https://api\.github\.com/repos/)[^"/]+/[^"/]+(/releases")}{${1}$ENV{UPSTREAM_REPO}${2}}' "$UPDATER_FILE"
        echo "[-] GitHubUpdateChecker.kt: updater restored to $UPSTREAM_REPO (if present)"
    fi
}

if [ "$REVERT" -eq 1 ]; then
    echo '>>> reverting patch...'
    revert_patch
else
    echo '>>> applying patch...'
    apply_patch
fi

echo ''
echo '=== current state ==='
st() { if "$@" >/dev/null 2>&1; then echo applied; else echo absent; fi; }
echo "  Action.kt constants : $(st grep -q 'SERVICE_STOPPED' "$ACTION_FILE")"
echo "  ControlReceiver.kt  : $(st test -f "$RECEIVER_FILE")"
echo "  Manifest receiver   : $(st grep -q 'ControlReceiver' "$MANIFEST_FILE")"
echo "  START_STICKY        : $(st grep -Eq '^[[:space:]]+return Service\.START_STICKY[[:space:]]*$' "$BOX_FILE")"
echo "  State broadcasts    : $(st grep -qF "$BC_STARTED" "$BOX_FILE")"
echo "  stopForUpdate       : $(st grep -q 'BoxService.stopForUpdate()' "$REPO_ROOT/app/src/other/java/io/nekohasekai/sfa/vendor/ApkInstaller.kt")"
CUR="$(updater_repo)"
if [ -z "$CUR" ]; then echo '  Updater releases    : (file not found)'
elif [ "$CUR" = "$UPSTREAM_REPO" ]; then echo "  Updater releases    : upstream ($CUR)"
else echo "  Updater releases    : $CUR"; fi
