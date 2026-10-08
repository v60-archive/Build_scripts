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

TG_TOKEN="8841388263:AAG9Q7QuB4zpLjhxgnM7VzSquKnrj7KKA14"
TG_CHAT="6684997865"

DEVICE="timelm"
ROM_NAME="Bliss 19.6"

BUILD_ID="$(date +%Y%m%d-%H%M)-$$"
LOG_FILE="log.txt"
MAIN_PID=$$
SCRIPT_START=$(date +%s)

SYNC_RETRIES=3
SYNC_RETRY_DELAY=30

# Progress ping interval — reduced from 1800 to 900 (15 min)
PROGRESS_PING_INTERVAL=900

# =========================================================
# TELEGRAM
# =========================================================
tg_send() {
    local msg="$1"
    if [ -z "$TG_TOKEN" ] || [ "$TG_TOKEN" = "PASTE_YOUR_BOT_TOKEN_HERE" ]; then
        echo "⚠️  [tg] TG_TOKEN not set — skipping notification"
        return 0
    fi
    local resp
    resp=$(curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT}" \
        -d parse_mode="HTML" \
        -d disable_web_page_preview=true \
        --data-urlencode "text=${msg}")
    if echo "$resp" | grep -q '"ok":true'; then
        echo "✅ [tg] Notification sent"
    else
        echo "⚠️  [tg] Notification failed: $resp"
    fi
}

tg_notify() {
    tg_send "[<code>${BUILD_ID}</code>] $1"
}

# Stage helper — sends "stage complete" style pings with elapsed time
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
echo "[1/6] Syncing Manifests & Repositories..."
echo "Build ID: ${BUILD_ID}"
echo "========================================="

# ---- Stage: script start ----
tg_notify "🏁 <b>Build script started</b>
Device: <code>${DEVICE}</code>
ROM: ${ROM_NAME}
Build ID: <code>${BUILD_ID}</code>
Host: ${BUILD_HOSTNAME}
Time: $(date -u '+%Y-%m-%d %H:%M UTC')"

# ---------------------------------------------------------
# FIX: Pre-seed SSH host keys
# ---------------------------------------------------------
echo "--> [1a] Pre-seeding SSH host keys"
mkdir -p ~/.ssh
ssh-keyscan -H github.com gitlab.com >> ~/.ssh/known_hosts 2>/dev/null
chmod 600 ~/.ssh/known_hosts
echo "    done"

# ---------------------------------------------------------
# FIX: Rewrite SSH URLs to HTTPS
# ---------------------------------------------------------
echo "--> [1b] Configuring git SSH→HTTPS rewrite"
git config --global --unset-all url."https://github.com/".insteadOf 2>/dev/null || true
git config --global --unset-all url."https://gitlab.com/".insteadOf 2>/dev/null || true
git config --global url."https://github.com/".insteadOf "ssh://git@github.com/"
git config --global url."https://github.com/".insteadOf "git@github.com:"
git config --global url."https://gitlab.com/".insteadOf "ssh://git@gitlab.com/"
git config --global url."https://gitlab.com/".insteadOf "git@gitlab.com:"
echo "    active rewrites:"
git config --global --get-regexp 'url\.' | sed 's/^/      /'
tg_stage "🔧 SSH→HTTPS rewrite applied"

# Do Your Modifications here gimhan and shiroi
echo "--> [1c] Clearing local_manifests and running repo init"
rm -rf .repo/local_manifests
tg_stage "📥 <b>repo init started</b>"
if ! repo init --depth=1 -u https://github.com/BlissRoms/stable_releases.git -b refs/tags/v19.6.1-stable-waterlily --git-lfs; then
    echo "❌ [1c] repo init FAILED"
    tg_notify "❌ <b>Build failed</b> — ${DEVICE}
Stage: repo init"
    exit 1
fi
echo "    repo init OK"
tg_stage "✅ repo init done"

echo "--> [1d] Cloning local_manifests overlay"
if ! git clone https://github.com/s0711482299-lgtm/manifest -b Bliss-timelm --depth 1 .repo/local_manifests; then
    echo "❌ [1d] local_manifests clone FAILED"
    tg_notify "❌ <b>Build failed</b> — ${DEVICE}
Stage: local_manifests clone"
    exit 1
fi
echo "    overlay OK"
tg_stage "✅ local_manifests cloned"

echo "--> [1e] Syncing source trees (with up to ${SYNC_RETRIES} retries)"
SYNC_OK=0
SYNC_START=$(date +%s)
for attempt in $(seq 1 $SYNC_RETRIES); do
    echo "    sync attempt ${attempt}/${SYNC_RETRIES}"
    tg_notify "📦 <b>repo sync</b> attempt ${attempt}/${SYNC_RETRIES} started"
    if /opt/crave/resync.sh 2>/dev/null || \
       repo sync -c --no-clone-bundle --no-tags --optimized-fetch --prune --force-sync; then
        SYNC_OK=1
        break
    fi
    echo "    ⚠️  sync attempt ${attempt} failed — retrying in ${SYNC_RETRY_DELAY}s"
    tg_notify "⚠️ Sync attempt ${attempt}/${SYNC_RETRIES} failed — retrying in ${SYNC_RETRY_DELAY}s"
    sleep $SYNC_RETRY_DELAY
done

if [ $SYNC_OK -ne 1 ]; then
    echo "❌ [1e] repo sync FAILED after ${SYNC_RETRIES} attempts"
    tg_notify "❌ <b>Build failed</b> — ${DEVICE}
Stage: repo sync (all ${SYNC_RETRIES} attempts)"
    exit 1
fi
SYNC_END=$(date +%s)
SYNC_MIN=$(( (SYNC_END - SYNC_START) / 60 ))
echo "    sync OK"
tg_stage "✅ repo sync done (${SYNC_MIN} min)"

echo "--> [1f] Patching boot jars allowlist"
printf '%s\n' 'com\.lge' 'com\.lge\..*' >> build/soong/scripts/check_boot_jars/package_allowed_list.txt
echo "    done"
tg_stage "✅ boot-jars patch applied"

echo "--> [1g] Sourcing build/envsetup.sh"
source build/envsetup.sh
tg_stage "✅ envsetup sourced"

# =========================================================
# BUILD EXECUTION
# =========================================================
echo ""
echo "========================================="
echo "[2/6] Starting ROM Compilation..."
echo "========================================="

BUILD_START=$(date +%s)
tg_notify "🚀 <b>ROM compilation started</b>
Device: <code>${DEVICE}</code>
ROM: ${ROM_NAME}
Time: $(date -u '+%Y-%m-%d %H:%M UTC')"

# --- Background progress pinger ---
(
    LAST_PING=$BUILD_START
    while [ ! -f "${LOG_FILE}" ]; do sleep 5; done
    while true; do
        sleep 60
        [ -f "/proc/$$" ] || exit 0
        kill -0 $MAIN_PID 2>/dev/null || exit 0

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

blissify -v timelm 2>&1 | tee "${LOG_FILE}"
BUILD_STATUS=${PIPESTATUS[0]}
echo "--> blissify exit status: $BUILD_STATUS"

kill $PINGER_PID 2>/dev/null || true

BUILD_END=$(date +%s)
BUILD_MIN=$(( (BUILD_END - BUILD_START) / 60 ))
tg_stage "🏗️ <b>blissify exited</b> (status=${BUILD_STATUS}, ${BUILD_MIN} min)"

# =========================================================
# SUCCESS OR FAILURE HANDLING
# =========================================================
if [ $BUILD_STATUS -eq 0 ]; then
    echo ""
    echo "========================================="
    echo "[3/6] ✅ Build Completed Successfully!"
    echo "========================================="
    tg_notify "✅ <b>Build succeeded</b> — locating artifact..."

    echo "--> Locating ROM artifact"
    ROM_ZIP=$(find out/target/product/ -mindepth 2 -maxdepth 4 -type f -name "*.zip" ! -name "*ota*" ! -name "*target_files*" | head -n 1)

    if [ -n "$ROM_ZIP" ] && [ -f "$ROM_ZIP" ]; then
        ZIP_SIZE=$(du -h "$ROM_ZIP" | cut -f1)
        echo "    found: $ROM_ZIP (${ZIP_SIZE})"
        tg_stage "📦 Artifact found: <code>$(basename "$ROM_ZIP")</code> (${ZIP_SIZE})"
        echo ""
        echo "========================================="
        echo "[4/6] 📤 Uploading ROM to Pixeldrain..."
        echo "========================================="
        tg_notify "📤 <b>Uploading ROM to Pixeldrain...</b>"

        if [ -n "$PD_KEY" ]; then
            RESPONSE=$(curl -s -u ":$PD_KEY" -T "$ROM_ZIP" "https://pixeldrain.com/api/file/")
        else
            RESPONSE=$(curl -s -T "$ROM_ZIP" "https://pixeldrain.com/api/file/")
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
            tg_notify "⚠️ <b>Build succeeded but upload failed</b> — ${DEVICE}
Response: <code>${RESPONSE}</code>"
        fi
    else
        echo "❌ Error: Could not locate compiled .zip file in out/target/product/"
        tg_notify "⚠️ <b>Build succeeded but no .zip found</b> — ${DEVICE}"
    fi

else
    echo ""
    echo "========================================="
    echo "[3/6] ❌ Build Failed! Extracting Error Context..."
    echo "========================================="
    tg_notify "❌ <b>Build failed</b> — extracting error context..."

    echo "--> Scanning log for last error"
    ERROR_LINE=$(grep -n -i -E "ERROR:|FAILED:|ninja: build stopped|fatal error" "${LOG_FILE}" | tail -n 1 | cut -d: -f1)

    if [ -n "$ERROR_LINE" ]; then
        echo "    error found at line $ERROR_LINE"
        START_LINE=$((ERROR_LINE - 100))
        [ $START_LINE -lt 1 ] && START_LINE=1
        END_LINE=$((ERROR_LINE + 100))
        sed -n "${START_LINE},${END_LINE}p" "${LOG_FILE}" > error_snippet.log
        tg_stage "🔍 Error at log line ${ERROR_LINE}"
    else
        echo "    no explicit error found — using last 500 lines"
        tail -n 500 "${LOG_FILE}" > error_snippet.log
        tg_stage "🔍 No explicit error marker — using last 500 lines"
    fi
    echo "" >> error_snippet.log
    echo "--- last 50 lines of full log ---" >> error_snippet.log
    tail -n 50 "${LOG_FILE}" >> error_snippet.log

    echo "--- Error Context (uploaded below) ---"
    head -20 error_snippet.log
    echo "..."
    echo "------------------------------------------------"

    echo ""
    echo "========================================="
    echo "[4/6] 📤 Uploading Error Log to Pixeldrain..."
    echo "========================================="
    tg_notify "📤 <b>Uploading error log...</b>"

    if [ -n "$PD_KEY" ]; then
        RESPONSE=$(curl -s -u ":$PD_KEY" -T "error_snippet.log" "https://pixeldrain.com/api/file/")
    else
        RESPONSE=$(curl -s -T "error_snippet.log" "https://pixeldrain.com/api/file/")
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
  "status": "$([ $BUILD_STATUS -eq 0 ] && echo success || echo failed)"
}
EOF
echo "--> Build metadata written to build-meta.json"
cat build-meta.json
tg_stage "🗂️ build-meta.json written"

echo ""
echo "========================================="
echo "[6/6] Done. Build ID: ${BUILD_ID}"
echo "========================================="
tg_notify "🏁 <b>Script done</b> — total $(( (BUILD_END - SCRIPT_START) / 60 )) min"
