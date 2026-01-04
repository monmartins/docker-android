#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="/opt/apps"

# Optional: choose a device (uncomment if you want to force a specific one)
# DEVICE_ID="emulator-5554"
# ADB=(adb -s "$DEVICE_ID")
ADB=(adb)

if [[ ! -d "$ROOT_DIR" ]]; then
  echo "[!] Directory not found: $ROOT_DIR" >&2
  exit 1
fi

if ! "${ADB[@]}" get-state >/dev/null 2>&1; then
  echo "[!] No device/emulator connected (adb get-state failed)." >&2
  echo "    Tip: run 'adb devices' and ensure one is 'device'." >&2
  exit 1
fi

echo "[*] Scanning: $ROOT_DIR"
echo

# Find all directories that contain at least one *.apk
# then for each directory, install the APK(s) in that directory.
while IFS= read -r -d '' dir; do
  # Collect APKs in this directory (not recursive; split sets usually live together)
  mapfile -d '' -t apks < <(find "$dir" -maxdepth 1 -type f -iname "*.apk" -print0 | sort -z)

  (( ${#apks[@]} > 0 )) || continue

  echo "[*] Directory: $dir"
  if (( ${#apks[@]} == 1 )); then
    echo "    -> Installing single APK: ${apks[0]}"
    "${ADB[@]}" install -r "${apks[0]}"
  else
    echo "    -> Installing multiple APKs (${#apks[@]}):"
    for a in "${apks[@]}"; do
      echo "       - $a"
    done
    # Correct command is `adb install-multiple`
    "${ADB[@]}" install-multiple -r "${apks[@]}"
  fi
  echo
done < <(
  find "$ROOT_DIR" -type f -iname "*.apk" -print0 \
  | xargs -0 -n1 dirname \
  | sort -zu
)

echo "[✓] Done."
