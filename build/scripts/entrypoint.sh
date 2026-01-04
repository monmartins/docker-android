#!/usr/bin/env bash
set -euo pipefail

log() { echo "[entrypoint] $*"; }

EMULATOR_NAME="${EMULATOR_NAME:-nexus}"
EMULATOR_PORT="${EMULATOR_PORT:-5558}"

ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/android}"
MAGISK_DIR="${MAGISK_DIR:-/opt/magisk}"
FRIDA_SERVER_PATH="${FRIDA_SERVER_PATH:-/opt/frida/frida-server}"
FRIDA_PORT="${FRIDA_PORT:-27042}"
QBDI_DIR="${QBDI_DIR:-/opt/qbdi}"

AVD_DIR="${HOME}/.android/avd/${EMULATOR_NAME}.avd"
MARK_PATCH="${AVD_DIR}/.magisk_patched"
MARK_PROV="${AVD_DIR}/.provision_done"

wait_for_boot() {
  adb wait-for-device >/dev/null
  log "Aguardando sys.boot_completed=1 ..."
  until adb shell getprop sys.boot_completed 2>/dev/null | grep -q "1"; do
    sleep 2
  done
  log "Boot completo."
}

start_emu_bg() {
  log "Start emulator (port=${EMULATOR_PORT})..."
  adb start-server >/dev/null

  emulator -avd "${EMULATOR_NAME}" \
    -port "${EMULATOR_PORT}" \
    -no-window -no-audio -no-boot-anim \
    -gpu swiftshader_indirect \
    -netdelay none -netspeed full \
    -no-snapshot \
    ${EMULATOR_EXTRA_ARGS:-} \
    >/var/log/emulator.log 2>&1 &

  EMU_PID=$!
  log "Emulator PID=${EMU_PID}"
}
stop_emu_safe() {
  log "Sync no Android antes de parar..."
  adb shell sync >/dev/null 2>&1 || true

  log "Tentando shutdown limpo..."
  adb emu kill >/dev/null 2>&1 || true

  # espera o processo morrer sozinho
  for _ in $(seq 1 20); do
    adb get-state >/dev/null 2>&1 || return 0
    sleep 1
  done

  log "Fallback: kill do QEMU (evitar, mas se precisar)..."
  pkill -TERM -f 'qemu-system|emulator' >/dev/null 2>&1 || true
  sleep 2
  pkill -KILL -f 'qemu-system|emulator' >/dev/null 2>&1 || true
}

stop_emu() {
  log "Parando emulator (graceful + kill fallback)..."

  # 1) try kill via console (emulator serial ex: emulator-5558)
  if command -v adb >/dev/null 2>&1; then
    adb -s "emulator-${EMULATOR_PORT}" emu kill >/dev/null 2>&1 || true
  fi

  # 2) Fallback: acha o PID do QEMU headless e manda TERM -> KILL
  #    (padrão do processo: .../qemu-system-x86_64-headless -avd nexus -port 5558 ...)
  local pids=""
  pids="$(pgrep -f "/opt/android/emulator/qemu/.*/qemu-system-x86_64-headless.*(-avd[[:space:]]+${EMULATOR_NAME}\b|@${EMULATOR_NAME}\b|[[:space:]]-port[[:space:]]+${EMULATOR_PORT}\b)" || true)"

  if [[ -z "${pids}" ]]; then
    # tentativa mais permissiva (caso o path mude)
    pids="$(pgrep -f "qemu-system-x86_64-headless.*(-avd[[:space:]]+${EMULATOR_NAME}\b|[[:space:]]-port[[:space:]]+${EMULATOR_PORT}\b)" || true)"
  fi

  if [[ -n "${pids}" ]]; then
    log "Encontrado(s) PID(s) do QEMU: ${pids}"
    kill -TERM ${pids} 2>/dev/null || true

    # espera até ~10s
    for _ in {1..10}; do
      sleep 1
      if ! ps -p ${pids} >/dev/null 2>&1; then
        log "Emulator finalizado."
        return 0
      fi
    done

    log "Forçando kill -KILL no(s) PID(s): ${pids}"
    kill -KILL ${pids} 2>/dev/null || true
  else
    log "Nenhum processo qemu-system-x86_64-headless encontrado para ${EMULATOR_NAME}/${EMULATOR_PORT}."
  fi
}


ensure_magisk_apk() {
  MAGISK_APK="${MAGISK_APK_PATH:-/opt/magisk/Magisk.apk}"

  if [[ -f "${MAGISK_APK}" ]]; then
    log "Magisk APK OK (cache): ${MAGISK_APK}"
    return 0
  fi

  mkdir -p "$(dirname "${MAGISK_APK}")"
 
  if [[ -n "${MAGISK_URL:-}" ]]; then
    URL="${MAGISK_URL}"
 
  elif [[ -n "${MAGISK_TAG:-}" ]]; then
    URL="https://github.com/topjohnwu/Magisk/releases/download/${MAGISK_TAG}/Magisk-${MAGISK_TAG}.apk"
 
  else
    STABLE_JSON_URL="https://raw.githubusercontent.com/topjohnwu/magisk-files/master/stable.json"
    URL="$(curl -fsSL --retry 6 --retry-all-errors --connect-timeout 10 --max-time 60 \
      "${STABLE_JSON_URL}" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["magisk"]["link"])')"
  fi

  log "Baixando Magisk APK: ${URL}"
  curl -fL --retry 6 --retry-all-errors --connect-timeout 10 --max-time 300 \
    -o "${MAGISK_APK}" \
    "${URL}"

  log "Magisk APK OK: ${MAGISK_APK}"
}



detect_avd_image() {
  local cfg="${AVD_DIR}/config.ini"
  local sysrel="" sysdir=""

  if [[ -f "${cfg}" ]]; then
    sysrel="$(grep -E '^image\.sysdir\.1=' "${cfg}" | head -n1 | cut -d= -f2- || true)" 
    sysrel="${sysrel//\\//}"
  fi

  if [[ -n "${sysrel}" ]]; then
    if [[ "${sysrel}" = /* ]]; then
      sysdir="${sysrel}"
    else
      sysdir="${ANDROID_SDK_ROOT%/}/${sysrel}"
    fi
  fi 
  for base in "${AVD_DIR}" "${sysdir}"; do
    [[ -n "${base}" ]] || continue
    if [[ -f "${base}init_boot.img" ]]; then
      echo "${base}init_boot.img"
      return 0
    fi
    if [[ -f "${base}ramdisk.img" ]]; then
      echo "${base}ramdisk.img"
      return 0
    fi
  done

  echo "[entrypoint] Não achei init_boot.img/ramdisk.img em ${AVD_DIR} nem em sysdir=${sysdir} (image.sysdir.1=${sysrel})" >&2
  return 1
}


patch_avd_once() {
  if [[ -f "${MARK_PATCH}" ]]; then
    log "AVD já patchado (marker existe)."
    return 0
  fi

  local img
  img="$(detect_avd_image)"
  local out="${img}.magisk"

  log "Fazendo patch Magisk em: ${img}"
  start_emu_bg
  wait_for_boot
 
  pushd "${MAGISK_DIR}" >/dev/null
  python3 build.py avd_patch "${img}" "${out}" --apk "${MAGISK_APK}"
  popd >/dev/null

  stop_emu_safe

  log "Aplicando imagem patchada (backup + replace)..."
  cp -av "${img}" "${img}.bak"
  mv -f "${out}" "${img}"
  touch "${MARK_PATCH}"

  log "Patch aplicado. Próximo boot já terá Magisk/root."
} 
install_magisk() {
  local apk="${MAGISK_APK}"
  local pkg="${MAGISK_PKG:-com.topjohnwu.magisk}"  
  local max_tries="${MAGISK_MAX_TRIES:-20}"
  local delay="${MAGISK_RETRY_DELAY:-2}"

  log "Aguardando device ficar pronto (adb)..."
  adb wait-for-device >/dev/null 2>&1 || true
 
  adb shell 'while [ "$(getprop sys.boot_completed | tr -d "\r")" != "1" ]; do sleep 1; done' \
    >/dev/null 2>&1 || true

  log "Instalando Magisk APK no Android (até ${max_tries} tentativas)..."

  for i in $(seq 1 "${max_tries}"); do 
    if adb shell "pm list packages | grep -q '^package:${pkg}$'" >/dev/null 2>&1; then
      log "Magisk já está instalado (${pkg})."
      return 0
    fi
 
    out="$(adb install -r "${apk}" 2>&1 || true)"
 
    if adb shell "pm list packages | grep -q '^package:${pkg}$'" >/dev/null 2>&1; then
      log "Magisk instalado com sucesso (${pkg}) na tentativa ${i}."
      return 0
    fi
 
    if echo "$out" | grep -qiE 'INSTALL_FAILED_UPDATE_INCOMPATIBLE|INSTALL_FAILED_VERSION_DOWNGRADE|INSTALL_PARSE_FAILED|INSTALL_FAILED_ALREADY_EXISTS'; then
      log "Conflito detectado (tentativa ${i}). Tentando desinstalar e reinstalar..."
      adb uninstall "${pkg}" >/dev/null 2>&1 || true
      adb install "${apk}" >/dev/null 2>&1 || true

      if adb shell "pm list packages | grep -q '^package:${pkg}$'" >/dev/null 2>&1; then
        log "Magisk instalado após reinstalação limpa (${pkg})."
        return 0
      fi
    fi

    log "Magisk ainda não instalou (tentativa ${i}/${max_tries}). Retentando em ${delay}s..."
    sleep "${delay}"
  done

  log "ERRO: não foi possível instalar o Magisk após ${max_tries} tentativas."
  return 1
}
provision_frida_server_until_ok() {
  local host_bin="${FRIDA_SERVER_PATH}"
  local device_dir="/data/adb/frida"
  local device_bin="${device_dir}/frida-server"
  local max_tries="${FRIDA_MAX_TRIES:-20}"
  local delay="${FRIDA_RETRY_DELAY:-2}"

  if [[ ! -x "${host_bin}" ]]; then
    log "FRIDA_SERVER_PATH não é executável ou não existe: ${host_bin}"
    return 1
  fi

  log "Provisionando frida-server persistente (até ${max_tries} tentativas)..."

  adb wait-for-device >/dev/null 2>&1 || true
  adb shell 'while [ "$(getprop sys.boot_completed | tr -d "\r")" != "1" ]; do sleep 1; done' \
    >/dev/null 2>&1 || true

  for i in $(seq 1 "${max_tries}"); do 
    adb shell "mkdir -p '${device_dir}' /data/adb/service.d" >/dev/null 2>&1 || true
    adb push "${host_bin}" "${device_bin}" >/dev/null 2>&1 || true
    adb shell "chmod 0755 '${device_bin}'" >/dev/null 2>&1 || true
 
    out="$(adb shell "cd '${device_dir}' && ./frida-server --version" 2>&1 || true)"
    ver="$(echo "$out" | tr -d '\r' | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)"

    if [[ -n "${ver}" ]]; then
      log "frida-server OK: versão ${ver} (tentativa ${i})."
      return 0
    fi
 
    if echo "$out" | grep -qiE 'Exec format error|not executable|wrong ELF class|No such file or directory'; then
      abi="$(adb shell "getprop ro.product.cpu.abi" 2>/dev/null | tr -d '\r' || true)"
      log "Possível binário incompatível/ABI (${abi}). Saída: ${out}" 
    fi
 
    if echo "$out" | grep -qiE 'Permission denied|avc: denied|not permitted'; then
      log "Possível bloqueio/permissão/SELinux (tentativa ${i}). Tentando setenforce 0..."
      adb shell "su -c 'setenforce 0' >/dev/null 2>&1 || setenforce 0 >/dev/null 2>&1 || true" || true
      adb shell "chmod 0755 '${device_bin}'" >/dev/null 2>&1 || true
    fi
 
    adb shell "ls -l '${device_bin}' >/dev/null 2>&1 || true"

    log "frida-server ainda não respondeu versão (tentativa ${i}/${max_tries}). Retentando em ${delay}s..." 
 
    sleep "${delay}"
  done

  log "ERRO: frida-server não respondeu a './frida-server --version' após ${max_tries} tentativas."
  return 1
}

provision_frida_qbdi_once() {
  if [[ -f "${MARK_PROV}" ]]; then
    log "Provision já feito (marker existe)."
    return 0
  fi

  start_emu_bg
  wait_for_boot
 
  log "Tentando adb root..."
  adb root >/dev/null 2>&1 || true
  sleep 2
  adb wait-for-device >/dev/null || true
 
  log "Instalando Magisk APK no Android..."
  install_magisk
 
  if [[ -x "${FRIDA_SERVER_PATH}" ]]; then
    log "Provisionando frida-server persistente..."
    provision_frida_server_until_ok 

    cat > /tmp/99-frida.sh <<EOF
#!/system/bin/sh
setenforce 0 2>/dev/null || true
BIN=/data/adb/frida/frida-server
if [ -x "\$BIN" ]; then
  (nohup "\$BIN" -l 0.0.0.0:${FRIDA_PORT} >/dev/null 2>&1 &) || true
fi
exit 0
EOF
    adb push /tmp/99-frida.sh /data/adb/service.d/99-frida.sh >/dev/null
    adb shell "chmod 0755 /data/adb/service.d/99-frida.sh" >/dev/null 2>&1 || true
    rm -f /tmp/99-frida.sh
  else
    log "frida-server não encontrado/executável em ${FRIDA_SERVER_PATH} (pulando)."
  fi
 
  log "Procurando libQBDI.so em ${QBDI_DIR}..."
  QBDI_SO="$(find "${QBDI_DIR}" -type f -name 'libQBDI.so' -print -quit || true)"
  if [[ -n "${QBDI_SO}" ]]; then
    log "Provisionando QBDI (${QBDI_SO})..."
    adb shell "mkdir -p /data/adb/qbdi" >/dev/null 2>&1 || true
    adb push "${QBDI_SO}" /data/adb/qbdi/libQBDI.so >/dev/null
    adb shell "chmod 0644 /data/adb/qbdi/libQBDI.so" >/dev/null 2>&1 || true

    cat > /tmp/98-qbdi.sh <<'EOF'
#!/system/bin/sh
# conveniência: link em /data/local/tmp
if [ -f /data/adb/qbdi/libQBDI.so ]; then
  ln -sf /data/adb/qbdi/libQBDI.so /data/local/tmp/libQBDI.so 2>/dev/null || true
fi
exit 0
EOF
    adb push /tmp/98-qbdi.sh /data/adb/service.d/98-qbdi.sh >/dev/null
    adb shell "chmod 0755 /data/adb/service.d/98-qbdi.sh" >/dev/null 2>&1 || true
    rm -f /tmp/98-qbdi.sh
  else
    log "libQBDI.so não encontrada em ${QBDI_DIR} (verifique o QBDI_TAG/pacote)."
  fi

  touch "${MARK_PROV}"
  stop_emu_safe
  log "Provision concluído."
}

main() {
  if [[ ! -e /dev/kvm ]]; then
    log "AVISO: /dev/kvm não existe. Passe --device /dev/kvm no docker run (senão fica lento/quebra)."
  fi

  if [[ ! -d "${AVD_DIR}" ]]; then
    log "AVD_DIR não existe: ${AVD_DIR} (você removeu o create avd do build?)"
    exit 1
  fi

  ensure_magisk_apk
  patch_avd_once
  provision_frida_qbdi_once
  export EMULATOR_PORT="5558" 
  log "Subindo supervisord..."
  exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf 
}

main "$@"
