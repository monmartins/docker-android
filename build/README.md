# Dockerfile — Debian + Android Emulator (API 34) + Frida + QBDI + Magisk (sources)

Este `Dockerfile` cria uma imagem baseada em **Debian trixie-slim** com:

- **Android SDK (cmdline-tools + platform-tools + build-tools)** e **Emulator**
- **AVD pronto** (Google APIs **x86_64**, Android **API 34**)
- **Frida** (cliente `frida-tools` no container + **frida-server** baixado para instalar/rodar no emulador)
- **QBDI** (baixado via script `scripts/fetch_qbdi.py`)
- **Magisk** (apenas **sources** clonados; com um patch no `build.py`)



---

## 1) Visão geral do Dockerfile 

### Base e shell
- A imagem começa de `debian:trixie-slim`. 
- Define `DEBIAN_FRONTEND=noninteractive` para evitar prompts do `apt`. 
- Troca o shell padrão para `bash` com `pipefail` (bom para falhar builds corretamente). 

### Variáveis de ambiente (SDK/Emulador/Frida/QBDI/Magisk)
O bloco de ENV centraliza versões, paths e defaults:

- SDK em `/opt/android` (`ANDROID_SDK_ROOT`/`ANDROID_HOME`) 
- AVD: `EMULATOR_NAME=nexus`, `EMULATOR_DEVICE="Nexus 6"` 
- Android: `ANDROID_API_LEVEL=34`, `ANDROID_BUILD_TOOLS=34.0.0` 
- Frida: `FRIDA_VERSION=17.2.16`, `FRIDA_ARCH=android-x86_64` e paths/porta 
- Magisk: repo e tag (`topjohnwu/Magisk`, `v30.6`) 
- QBDI: `QBDI_TAG=v0.12.0`, destino `/opt/qbdi` 
- Android cmdline-tools zip (versão fixa) 

E ajusta o `PATH` para incluir `sdkmanager`, `emulator` e `adb`. 

### Pacotes base (apt) + Java
Instala pacotes essenciais (rede, zip, build toolchain, libs do emulador, supervisord, etc.). 

Também tenta instalar Java 17, e faz fallback para 21 ou `default-jdk-headless` (para contornar disponibilidade do pacote no Debian trixie). 

> Há um bloco “debug bits” que imprime `/etc/os-release` e consulta `apt-cache` para o OpenJDK. 
> Em uma imagem “de produção” isso normalmente seria removido para reduzir ruído/tempo de build.

### Python tooling (Frida) com venv (PEP 668)
Cria um virtualenv em `/opt/venv` e instala `frida==17.2.16` e `frida-tools`. 
Depois injeta o venv no `PATH`. 

Isso evita conflitos com PEP 668 (“externally-managed environment”) em distros recentes.

### Android SDK + Emulator + AVD
Baixa e instala **Android command line tools** e então:

1. Aceita as licenças (`sdkmanager --licenses`) 
2. Instala `platform-tools`, `emulator`, `platforms;android-34`, `build-tools;34.0.0` e a system image Google APIs x86_64 
3. Cria um AVD chamado `${EMULATOR_NAME}` com device `${EMULATOR_DEVICE}` e o pacote de system image instalado 

### Frida server (android-x86_64)
Baixa do release do Frida e coloca em `/opt/frida/frida-server` com permissão de execução. 

> Observação: esse `frida-server` é o binário para **rodar dentro do Android (emulador)** — o container só o armazena no filesystem. Iniciar/empurrar para o emulador costuma ser papel do `entrypoint.sh`.

### QBDI (download via script do repositório)
O Dockerfile exige que você tenha no repo um script:
- `./scripts/fetch_qbdi.py`

Ele é copiado para `/opt/fetch_qbdi.py` e executado passando tag e diretório alvo. 

### Magisk (sources) + patch no build.py
Clona `topjohnwu/Magisk` na tag `v30.6`. 
Em seguida, aplica um `sed` no `build.py` para corrigir um `f-string` com aspas. 

### Scripts do repositório + supervisor
O Dockerfile copia scripts/configs do seu repo para dentro da imagem:

- `./scripts/entrypoint.sh` → `/entrypoint.sh`  
- `./scripts/run-emulator.sh` → `/usr/local/bin/run-emulator.sh`  
- `./scripts/supervisord.conf` → `/etc/supervisor/supervisord.conf` 

E marca `entrypoint.sh` e `run-emulator.sh` como executáveis. 

### Portas expostas
- `5554/5555`: portas típicas do **ADB/emulador**. 
- `37043`: exposta explicitamente junto com as portas do emulador. 

### Comando final
A imagem inicia com:
- `CMD ["/entrypoint.sh"]` 

Ou seja: quem decide o “fluxo” (subir emulator, socat, frida, supervisor etc.) é o seu `entrypoint.sh`.

---

## 2) Estrutura esperada do repositório

Para esse Dockerfile buildar, você precisa (no mínimo):

```text
.
├── Dockerfile
└── scripts/
    ├── entrypoint.sh
    ├── run-emulator.sh
    ├── supervisord.conf
    └── fetch_qbdi.py
```

> Se algum desses arquivos não existir, o `docker build` vai falhar nos `COPY`.

---

## 3) Comandos úteis de `docker build` (para colocar no README)

### Build básico
```bash
docker build -t rootrmc/docker-android:emulator_14 .
```
(É o comando sugerido no próprio Dockerfile.) 

### Build com logs detalhados (bom para debug do sdkmanager)
```bash
docker build --progress=plain -t rootrmc/docker-android:emulator_14 .
```

### Build limpando cache (garante baixar tudo de novo)
```bash
docker build --no-cache --progress=plain -t rootrmc/docker-android:emulator_14 .
```

### Build mirando plataforma (quando host é ARM64, mas você quer imagem amd64)
> Útil se você estiver em Apple Silicon/ARM e quer garantir compatibilidade com o emulador x86_64.
```bash
docker build --platform=linux/amd64 -t rootrmc/docker-android:emulator_14 .
```

### Build usando BuildKit e cache local (acelera builds repetidos)
```bash
DOCKER_BUILDKIT=1 docker build \
  --progress=plain \
  --cache-from type=local,src=.docker-cache \
  --cache-to type=local,dest=.docker-cache,mode=max \
  -t rootrmc/docker-android:emulator_14 .
```


---

## 4) Dicas rápidas para expor no repositório

Sugestão de checklist para o README:

- **Objetivo da imagem**: “Android Emulator API 34 + Frida + QBDI em Debian”
- **Requisitos no host**: Docker recente; (se for rodar emulator com aceleração) `/dev/kvm` disponível e permissões adequadas.
- **Como buildar**: (use os comandos acima)
- **Como rodar**: cite as portas expostas e que o fluxo é controlado pelo `entrypoint.sh` (e/ou supervisor).
- **Como customizar**: alterar as variáveis de `ENV` no Dockerfile para API/build-tools/AVD/Frida/QBDI.

---

## 5) Pontos de atenção (para evitar dor de cabeça)

- **Licenças do Android**: o build executa `sdkmanager --licenses` (pode demorar e falhar se a rede estiver instável). 
- **Arquitetura**: a system image é **x86_64**. 
- **Frida server**: o binário baixado é `android-x86_64` e precisa ser iniciado no Android (normalmente via `adb push` + `adb shell`). 
- **Scripts do repo**: `entrypoint.sh`/`run-emulator.sh`/`supervisord.conf` são parte da “lógica” do runtime. 

---
