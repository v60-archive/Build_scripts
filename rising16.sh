#!/bin/bash

# =========================================================
# LOAD SECRETS (.secrets in $HOME or current dir)
# =========================================================
if [ -f "$HOME/.secrets" ]; then
    source "$HOME/.secrets"
elif [ -f "$(pwd)/.secrets" ]; then
    source "$(pwd)/.secrets"
fi

# Search for either key variant in .secrets
PD_KEY="${PIXELDRAIN_API_KEY:-$PD_API_KEY}"

# Set build username/host environments
export BUILD_USERNAME="Gimhan"
export BUILD_HOSTNAME="Crave"
export KBUILD_BUILD_USER="Gimhan"
export KBUILD_BUILD_HOST="Crave"

echo "========================================="
echo "Syncing Manifests & Repositories..."
echo "========================================="

# Do Your Modifications here gimhan and shiroi
# Clear local manifests & re-init
rm -rf .repo/local_manifests
repo init -u https://github.com/s0711482299-lgtm/android -b sixteen --no-clone-bundle --depth=1 --git-lfs
git clone https://github.com/s0711482299-lgtm/manifest -b rising-timelm --depth 1 .repo/local_manifests

# Resync trees
/opt/crave/resync.sh || repo sync -c --no-clone-bundle --no-tags --optimized-fetch --prune --force-sync

# Patch boot jars list
printf '%s\n' 'com\.lge' 'com\.lge\..*' >> build/soong/scripts/check_boot_jars/package_allowed_list.txt

# Source build env
source build/envsetup.sh

# =========================================================
# BUILD EXECUTION & LOGGING
# =========================================================
echo "========================================="
echo "Starting ROM Compilation..."
echo "========================================="

riseup timelm userdebug
m installclean

# Run main target and stream log
rise b 2>&1 | tee log.txt
# DONT MAKE ANY MODIFICATIONS BEYOND THIS POINT
BUILD_STATUS=${PIPESTATUS[0]}

# =========================================================
# SUCCESS OR FAILURE HANDLING
# =========================================================
if [ $BUILD_STATUS -eq 0 ]; then
    echo "========================================="
    echo "✅ Build Completed Successfully!"
    echo "========================================="
    
    # Corrected maxdepth to 4 to reach out/target/product/timelm/*.zip
    ROM_ZIP=$(find out/target/product/ -mindepth 2 -maxdepth 4 -type f -name "*.zip" ! -name "*ota*" ! -name "*target_files*" | head -n 1)

    if [ -n "$ROM_ZIP" ] && [ -f "$ROM_ZIP" ]; then
        echo "--> Found ROM artifact: $ROM_ZIP"
        echo "📤 Uploading ROM to Pixeldrain..."

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
        else
            echo "⚠️ ROM Upload to Pixeldrain failed."
            echo "Response: $RESPONSE"
        fi
    else
        echo "❌ Error: Could not locate compiled .zip file in out/target/product/"
    fi

else
    echo "========================================="
    echo "❌ Build Failed! Extracting Error Context..."
    echo "========================================="

    # Get the LAST matching error line instead of the first
    ERROR_LINE=$(grep -n -i -E "ERROR:|FAILED:" log.txt | tail -n 1 | cut -d: -f1)

    if [ -n "$ERROR_LINE" ]; then
        START_LINE=$((ERROR_LINE - 100))
        [ $START_LINE -lt 1 ] && START_LINE=1
        END_LINE=$((ERROR_LINE + 100))

        # Extract 100 lines before and after the critical error
        sed -n "${START_LINE},${END_LINE}p" log.txt > error_snippet.log
    else
        # Fallback to last 200 lines if no explicit pattern hit
        tail -n 200 log.txt > error_snippet.log
    fi

    echo "--- Error Context (100 lines before & after) ---"
    cat error_snippet.log
    echo "------------------------------------------------"

    # Upload error snippet
    echo "========================================="
    echo "📤 Uploading Error Log to Pixeldrain..."
    echo "========================================="

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
    else
        echo "⚠️ Error log upload failed or API key missing."
        echo "Response: $RESPONSE"
    fi
fi
