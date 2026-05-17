#!/bin/bash
set -o pipefail
set -u
shopt -s lastpipe

# ── CONFIG ────────────────────────────────────────────────────

BOT_TOKEN="8621768947:AAHWD7d_tNi_JJ29bSVTjiC6gXEkDuTRZxQ"
CHAT_ID="-1003937000666"
DEVICE_CODE="sky"
BUILD_HOSTNAME="topex"

# rm -rf / clone / anything — before repo init
PRE_INIT_CMDS=(
  # "rm -rf some/path"
  # "git clone https://github.com/foo/bar.git -b main some/path"
)

REPO_INIT_CMD="repo init -u https://github.com/VoltageOS/manifest.git -b 16.2 --git-lfs"

USE_REPO_SYNC=true
USE_CRAVE_RESYNC=true

REMOVE_PATHS=(
  "vendor/qcom/opensource/vibrator"
  "vendor/lineage-priv"
  "device/qcom/sepolicy_vndr/sm8450/"
)

CLONE_REPOS=(
  "https://github.com/anonytry/device_xiaomi_sky|.|device/xiaomi/sky"
  "https://github.com/anonytry/kernel_xiaomi_sky.git|temp|kernel/xiaomi/sky"
  "https://github.com/anonytry/android_vendor_qcom_opensource_vibrator.git|.|vendor/qcom/opensource/vibrator"
  "https://github.com/anonytry/device_qcom_sepolicy_vndr.git|.|device/qcom/sepolicy_vndr/sm8450/"
  "https://github.com/anonytry/vendor_extras|.|vendor/extras"
)

EXPORTS=(
  "ALLOW_MISSING_DEPENDENCIES=true"
  "SKIP_ABI_CHECKS=true"
  "SUVM=true"
  "VND=true"
)

EXTRA_CMDS=(
#"echo 'no' | bash <(curl -s https://raw.githubusercontent.com/anonytry/Signify/refs/heads/vos/Signify.sh)"
"rm -rf packages/apps/DolbyAtmos/preinstalled-packages-platform-dolby.xml"
)


KERNELSU_ENABLED=true
KERNELSU_PATH="kernel/xiaomi/sky"
KERNELSU_BRANCH="dev"

BUILD_CMD=". build/envsetup.sh && brunch sky user"

# ── END CONFIG ────────────────────────────────────────────────

export TZ="Asia/Kolkata"
export BUILD_HOSTNAME

for dep in curl jq repo git; do
  command -v "$dep" &>/dev/null || { echo "missing: $dep"; exit 1; }
done

send_msg() {
  curl -s --max-time 15 -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" \
    --data-urlencode text="$1" \
    -d parse_mode=HTML > /dev/null || echo "[warn] telegram send_msg failed" >&2
}

send_msg_id() {
  local id
  if ! id=$(curl -s --max-time 15 -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" \
    --data-urlencode text="$1" \
    -d parse_mode=HTML | jq -r '.result.message_id // empty'); then
    echo "[warn] telegram send_msg_id failed" >&2
  fi
  # fallback: 0 means failed — edit_msg guards against this
  printf '%s' "${id:-0}"
}

edit_msg() {
  # message_id=0 means send_msg_id failed — skip silently instead of bad API call
  [[ "$1" == "0" || -z "$1" ]] && return 0
  curl -s --max-time 10 -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" \
    -d chat_id="$CHAT_ID" \
    -d message_id="$1" \
    --data-urlencode text="$2" \
    -d parse_mode=HTML > /dev/null || echo "[warn] telegram edit_msg failed (id=$1)" >&2
}

format_time() {
  printf "%02dh %02dm %02ds" $(($1/3600)) $(($1%3600/60)) $(($1%60))
}

send_log() {
  sleep 2
  grep -iE "error:|fatal:|exception|traceback|ninja: build stopped|Killed|No space left" out/error.log \
    > out/errors_only.log 2>/dev/null
  local LOG="out/errors_only.log"
  [[ ! -s "$LOG" ]] && LOG="out/error.log"
  if [[ -s "$LOG" ]]; then
    curl -s --max-time 60 -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendDocument" \
      -F chat_id="$CHAT_ID" \
      -F document=@"$LOG" \
      -F caption="❌ Build Error Log" > /dev/null
  else
    send_msg "⚠️ No errors captured in log"
  fi
}

# FIX 1: clone_repo now reports which repo failed
clone_repo() {
  local url=$1 branch=$2 dest=$3
  if [[ -d "$dest/.git" ]]; then
    echo "skip $dest"
    return 0
  fi
  [[ -d "$dest" ]] && rm -rf "$dest"
  if [[ "$branch" == "." ]]; then
    git clone --depth=1 "$url" "$dest" || { CLONE_OK=0; CLONE_FAILED="$dest"; return 1; }
  else
    git clone --depth=1 -b "$branch" "$url" "$dest" || { CLONE_OK=0; CLONE_FAILED="$dest"; return 1; }
  fi
}

# pkill -P $$ kills direct children of this shell (the build process)
# more reliable than jobs -pr in non-interactive bash — process substitution children
# don't always appear in the jobs table
trap 'USER_CANCELLED=1; pkill -P $$ 2>/dev/null' INT TERM
USER_CANCELLED=0
START=$(date +%s)

# FIX 3: mkdir out early so repo init can log there
mkdir -p out

send_msg "🚀 <b>Build Started</b>

📱 $DEVICE_CODE
🖥 $BUILD_HOSTNAME
⏱ $(date)"

# Manifest cleanup
STEP=$(send_msg_id "⚙️ Cleaning local manifests...")
rm -rf .repo/local_manifests
edit_msg "$STEP" "✅ Cleaning local manifests"

# Pre-init setup
if [[ ${#PRE_INIT_CMDS[@]} -gt 0 ]]; then
  STEP=$(send_msg_id "⚙️ Pre-init setup...")
  PRE_INIT_OK=1
  for cmd in "${PRE_INIT_CMDS[@]}"; do
    eval "$cmd" || {
      PRE_INIT_OK=0
      edit_msg "$STEP" "⚠️ Pre-init Failed: $cmd"
      break
    }
  done
  [[ $PRE_INIT_OK -eq 1 ]] && edit_msg "$STEP" "✅ Pre-init setup"
fi

# Initialize repository
STEP=$(send_msg_id "⚙️ Repo Init...")
$REPO_INIT_CMD >> out/error.log 2>&1
edit_msg "$STEP" "✅ Repo Init"

# Sync
STEP=$(send_msg_id "⚙️ Syncing...")
SYNC_OK=0; DIRTY=0; SYNC_METHOD=""
SYNC_FLAGS="-c -v -j$(nproc --all) --force-sync --no-clone-bundle --no-tags"

if [[ $USE_CRAVE_RESYNC == true && -x /opt/crave/resync.sh ]]; then
  if stdbuf -oL -eL /opt/crave/resync.sh 2>&1 | tee -a out/error.log; then
    SYNC_METHOD="Crave Resync"
    SYNC_OK=1
  fi
fi

if [[ $USE_REPO_SYNC == true ]]; then
  # PYTHONUNBUFFERED=1 and stdbuf help show output immediately
  if PYTHONUNBUFFERED=1 stdbuf -oL -eL repo sync $SYNC_FLAGS 2>&1 | tee -a out/error.log; then
    [[ -n "$SYNC_METHOD" ]] && SYNC_METHOD="$SYNC_METHOD + Repo Sync" || SYNC_METHOD="Repo Sync"
    SYNC_OK=1
  fi
fi

# stricter than checking build/system/device alone — a half-broken tree can pass that
if [[ $SYNC_OK -eq 0 && -d build/make && -d frameworks/base && -d system/core ]]; then
  SYNC_OK=1; DIRTY=1
fi

if [[ $SYNC_OK -eq 1 ]]; then
  [[ $DIRTY -eq 1 ]] \
    && edit_msg "$STEP" "✅ Sync Complete (dirty)" \
    || edit_msg "$STEP" "✅ $SYNC_METHOD Done"
else
  edit_msg "$STEP" "⚠️ Sync Failed (Continuing...)"
fi

# Device sources
if [[ ${#REMOVE_PATHS[@]} -gt 0 ]]; then
  STEP=$(send_msg_id "⚙️ Cleaning paths...")
  for path in "${REMOVE_PATHS[@]}"; do rm -rf "$path"; done
  edit_msg "$STEP" "✅ Cleaning paths"
fi

# FIX 1 continued: report which repo failed in Telegram message
STEP=$(send_msg_id "⚙️ Cloning repos...")
CLONE_OK=1
CLONE_FAILED=""
for entry in "${CLONE_REPOS[@]}"; do
  IFS='|' read -r url branch dest <<< "$entry"
  clone_repo "$url" "$branch" "$dest"
done
if [[ $CLONE_OK -eq 1 ]]; then
  edit_msg "$STEP" "✅ Cloning repos"
else
  edit_msg "$STEP" "⚠️ Clone Failed: $CLONE_FAILED"
fi

# Environment
for exp in "${EXPORTS[@]}"; do export "$exp"; done
set +u
. build/envsetup.sh
set -u

# Post-envsetup
# FIX 6: EXTRA_CMDS — success message only if all pass
if [[ ${#EXTRA_CMDS[@]} -gt 0 ]]; then
  STEP=$(send_msg_id "⚙️ Extra setup...")
  EXTRA_OK=1
  for cmd in "${EXTRA_CMDS[@]}"; do
    eval "$cmd" || {
      EXTRA_OK=0
      edit_msg "$STEP" "⚠️ Extra setup Failed: $cmd"
      break
    }
  done
  [[ $EXTRA_OK -eq 1 ]] && edit_msg "$STEP" "✅ Extra setup"
fi

# KernelSU
  if [[ $KERNELSU_ENABLED == true ]]; then
    STEP=$(send_msg_id "⚙️ KernelSU setup...")
    if ! cd "$KERNELSU_PATH" 2>/dev/null; then
      edit_msg "$STEP" "⚠️ KernelSU Failed: path not found ($KERNELSU_PATH)"
    else
      KSU_OK=1
      if [[ ! -d "KernelSU" ]]; then
        curl -LSs -o /tmp/ksu_setup.sh \
          "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" \
          && bash /tmp/ksu_setup.sh "$KERNELSU_BRANCH" \
          || KSU_OK=0
        rm -f /tmp/ksu_setup.sh
      fi
      cd - >/dev/null
      if [[ $KSU_OK -eq 1 ]]; then
        edit_msg "$STEP" "✅ KernelSU setup"
      else
        edit_msg "$STEP" "⚠️ KernelSU setup Failed"
      fi
    fi
  fi

# Build tracker
send_msg "🛠 <b>Compilation Started</b>"
# touch only — do NOT truncate, earlier repo/sync logs must be preserved
touch out/error.log
echo "── Build started at $(date) ──" >> out/error.log

MSG_ID=$(send_msg_id "⚙️ Preparing build...")
edit_msg "$MSG_ID" "⚙️ Blueprint..."

BUILD_STARTED=0
MAX_P=0
LAST_PERCENT=-1
BUILD_MSG_ID=""
MILESTONES=(1 7 17 37 50 67 78 86 94 99)
MILESTONE_IDX=0
TOTAL_ACTIONS=0
EXIT_FILE=$(mktemp)

while read -r line; do
  printf '%s\n' "$line"

  # check cancel flag per-line so we don't block till build ends
  if [[ $USER_CANCELLED -eq 1 ]]; then
    break
  fi

  if [[ "$line" == *"Running globs"* ]]; then
    edit_msg "$MSG_ID" "✅ Blueprint
⚙️ Generating Ninja..."
  fi

  if [[ "$line" == *"initializing Make module parser"* ]]; then
    edit_msg "$MSG_ID" "✅ Blueprint
✅ Generating Ninja
⚙️ Parsing Modules..."
  fi

  if [[ "$line" =~ \[[[:space:]]*([0-9]+)%[[:space:]]+([0-9]+)/([0-9]+) ]]; then
  P=${BASH_REMATCH[1]}
  N=${BASH_REMATCH[3]}

  if [[ $BUILD_STARTED -eq 0 ]]; then
    (( P > MAX_P )) && MAX_P=$P
    if { (( MAX_P > 90 && P < 10 )) || (( N > 5000 && MAX_P < 10 )); }; then
      BUILD_STARTED=1
      edit_msg "$MSG_ID" "✅ Blueprint
  ✅ Generating Ninja
  ✅ Parsing Modules"
      sleep 1
      # Fix: Explicitly notify that Build has started after parsing
      BUILD_MSG_ID=$(send_msg_id "🛠 <b>Build Started</b>
  ⚙️ Build Progress: 0%")
      LAST_PERCENT=-1
      MILESTONE_IDX=0
    fi
  fi

  if [[ $BUILD_STARTED -eq 1 ]]; then
    (( N > TOTAL_ACTIONS )) && TOTAL_ACTIONS=$N
    if (( LAST_PERCENT > 50 && P < 10 )); then
      LAST_PERCENT=-1; MILESTONE_IDX=0
    fi
    if (( MILESTONE_IDX < ${#MILESTONES[@]} )); then
      TARGET=${MILESTONES[$MILESTONE_IDX]}
      if (( P >= TARGET )); then
        # Fix: Keep the progress update informative
        edit_msg "$BUILD_MSG_ID" "🛠 <b>Compilation Started</b>
  ⚙️ Progress: $TARGET%"
        MILESTONE_IDX=$(( MILESTONE_IDX + 1 ))
        LAST_PERCENT=$P
      fi
    fi
  fi
  fi

  done < <(set +u; 
  # Watchdog: Monitors if the build shell dies unexpectedly
  (
  MAIN_PID=$BASHPID
  sleep 30 # Give build time to start
  while kill -0 $MAIN_PID 2>/dev/null; do
    sleep 60
  done
  # If we are here, the main shell died. Check if it was a clean exit.
  if [[ ! -f "$EXIT_FILE" && $USER_CANCELLED -eq 0 ]]; then
     curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
       -d chat_id="$CHAT_ID" \
       -d text="⚠️ <b>Warning:</b> Build process disappeared unexpectedly (Server Disconnect/OOM)!" \
       -d parse_mode=HTML > /dev/null
  fi
  ) &
  WATCHDOG_PID=$!
  eval "$BUILD_CMD" 2>&1 | tee -a out/error.log; 
  echo "${PIPESTATUS[0]}" > "$EXIT_FILE"
  kill $WATCHDOG_PID 2>/dev/null
  )
STATUS_CODE=$(cat "$EXIT_FILE" 2>/dev/null || echo 1)
rm -f "$EXIT_FILE"

END=$(date +%s)
TIME=$(format_time $((END - START)))
TARGET_ID=${BUILD_MSG_ID:-$MSG_ID}

# Result handling
if [[ $USER_CANCELLED -eq 1 ]]; then
  edit_msg "$TARGET_ID" "⛔ <b>Build Cancelled</b>
⏱ $TIME"
  send_log

elif [[ $STATUS_CODE -ne 0 ]]; then
  edit_msg "$TARGET_ID" "❌ <b>Build Failed</b>
⏱ $TIME"
  send_log

else
  send_msg "✅ <b>Build Completed</b>
⏱ $TIME"

  ZIP=$(ls -t out/target/product/$DEVICE_CODE/*.zip 2>/dev/null | grep -vE "ota|target_files|symbols" |
     head -n1)
  if [[ -f "$ZIP" ]]; then
    NAME=$(basename "$ZIP")
    SIZE=$(du -h "$ZIP" | cut -f1)
    SIZE_BYTES=$(stat -c%s "$ZIP")
    
    # Metadata extraction
    # Search for all build.prop files and take the most relevant one (system/build.prop is usually best)
    PROP=$(find out/target/product/$DEVICE_CODE -name "build.prop" | grep "system/build.prop" | head -n1)
    [[ -z "$PROP" ]] && PROP=$(find out/target/product/$DEVICE_CODE -name "build.prop" | head -n1)
    
    AV="N/A"; SP="N/A"; BV="N/A"; BD="N/A"
    if [[ -n "$PROP" && -f "$PROP" ]]; then
      AV=$(grep "ro.build.version.release=" "$PROP" | cut -d= -f2 | head -n1)
      SP=$(grep "ro.build.version.security_patch=" "$PROP" | cut -d= -f2 | head -n1)
      BV=$(grep "ro.voltage.version=" "$PROP" | cut -d= -f2 | head -n1)
      BD=$(grep "ro.build.date=" "$PROP" | cut -d= -f2 | head -n1)
    fi

    UP_ID=$(send_msg_id "📤 <b>Uploading to Gofile...</b>")
    # Gofile — try up to 2 servers before giving up
    UPLOAD_OK=0
    SERVERS=$(curl -s --max-time 10 https://api.gofile.io/servers | jq -r '.data.servers[].name' 2>/dev/null | head -n2)
    for SERVER in $SERVERS; do
      # Increased timeout to 1200s (20 mins)
      LINK=$(curl -s --max-time 1200 -F "file=@$ZIP" "https://$SERVER.gofile.io/uploadFile" \
        | jq -er '.data.downloadPage')
      if [[ -n "$LINK" ]]; then
        UPLOAD_OK=1
        break
      fi
    done

    if [[ $UPLOAD_OK -eq 1 ]]; then
      edit_msg "$UP_ID" "🚀 <b>Build Released</b>

📱 <b>Device:</b> $DEVICE_CODE
📦 <b>File:</b> $NAME
📊 <b>Size:</b> $SIZE
🤖 <b>Android:</b> $AV
🛡️ <b>Patch:</b> $SP
⚡ <b>Version:</b> $BV
📅 <b>Date:</b> $BD
⏱ <b>Time:</b> $TIME

🔗 <a href=\"$LINK\">Download (Gofile)</a>"
    else
      edit_msg "$UP_ID" "⚠️ Gofile Upload Failed"
    fi
  else
    send_msg "❌ ZIP not found"
  fi
fi
EVICE_CODE
📦 <b>File:</b> $NAME
📊 <b>Size:</b> $SIZE
🤖 <b>Android:</b> $AV
🛡️ <b>Patch:</b> $SP
⚡ <b>Version:</b> $BV
📅 <b>Date:</b> $BD
⏱ <b>Time:</b> $TIME

🔗 <a href=\"$LINK\">Download (Gofile)</a>"
    else
      edit_msg "$UP_ID" "⚠️ Gofile Upload Failed"
    fi
  else
    send_msg "❌ ZIP not found"
  fi
fi
