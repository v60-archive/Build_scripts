#!/bin/bash

# =========================================================
# LOAD SECRETS (.secrets in $HOME or current dir)
# =========================================================
#if [ -f "$HOME/.secrets" ]; then
#    source "$HOME/.secrets"
#elif [ -f "$(pwd)/.secrets" ]; then
#    source "$(pwd)/.secrets"
#fi

# ---------------------------------------------------------
# CONFIG
# ---------------------------------------------------------
PD_KEY="9e2aacb7-e7b0-4941-84a4-160d6be7bf99"

# Telegram
TG_TOKEN="8841388263:AAG9Q7QuB4zpLjhxgnM7VzSquKnrj7KKA14"
TG_CHAT="6684997865"
TG_ENABLED=1              # set to 0 to disable all notifications

DEVICE="timelm"
ROM_NAME="Bliss 19.6"

BUILD_ID="$(date +%Y%m%d-%H%M)-$$"
LOG_FILE="log.txt"
MAIN_PID=$$
SCRIPT_START=$(date +%s)

PROGRESS_PING_INTERVAL=900

# =========================================================
# TELEGRAM
# =========================================================
tg_send() {
    local msg="$1"
    [ "${TG_ENABLED:-1}" = "0" ] && return 0
    if [ -z "${TG_TOKEN:-}" ] || [ "$TG_TOKEN" = "PASTE_YOUR_BOT_TOKEN_HERE" ]; then
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

# Set build username/host environments
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
Build ID: <code>${BUILD_ID}</code>
Host: ${BUILD_HOSTNAME}
Time: $(date -u '+%Y-%m-%d %H:%M UTC')"

# Git identity
echo "--> Setting git identity"
git config --global user.name "Gimhan"
git config --global user.email "gimhan@build.local"
echo "    identity: $(git config --global user.name) <$(git config --global user.email)>"

# Do Your Modifications here gimhan and shiroi
# Clear local manifests & re-init
echo "--> repo init"
rm -rf .repo/local_manifests
tg_stage "📥 <b>repo init started</b>"
if ! repo init --depth=1 -u https://github.com/s0711482299-lgtm/stable_releases.git -b waterlily-qpr2 --git-lfs; then
    echo "❌ repo init FAILED"
    tg_notify "❌ <b>Build failed</b> — ${DEVICE}
Stage: repo init"
    exit 1
fi
echo "    repo init OK"
tg_stage "✅ repo init done"

echo "--> local_manifests clone"
if ! git clone https://github.com/s0711482299-lgtm/manifest -b Bliss-timelm --depth 1 .repo/local_manifests; then
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
Device: <code>${DEVICE}</code>
ROM: ${ROM_NAME}
Time: $(date -u '+%Y-%m-%d %H:%M UTC')"

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

# Run main target and stream log
blissify -v timelm 2>&1 | tee "${LOG_FILE}"
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
tg_stage "🏗️ <b>blissify exited</b> (status=${BUILD_STATUS}, ${BUILD_MIN} min)"

# =========================================================
# SUCCESS OR FAILURE HANDLING
# =========================================================
if [ "${BUILD_STATUS:-1}" -eq 0 ]; then
    echo "========================================="
    echo "✅ Build Completed Successfully!"
    echo "========================================="
    tg_notify "✅ <b>Build succeeded</b> — locating artifact..."

    # Corrected maxdepth to 4 to reach out/target/product/timelm/*.zip
    ROM_ZIP=$(find out/target/product/ -mindepth 2 -maxdepth 4 -type f -name "*.zip" ! -name "*ota*" ! -name "*target_files*" 2>/dev/null | head -n 1)

    if [ -n "$ROM_ZIP" ] && [ -f "$ROM_ZIP" ]; then
        ZIP_SIZE=$(du -h "$ROM_ZIP" | cut -f1)
        echo "--> Found ROM artifact: $ROM_ZIP (${ZIP_SIZE})"
        tg_stage "📦 Artifact found: <code>$(basename "$ROM_ZIP")</code> (${ZIP_SIZE})"
        echo "📤 Uploading ROM to Pixeldrain..."
        tg_notify "📤 <b>Uploading ROM to Pixeldrain...</b>"

        if [ -n "$PD_KEY" ]; then
            RESPONSE=$(curl -s --max-time 3600 -u ":$PD_KEY" -T "$ROM_ZIP" "https://pixeldrain.com/api/file/" 2>/dev/null || echo '{}')
        else
            RESPONSE=$(curl -s --max-time 3600 -T "$ROM_ZIP" "https://pixeldrain.com/api/file/" 2>/dev/null || echo '{}')
        fi

        PD_ID=$(echo "$RESPONSE" | jq -r '.id' 2>/dev/null || true)

        if [ -n "$PD_ID" ] && [ "$PD_ID" != "null" ]; then
            echo "-----------------------------------------"
            echo "✅ ROM Upload Successful!"
            echo "🔗 Link: https://pixeldrain.com/u/$PD_ID"
            echo "-----------------------------------------"

            DURATION_MIN=$(( (BUILD_END - BUILD_START) / 60 ))
            tg_notify "✅ <b>Build successful</b>
Device: <code>${DEVICE}</code>
Duration: ${DURATION_MIN} min
Size: ${ZIP_SIZE}
Download: https://pixeldrain.com/u/${PD_ID}"
        else
            echo "⚠️ ROM Upload to Pixeldrain failed."
            echo "Response: $RESPONSE"
            tg_notify "⚠️ <b>Build succeeded but upload failed</b> — ${DEVICE}"
        fi
    else
        echo "❌ Error: Could not locate compiled .zip file in out/target/product/"
        tg_notify "⚠️ <b>Build succeeded but no .zip found</b> — ${DEVICE}"
    fi

else
    echo "========================================="
    echo "❌ Build Failed! Extracting Error Context..."
    echo "========================================="
    tg_notify "❌ <b>Build failed</b> — extracting error context..."

    # Get the LAST matching error line instead of the first
    ERROR_LINE=$(grep -n -i -E "ERROR:|FAILED:|ninja: build stopped|fatal error" "${LOG_FILE}" 2>/dev/null | tail -n 1 | cut -d: -f1)

    if [ -n "$ERROR_LINE" ]; then
        START_LINE=$((ERROR_LINE - 100))
        [ $START_LINE -lt 1 ] && START_LINE=1
        END_LINE=$((ERROR_LINE + 100))
        # Extract 100 lines before and after the critical error
        sed -n "${START_LINE},${END_LINE}p" "${LOG_FILE}" > error_snippet.log
        tg_stage "🔍 Error at log line ${ERROR_LINE}"
    else
        # Fallback to last 500 lines if no explicit pattern hit
        tail -n 500 "${LOG_FILE}" > error_snippet.log 2>/dev/null || true
        tg_stage "🔍 No explicit error marker — using last 500 lines"
    fi
    echo "" >> error_snippet.log
    echo "--- last 50 lines of full log ---" >> error_snippet.log
    tail -n 50 "${LOG_FILE}" >> error_snippet.log 2>/dev/null || true

    echo "--- Error Context (uploaded below) ---"
    head -20 error_snippet.log
    echo "------------------------------------------------"

    # Upload error snippet
    echo "========================================="
    echo "📤 Uploading Error Log to Pixeldrain..."
    echo "========================================="
    tg_notify "📤 <b>Uploading error log...</b>"

    if [ -n "$PD_KEY" ]; then
        RESPONSE=$(curl -s --max-time 300 -u ":$PD_KEY" -T "error_snippet.log" "https://pixeldrain.com/api/file/" 2>/dev/null || echo '{}')
    else
        RESPONSE=$(curl -s --max-time 300 -T "error_snippet.log" "https://pixeldrain.com/api/file/" 2>/dev/null || echo '{}')
    fi

    PD_ID=$(echo "$RESPONSE" | jq -r '.id' 2>/dev/null || true)

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
        echo "⚠️ Error log upload failed or API key missing."
        echo "Response: $RESPONSE"
        DURATION_MIN=$(( (BUILD_END - BUILD_START) / 60 ))
        tg_notify "❌ <b>Build failed</b> (no log uploaded) — ${DEVICE}
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
