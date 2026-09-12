#!/usr/bin/env bash
#
# apply-tasker-control-patch.sh
#
# Patches a sing-box-for-android source tree so that:
#   1-3) an EXPORTED broadcast receiver (ControlReceiver) lets Tasker (direct
#        Intent, or `am broadcast` via Shizuku/rish) start/stop the proxy while
#        the screen is off / locked / in the background;
#   4)   (optional, --update-repo) the app's built-in GitHub updater checks
#        YOUR repository's Releases instead of SagerNet/sing-box, so the phone
#        self-updates from your own auto-built APKs.
#
# Intended for CI: the GitHub Actions workflow checks out upstream source fresh
# and runs this at build time only, so nothing here is ever committed to a
# fork. It also runs locally in git-bash for a local build.
#
# Usage:
#   bash apply-tasker-control-patch.sh                                  # apply 1-3 (idempotent)
#   bash apply-tasker-control-patch.sh --update-repo OWNER/REPO         # apply 1-4
#   bash apply-tasker-control-patch.sh --revert                         # remove everything
#   bash apply-tasker-control-patch.sh --repo-root DIR ...              # point at a tree elsewhere
#   SFA_UPDATE_REPO=OWNER/REPO bash apply-tasker-control-patch.sh       # same as --update-repo
#
# Design: anchors only on stable landmarks (`object Action {`, `</application>`,
# the bg package dir, the RELEASES_URL constant) -- never line numbers -- so it
# keeps working after upstream source upgrades. ASCII-only on purpose.
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
UPDATER_FILE="$REPO_ROOT/app/src/github/java/io/nekohasekai/sfa/vendor/GitHubUpdateChecker.kt"
UPSTREAM_REPO="SagerNet/sing-box"

for f in "$ACTION_FILE" "$MANIFEST_FILE"; do
    if [ ! -f "$f" ]; then
        echo "Not found: $f" >&2
        echo "Run from the repo root, or pass --repo-root DIR." >&2
        exit 1
    fi
done

# Prints OWNER/REPO the updater currently points at, or nothing if unknown. Never fails.
updater_repo() {
    [ -f "$UPDATER_FILE" ] || return 0
    grep -Eo 'RELEASES_URL[[:space:]]*=[[:space:]]*"https://api\.github\.com/repos/[^"/]+/[^"/]+/releases"' "$UPDATER_FILE" \
        | sed -E 's#.*/repos/([^"/]+/[^"/]+)/releases".*#\1#' | head -n1 || true
}

apply_patch() {
    # 1) Action.kt: insert the two constants right after `object Action {`
    if grep -q 'SERVICE_START' "$ACTION_FILE"; then
        echo '[=] Action.kt already has the constants, skipping'
    else
        perl -0777 -i -pe 's/(object\s+Action\s*\{[^\n]*\n)/$1    const val SERVICE_START = "io.nekohasekai.sfa.SERVICE_START"\n    const val SERVICE_STOP = "io.nekohasekai.sfa.SERVICE_STOP"\n/' "$ACTION_FILE"
        if ! grep -q 'SERVICE_START' "$ACTION_FILE"; then
            echo "Anchor 'object Action {' not found in Action.kt; patch by hand." >&2
            exit 1
        fi
        echo '[+] Action.kt: inserted SERVICE_START / SERVICE_STOP'
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
        if ! grep -q 'ControlReceiver' "$MANIFEST_FILE"; then
            echo "Anchor '</application>' not found in AndroidManifest.xml; patch by hand." >&2
            exit 1
        fi
        echo '[+] AndroidManifest.xml: inserted ControlReceiver'
    fi

    # Soft check: do BoxService.start()/stop() still exist? (upstream rename/refactor)
    if [ -f "$BOX_FILE" ]; then
        if ! grep -Eq 'fun[[:space:]]+start[[:space:]]*\(' "$BOX_FILE" || ! grep -Eq 'fun[[:space:]]+stop[[:space:]]*\(' "$BOX_FILE"; then
            echo '[!] WARNING: BoxService.start()/stop() not found - upstream may have refactored; review ControlReceiver.kt.' >&2
        fi
    fi

    # 4) GitHubUpdateChecker.kt: point the built-in updater at OWNER/REPO (only if asked)
    if [ -n "$UPDATE_REPO" ]; then
        if [ ! -f "$UPDATER_FILE" ]; then
            echo "Not found: $UPDATER_FILE (needed for --update-repo); upstream may have moved it." >&2
            exit 1
        fi
        if [ "$(updater_repo)" = "$UPDATE_REPO" ]; then
            echo "[=] GitHubUpdateChecker.kt already points at $UPDATE_REPO, skipping"
        else
            UPDATE_REPO="$UPDATE_REPO" perl -0777 -i -pe 's{(RELEASES_URL\s*=\s*"https://api\.github\.com/repos/)[^"/]+/[^"/]+(/releases")}{${1}$ENV{UPDATE_REPO}${2}}' "$UPDATER_FILE"
            if [ "$(updater_repo)" != "$UPDATE_REPO" ]; then
                echo "Anchor 'RELEASES_URL = \"https://api.github.com/repos/.../releases\"' not found in GitHubUpdateChecker.kt; patch by hand." >&2
                exit 1
            fi
            echo "[+] GitHubUpdateChecker.kt: updater now reads releases of $UPDATE_REPO"
        fi
    fi
}

revert_patch() {
    # 1) Action.kt: remove the two constants
    if [ -f "$ACTION_FILE" ]; then
        perl -0777 -i -pe 's/[ \t]*const val SERVICE_START = "io\.nekohasekai\.sfa\.SERVICE_START"\n//; s/[ \t]*const val SERVICE_STOP = "io\.nekohasekai\.sfa\.SERVICE_STOP"\n//' "$ACTION_FILE"
        echo '[-] Action.kt: removed constants (if present)'
    fi

    # 2) ControlReceiver.kt: delete
    if [ -f "$RECEIVER_FILE" ]; then
        rm -f "$RECEIVER_FILE"
        echo '[-] deleted ControlReceiver.kt'
    else
        echo '[=] ControlReceiver.kt not present'
    fi

    # 3) AndroidManifest.xml: remove the <receiver> block
    if [ -f "$MANIFEST_FILE" ]; then
        perl -0777 -i -pe 's/[ \t]*<receiver\s+android:name="\.bg\.ControlReceiver".*?<\/receiver>[ \t]*\n(\n)?//s' "$MANIFEST_FILE"
        echo '[-] AndroidManifest.xml: removed ControlReceiver (if present)'
    fi

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
if grep -q 'SERVICE_START' "$ACTION_FILE" 2>/dev/null; then echo '  Action.kt constants : applied'; else echo '  Action.kt constants : absent'; fi
if [ -f "$RECEIVER_FILE" ]; then echo '  ControlReceiver.kt  : applied'; else echo '  ControlReceiver.kt  : absent'; fi
if grep -q 'ControlReceiver' "$MANIFEST_FILE" 2>/dev/null; then echo '  Manifest receiver   : applied'; else echo '  Manifest receiver   : absent'; fi
CUR="$(updater_repo)"
if [ -z "$CUR" ]; then echo '  Updater releases    : (file not found)'
elif [ "$CUR" = "$UPSTREAM_REPO" ]; then echo "  Updater releases    : upstream ($CUR)"
else echo "  Updater releases    : $CUR"; fi
