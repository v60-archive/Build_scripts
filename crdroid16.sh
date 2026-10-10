#!/bin/bash

# =========================================================
# LOAD SECRETS (.secrets in $HOME or current dir)
# =========================================================
if [ -f "$HOME/.secrets" ]; then
    source "$HOME/.secrets"
    echo "✅ Loaded secrets from $HOME/.secrets"
elif [ -f "$(pwd)/.secrets" ]; then
    source "$(pwd)/.secrets"
    echo "✅ Loaded secrets from $(pwd)/.secrets"
else
    echo "⚠️  No secrets file found — Telegram and Pixeldrain will be disabled"
fi


# ---------------------------------------------------------
# CONFIG
# ---------------------------------------------------------
TG_ENABLED=1              # set to 0 to disable all Telegram notifications
PD_ENABLED=1              # set to 0 to disable all Pixeldrain uploads

DEVICE="timelm"
ROM_NAME="crDroid 16.0"

BUILD_ID="$(date +%Y%m%d-%H%M)-$$"
LOG_FILE="log.txt"
MAIN_PID=$$
SCRIPT_START=$(date +%s)

PROGRESS_PING_INTERVAL=900

# Verify secrets loaded (prints lengths only, never values)
if [ -z "${PD_KEY:-}" ]; then echo "⚠️  PD_KEY not set"; else echo "    PD_KEY: ${#PD_KEY} chars"; fi
if [ -z "${TG_TOKEN:-}" ]; then echo "⚠️  TG_TOKEN not set"; else echo "    TG_TOKEN: ${#TG_TOKEN} chars"; fi
if [ -z "${TG_CHAT:-}" ]; then echo "⚠️  TG_CHAT not set"; else echo "    TG_CHAT: ${TG_CHAT}"; fi

# =========================================================
# TELEGRAM
# =========================================================
tg_send() {
    local msg="$1"
    [ "${TG_ENABLED:-1}" = "0" ] && return 0
    if [ -z "${TG_TOKEN:-}" ]; then
        echo "⚠️  [tg] TG_TOKEN not set — skipping notification"
        return 0
    fi
    local resp
    resp=$(curl -s --show-error --max-time 10 --connect-timeout 5 \
        -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT}" \
        -d parse_mode="HTML" \
        -d disable_web_page_preview=true \
        --data-urlencode "text=${msg}" 2>/dev/null || echo '{}')
    if echo "$resp" | grep -q '"ok":true'; then
        echo "✅ [tg] Notification sent"
    else
        echo "⚠️  [tg] Notification failed (continuing)"
    fi
    return 0
}

tg_notify() {
    tg_send "[<code>${BUILD_ID:-unknown}</code>] $1"
}

tg_stage() {
    local label="$1"
    local now=$(date +%s)
    local elapsed=$(( (now - SCRIPT_START) / 60 ))
    tg_notify "$label <i>[+${elapsed}m]</i>"
}

# =========================================================
# BUILD USER/HOST
# =========================================================
export BUILD_USERNAME="Gimhan"
export BUILD_HOSTNAME="Crave"
export KBUILD_BUILD_USER="Gimhan"
export KBUILD_BUILD_HOST="Crave"

echo "========================================="
echo "Syncing Manifests & Repositories..."
echo "Build ID: ${BUILD_ID}"
echo "========================================="

tg_notify "🏁 <b>Build script started</b>
Device: <code>${DEVICE}</code>
ROM: ${ROM_NAME}
Host: ${BUILD_HOSTNAME}"

# Git identity
echo "--> Setting git identity"
git config --global user.name "Gimhan"
git config --global user.email "Gimhan@build.local"
echo "    identity: $(git config --global user.name) <$(git config --global user.email)>"

# Do Your Modifications here gimhan and shiroi
# Clear local manifests & re-init
echo "--> repo init"
rm -rf .repo/local_manifests
tg_stage "📥 <b>repo init started</b>"
if ! repo init -u https://github.com/crdroidandroid/android.git -b 16.0 --no-clone-bundle --depth=1 --git-lfs; then
    echo "❌ repo init FAILED"
    tg_notify "❌ <b>Build failed</b> — ${DEVICE}
Stage: repo init"
    exit 1
fi
echo "    repo init OK"
tg_stage "✅ repo init done"

echo "--> local_manifests clone"
if ! git clone https://github.com/s0711482299-lgtm/manifest --depth 1 -b crdroid-timelm .repo/local_manifests; then
    echo "❌ local_manifests clone FAILED"
    tg_notify "❌ <b>Build failed</b> — ${DEVICE}
Stage: local_manifests clone"
    exit 1
fi
echo "    overlay OK"
tg_stage "✅ local_manifests cloned"

# Resync trees
echo "--> repo sync"
SYNC_START=$(date +%s)
tg_notify "📦 <b>repo sync</b> started"
if /opt/crave/resync.sh || repo sync -c --no-clone-bundle --no-tags --optimized-fetch --prune --force-sync; then
    SYNC_END=$(date +%s)
    SYNC_MIN=$(( (SYNC_END - SYNC_START) / 60 ))
    echo "    sync OK"
    tg_stage "✅ repo sync done (${SYNC_MIN} min)"
else
    echo "❌ repo sync FAILED"
    tg_notify "❌ <b>Build failed</b> — ${DEVICE}
Stage: repo sync"
    exit 1
fi

# Patch boot jars list
printf '%s\n' 'com\.lge' 'com\.lge\..*' >> build/soong/scripts/check_boot_jars/package_allowed_list.txt
tg_stage "✅ boot-jars patch applied"

# Source build env
source build/envsetup.sh
tg_stage "✅ envsetup sourced"

# =========================================================
# BUILD EXECUTION & LOGGING
# =========================================================
echo "========================================="
echo "Starting ROM Compilation..."
echo "========================================="

BUILD_START=$(date +%s)
tg_notify "🚀 <b>ROM compilation started</b>
Device: <code>${DEVICE}</code>"

# Background progress pinger
(
    LAST_PING=$BUILD_START
    for i in $(seq 1 60); do
        [ -f "${LOG_FILE}" ] && break
        sleep 1
    done
    while true; do
        sleep 60
        kill -0 "$MAIN_PID" 2>/dev/null || exit 0
        touch /tmp/pinger-alive 2>/dev/null || true

        NOW=$(date +%s)
        if [ $((NOW - LAST_PING)) -ge $PROGRESS_PING_INTERVAL ]; then
            ELAPSED_MIN=$(( (NOW - BUILD_START) / 60 ))
            LAST_LINE=$(tail -1 "${LOG_FILE}" 2>/dev/null | cut -c1-100)
            LAST_LINE_ESC=$(printf '%s' "$LAST_LINE" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g;')
            LOG_LINES=$(wc -l < "${LOG_FILE}" 2>/dev/null || echo 0)
            tg_notify "⏳ <b>Build running</b> — ${ELAPSED_MIN} min
Lines: ${LOG_LINES}
Last: <code>${LAST_LINE_ESC}</code>"
            LAST_PING=$NOW
        fi
    done
) &
PINGER_PID=$!
echo "    progress pinger running (pid ${PINGER_PID})"

lunch lineage_timelm-bp4a-userdebug
m installclean

# Run main target and stream log
m bacon 2>&1 | tee "${LOG_FILE}"
# DONT MAKE ANY MODIFICATIONS BEYOND THIS POINT
BUILD_STATUS=${PIPESTATUS[0]:-1}

# Stop pinger
if [ -n "${PINGER_PID:-}" ]; then
    kill "$PINGER_PID" 2>/dev/null || true
    sleep 1
    kill -9 "$PINGER_PID" 2>/dev/null || true
fi
rm -f /tmp/pinger-alive 2>/dev/null || true

BUILD_END=$(date +%s)
BUILD_MIN=$(( (BUILD_END - BUILD_START) / 60 ))
tg_stage "🏗️ <b>m bacon exited</b> (status=${BUILD_STATUS}, ${BUILD_MIN} min)"

# =========================================================
# SUCCESS OR FAILURE HANDLING
# =========================================================
if [ "${BUILD_STATUS:-1}" -eq 0 ]; then
    echo "========================================="
    echo "✅ Build Completed Successfully!"
    echo "========================================="
    tg_notify "✅ <b>Build succeeded</b> — locating artifacts..."

    ROM_ZIP=""
    RECOVERY_IMG=""
    PD_ID=""
    PD_REC_ID=""
    ZIP_SIZE=""
    REC_SIZE=""

    # ---------- Locate ROM zip ----------
    ROM_ZIP=$(find out/target/product/ -mindepth 2 -maxdepth 4 -type f -name "*.zip" ! -name "*ota*" ! -name "*target_files*" 2>/dev/null | head -n 1)

    # ---------- Locate recovery image ----------
    for candidate in \
        "out/target/product/${DEVICE}/recovery.img" \
        "out/target/product/${DEVICE}/boot.img"
    do
        [ -f "$candidate" ] && RECOVERY_IMG="$candidate" && break
    done

    # ---------- Upload ROM ----------
    if [ -n "$ROM_ZIP" ] && [ -f "$ROM_ZIP" ]; then
        ZIP_SIZE=$(du -h "$ROM_ZIP" | cut -f1)
        echo "--> Found ROM artifact: $ROM_ZIP (${ZIP_SIZE})"
        tg_stage "📦 ROM found: <code>$(basename "$ROM_ZIP")</code> (${ZIP_SIZE})"

        if [ "${PD_ENABLED:-1}" = "0" ]; then
            echo "⚠️  [pd] PD_ENABLED=0 — skipping ROM upload"
        elif [ -n "${PD_KEY:-}" ]; then
            echo "📤 Uploading ROM to Pixeldrain..."
            tg_notify "📤 <b>Uploading ROM to Pixeldrain...</b>"
            RESPONSE=$(curl -s --max-time 3600 -u ":$PD_KEY" -T "$ROM_ZIP" "https://pixeldrain.com/api/file/" 2>/dev/null || echo '{}')
            PD_ID=$(echo "$RESPONSE" | jq -r '.id' 2>/dev/null || true)
        else
            echo "⚠️  [pd] PD_KEY not set — skipping ROM upload"
        fi

        if [ -n "$PD_ID" ] && [ "$PD_ID" != "null" ]; then
            echo "✅ ROM: https://pixeldrain.com/u/$PD_ID"
        else
            echo "⚠️ ROM upload failed or skipped."
        fi
    else
        echo "❌ Error: Could not locate compiled .zip file"
    fi

    # ---------- Upload recovery ----------
    if [ -n "$RECOVERY_IMG" ] && [ -f "$RECOVERY_IMG" ]; then
        REC_SIZE=$(du -h "$RECOVERY_IMG" | cut -f1)
        echo "--> Found recovery image: $RECOVERY_IMG (${REC_SIZE})"
        tg_stage "🛠️ Recovery found: <code>$(basename "$RECOVERY_IMG")</code> (${REC_SIZE})"

        if [ "${PD_ENABLED:-1}" = "0" ]; then
            echo "⚠️  [pd] PD_ENABLED=0 — skipping recovery upload"
        elif [ -n "${PD_KEY:-}" ]; then
            echo "📤 Uploading recovery to Pixeldrain..."
            tg_notify "📤 <b>Uploading recovery to Pixeldrain...</b>"
            RESPONSE=$(curl -s --max-time 3600 -u ":$PD_KEY" -T "$RECOVERY_IMG" "https://pixeldrain.com/api/file/" 2>/dev/null || echo '{}')
            PD_REC_ID=$(echo "$RESPONSE" | jq -r '.id' 2>/dev/null || true)
        else
            echo "⚠️  [pd] PD_KEY not set — skipping recovery upload"
        fi

        if [ -n "$PD_REC_ID" ] && [ "$PD_REC_ID" != "null" ]; then
            echo "✅ Recovery: https://pixeldrain.com/u/$PD_REC_ID"
        else
            echo "⚠️ Recovery upload failed or skipped."
        fi
    else
        echo "--> No recovery image found (checked recovery.img and boot.img)"
    fi

    # ---------- Final success notification ----------
    DURATION_MIN=$(( (BUILD_END - BUILD_START) / 60 ))

    MSG="✅ <b>Build successful</b>
Device: <code>${DEVICE}</code>
Duration: ${DURATION_MIN} min"

    if [ -n "$PD_ID" ] && [ "$PD_ID" != "null" ]; then
        MSG="${MSG}
ROM: ${ZIP_SIZE:-?} — https://pixeldrain.com/u/${PD_ID}"
    fi

    if [ -n "$PD_REC_ID" ] && [ "$PD_REC_ID" != "null" ]; then
        MSG="${MSG}
Recovery: ${REC_SIZE:-?} — https://pixeldrain.com/u/${PD_REC_ID}"
    fi

    tg_notify "$MSG"

else
    echo "========================================="
    echo "❌ Build Failed! Extracting Error Context..."
    echo "========================================="
    tg_notify "❌ <b>Build failed</b> — extracting error context..."

    ERROR_LINE=$(grep -n -i -E "ERROR:|FAILED:|ninja: build stopped|fatal error" "${LOG_FILE}" 2>/dev/null | tail -n 1 | cut -d: -f1)

    if [ -n "$ERROR_LINE" ]; then
        START_LINE=$((ERROR_LINE - 100))
        [ $START_LINE -lt 1 ] && START_LINE=1
        END_LINE=$((ERROR_LINE + 100))
        sed -n "${START_LINE},${END_LINE}p" "${LOG_FILE}" > error_snippet.log
        tg_stage "🔍 Error at log line ${ERROR_LINE}"
    else
        tail -n 500 "${LOG_FILE}" > error_snippet.log 2>/dev/null || true
        tg_stage "🔍 No explicit error marker — using last 500 lines"
    fi
    echo "" >> error_snippet.log
    echo "--- last 50 lines of full log ---" >> error_snippet.log
    tail -n 50 "${LOG_FILE}" >> error_snippet.log 2>/dev/null || true

    echo "--- Error Context (uploaded below) ---"
    head -20 error_snippet.log
    echo "------------------------------------------------"

    # ---------- Upload error log ----------
    PD_ID=""
    if [ "${PD_ENABLED:-1}" = "0" ]; then
        echo "⚠️  [pd] PD_ENABLED=0 — skipping error log upload"
    elif [ -n "${PD_KEY:-}" ]; then
        echo "📤 Uploading Error Log to Pixeldrain..."
        tg_notify "📤 <b>Uploading error log...</b>"
        RESPONSE=$(curl -s --max-time 300 -u ":$PD_KEY" -T "error_snippet.log" "https://pixeldrain.com/api/file/" 2>/dev/null || echo '{}')
        PD_ID=$(echo "$RESPONSE" | jq -r '.id' 2>/dev/null || true)
    else
        echo "⚠️  [pd] PD_KEY not set — skipping error log upload"
    fi

    if [ -n "$PD_ID" ] && [ "$PD_ID" != "null" ]; then
        echo "-----------------------------------------"
        echo "✅ Error Log Uploaded Successfully!"
        echo "🔗 Link: https://pixeldrain.com/u/$PD_ID"
        echo "-----------------------------------------"

        DURATION_MIN=$(( (BUILD_END - BUILD_START) / 60 ))
        tg_notify "❌ <b>Build failed</b> — ${DEVICE}
Duration: ${DURATION_MIN} min
Error log: https://pixeldrain.com/u/${PD_ID}"
    else
        echo "⚠️ Error log upload failed or not configured."
        DURATION_MIN=$(( (BUILD_END - BUILD_START) / 60 ))
        tg_notify "❌ <b>Build failed</b> — ${DEVICE}
Duration: ${DURATION_MIN} min"
    fi
fi

# Build metadata
BUILD_END=$(date +%s)
cat > build-meta.json <<EOF
{
  "build_id": "${BUILD_ID}",
  "device": "${DEVICE}",
  "rom": "${ROM_NAME}",
  "started_ts": ${BUILD_START},
  "finished_ts": ${BUILD_END},
  "duration_sec": $(( BUILD_END - BUILD_START )),
  "status": "$([ "${BUILD_STATUS:-1}" -eq 0 ] && echo success || echo failed)"
}
EOF
echo "--> Build metadata written to build-meta.json"
cat build-meta.json
tg_stage "🗂️ build-meta.json written"

echo ""
echo "========================================="
echo "Done. Build ID: ${BUILD_ID}"
echo "========================================="
tg_notify "🏁 <b>Script done</b> — total $(( (BUILD_END - SCRIPT_START) / 60 )) min"
