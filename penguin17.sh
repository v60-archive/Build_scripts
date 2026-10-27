#!/bin/bash
# Set build username/host environments
export BUILD_USERNAME="kiyomi"
export BUILD_HOSTNAME="yuki"
export KBUILD_BUILD_USER="kiyomi"
export KBUILD_BUILD_HOST="yuki"

echo "========================================="
echo "Syncing Manifests & Repositories..."
echo "========================================="

# Clear local manifests & re-init
rm -rf .repo/local_manifests external/rust/crates external/rust/android-crates-io external/python/cpython2
repo init -u https://github.com/Project-PenguinOS/manifest -b celerity --git-lfs --depth 1
git clone https://github.com/v60-archive/manifest --depth 1 -b penguin17 .repo/local_manifests

# Resync trees
/opt/crave/resync.sh || repo sync -c --no-clone-bundle --no-tags --optimized-fetch --prune --force-sync

cd build/soong
git remote add custom https://github.com/v60-archive/build_soong.git
git fetch custom
git reset --hard custom/penguin17
cd ../..

# Patch boot jars list
#printf '%s\n' 'com\.lge' 'com\.lge\..*' >> build/soong/scripts/check_boot_jars/package_allowed_list.txt

# Source build env
source build/envsetup.sh

# =========================================================
# BUILD EXECUTION & LOGGING
# =========================================================
echo "========================================="
echo "Starting ROM Compilation..."
echo "========================================="

./rom-build.sh timelm

