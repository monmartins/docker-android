#!/usr/bin/env bash
set -euo pipefail

SERIAL="${SERIAL:-emulator-5558}"
REMOTE_PORT="${REMOTE_PORT:-27042}"
LOCAL_PORT="${LOCAL_PORT:-37042}"   # local forward port (must be free)

log(){ echo "[adb-frida] $*"; }

adb start-server >/dev/null 2>&1 || true

log "Waiting for device ${SERIAL}..."
adb -s "${SERIAL}" wait-for-device >/dev/null

log "Waiting for Android boot..."
until adb -s "${SERIAL}" shell getprop sys.boot_completed 2>/dev/null | grep -q "1"; do
  sleep 2
done
log "Boot OK."

# Clean previous forward if exists, then create it
adb -s "${SERIAL}" forward --remove "tcp:${LOCAL_PORT}" >/dev/null 2>&1 || true
adb -s "${SERIAL}" forward "tcp:${LOCAL_PORT}" "tcp:${REMOTE_PORT}"

log "Forward set: tcp:${LOCAL_PORT} -> tcp:${REMOTE_PORT}"

# Keep running so supervisord doesn't restart in a loop
# (also re-applies forward if adb server restarts)
while true; do
  sleep 10
  adb -s "${SERIAL}" forward --list | grep -q "tcp:${LOCAL_PORT}.*tcp:${REMOTE_PORT}" || {
    log "Forward missing, re-applying..."
    adb -s "${SERIAL}" forward --remove "tcp:${LOCAL_PORT}" >/dev/null 2>&1 || true
    adb -s "${SERIAL}" forward "tcp:${LOCAL_PORT}" "tcp:${REMOTE_PORT}" || true
  }
done
