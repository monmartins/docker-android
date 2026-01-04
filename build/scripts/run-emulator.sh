#!/usr/bin/env bash
set -euo pipefail

log() { echo "[run-emulator] $*"; }

EMULATOR_NAME="${EMULATOR_NAME:-nexus}"
EMULATOR_PORT="${EMULATOR_PORT:-5558}"
FRIDA_PORT="${FRIDA_PORT:-27042}"

SERIAL="emulator-${EMULATOR_PORT}"

wait_for_boot() {
  adb -s "${SERIAL}" wait-for-device >/dev/null
  until adb -s "${SERIAL}" shell getprop sys.boot_completed 2>/dev/null | grep -q "1"; do
    sleep 2
  done
}
term_handler() {
  log "SIG recebido, encerrando..."

  # Ask emulator to shutdown cleanly
  adb -s "${SERIAL}" emu kill >/dev/null 2>&1 || true

  # give it a moment
  for _ in {1..15}; do
    kill -0 "${EMU_PID}" 2>/dev/null || break
    sleep 1
  done

  # if still alive, terminate qemu
  kill "${EMU_PID}" 2>/dev/null || true
  wait "${EMU_PID}" 2>/dev/null || true

  # cleanup: remove AVD locks
  find "/root/.android/avd/${EMULATOR_NAME}.avd" -name "*.lock" -delete 2>/dev/null || true
  exit 0
}

log "Iniciando adb server..."
adb start-server >/dev/null

log "Iniciando emulator (port=${EMULATOR_PORT})..."
emulator -avd "${EMULATOR_NAME}" \
  -port "${EMULATOR_PORT}" \
  -no-window -no-audio -no-boot-anim \
  -gpu swiftshader_indirect \
  -netdelay none -netspeed full \
  -no-snapshot \
  ${EMULATOR_EXTRA_ARGS:-} \
  >/var/log/emulator.log 2>&1 &

EMU_PID=$!

trap 'log "SIG recebido, encerrando..."; kill "${EMU_PID}" 2>/dev/null || true; wait "${EMU_PID}" 2>/dev/null || true; exit 0' TERM INT

log "Aguardando boot no ${SERIAL}..."
wait_for_boot
log "Boot OK."

wait "${EMU_PID}"


trap term_handler TERM INT


