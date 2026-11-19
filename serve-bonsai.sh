#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# serve-bonsai.sh — descarga Bonsai 2 27B o GLM-4.7-Flash (GGUF) y los sirve
# con llama.cpp (llama-server) como API compatible con OpenAI.
#
#   bash serve-bonsai.sh                 # detecta hardware, descarga y sirve
#   bash serve-bonsai.sh --help
#   bash serve-bonsai.sh --dry-run       # enseña lo que haría, sin descargar
#
# Requiere Linux x86_64/aarch64. Instala las dependencias del sistema que falten
# (curl/wget, tar, python3) y descarga binarios precompilados de PrismML
# (CUDA, ROCm, Vulkan o CPU). No requiere toolkit CUDA ni compilar nada.
# El driver de la GPU NVIDIA debe estar instalado (el script lo detecta y guía).
# ---------------------------------------------------------------------------
set -Eeuo pipefail

VERSION="2.1.0"

# --- Configuración por defecto (todo se puede sobrescribir por entorno) -----
LLAMA_REPO="${LLAMA_REPO:-PrismML-Eng/llama.cpp}"
LLAMA_RELEASE="${LLAMA_RELEASE:-prism-b10828-a153697}"
MODEL="${MODEL:-bonsai}"          # bonsai | glm47
MODEL_REPO="${MODEL_REPO:-}"
SERVED_NAME="${SERVED_NAME:-}"
PACKING="${PACKING:-pq2}"         # solo Bonsai: pq2 | ptq1 | q2
PACKING_EXPLICIT=0

BASE_DIR="${BASE_DIR:-$HOME/.local/share/bonsai}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8000}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-auto}"
PARALLEL="${PARALLEL:-1}"
GPU_LAYERS="${GPU_LAYERS:-auto}"
BACKEND="${BACKEND:-auto}"        # auto | cuda | rocm | vulkan | cpu
CUDA_BUILD="${CUDA_BUILD:-auto}"  # auto | 12.4 | 12.8 | 13.3
API_KEY="${API_KEY:-}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
HF_TOKEN="${HF_TOKEN:-}"
MIN_FREE_GB="${MIN_FREE_GB:-0}"   # 0 = calcular según el pack
VISION="${VISION:-0}"
KV4="${KV4:-0}"

ASSUME_YES=0
SKIP_DOWNLOAD=0
REINSTALL=0
DRY_RUN=0
ALLOW_CPU=0

# --- Salida ----------------------------------------------------------------
if [[ -t 1 ]]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else
  B=""; G=""; Y=""; R=""; N=""
fi
step() { printf '\n%s==>%s %s%s\n' "$B" "$N" "$B" "$*$N"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '    %s!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '\n%s✗ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- Dependencias del sistema ---------------------------------------------
# Instala lo que falte (curl/wget, tar, python3, pciutils) con el gestor de
# paquetes de la distro. El driver de la GPU NO se instala aquí: necesita
# reinicio y se gestiona aparte (ver más abajo).
PKG_MGR=""
detect_pkg_mgr() {
  if   have apt-get; then PKG_MGR=apt
  elif have dnf;     then PKG_MGR=dnf
  elif have yum;     then PKG_MGR=yum
  elif have pacman;  then PKG_MGR=pacman
  elif have zypper;  then PKG_MGR=zypper
  elif have apk;     then PKG_MGR=apk
  else PKG_MGR=""
  fi
}

pkg_name() {
  case "$PKG_MGR:$1" in
    pacman:python3) echo python ;;
    *) echo "$1" ;;
  esac
}

install_pkgs() {
  local pkgs=() p SUDO=""
  for p in "$@"; do pkgs+=("$(pkg_name "$p")"); done
  if (( EUID != 0 )); then
    if have sudo; then SUDO="sudo"
    else die "faltan dependencias (${pkgs[*]}) y no hay sudo. Instálalas como root y reintenta."
    fi
  fi
  info "instalando dependencias del sistema: ${pkgs[*]}"
  case "$PKG_MGR" in
    apt)     $SUDO apt-get update -qq && $SUDO apt-get install -y "${pkgs[@]}" ;;
    dnf|yum) $SUDO "$PKG_MGR" install -y "${pkgs[@]}" ;;
    pacman)  $SUDO pacman -S --needed --noconfirm "${pkgs[@]}" ;;
    zypper)  $SUDO zypper --non-interactive install "${pkgs[@]}" ;;
    apk)     $SUDO apk add "${pkgs[@]}" ;;
    *) die "no conozco el gestor de paquetes de esta distro. Instala a mano: ${pkgs[*]}" ;;
  esac
}

ensure_deps() {
  detect_pkg_mgr
  local need=()
  if ! have curl && ! have wget; then need+=(curl); fi
  have tar || need+=(tar)
  if (( ${#need[@]} > 0 )); then
    [[ -n "$PKG_MGR" ]] || die "faltan ${need[*]} y no hay gestor de paquetes conocido. Instálalos a mano."
    install_pkgs "${need[@]}"
  fi
  have curl || have wget || die "sigo sin curl/wget tras intentar instalarlas"
  have tar || die "sigo sin tar tras intentar instalarlo"
  # python3 es opcional (verificación del GGUF); se instala si se puede.
  if ! have python3 && [[ -n "$PKG_MGR" ]] && { (( EUID == 0 )) || have sudo; }; then
    install_pkgs python3 || warn "no pude instalar python3; se omitirá la verificación del GGUF"
  fi
  # lspci ayuda a detectar una GPU aunque falte el driver; opcional.
  if ! have lspci && [[ -n "$PKG_MGR" ]] && { (( EUID == 0 )) || have sudo; }; then
    install_pkgs pciutils || true
  fi
}

usage() {
  cat <<EOF
serve-bonsai.sh v${VERSION} — sirve Bonsai 2 o GLM-4.7-Flash con llama.cpp

USO
  bash serve-bonsai.sh [opciones] [-- <flags extra para llama-server>]

OPCIONES
  -y, --yes              No preguntar nada
  -p, --port N           Puerto HTTP (por defecto 8000)
  -l, --max-model-len N  Contexto máximo en tokens (por defecto: auto según VRAM/RAM)
      --model M          bonsai (defecto) | glm47 (GLM-4.7-Flash 30B-A3B; ≥22 GB VRAM)
  -q, --packing P        Solo Bonsai: pq2 (defecto, 7.21 GB) | ptq1 (5.95 GB) | q2 (7.63 GB)
  -d, --dir RUTA         Directorio base (defecto ~/.local/share/bonsai)
      --host HOST        Dirección de escucha (defecto 127.0.0.1; usa 0.0.0.0 para exponer)
      --backend B        auto (defecto) | cuda | rocm | vulkan | cpu
      --cpu              Atajo de --backend cpu --gpu-layers 0
      --allow-cpu        Permite ir por CPU aunque haya una GPU NVIDIA sin driver
      --cuda-build V     12.4 | 12.8 | 13.3 (por defecto: según el driver)
      --gpu-layers N     Capas en GPU (defecto: 99 en GPU, 0 en CPU)
      --parallel N       Slots concurrentes (defecto 1; el contexto se reparte)
      --vision           Descarga el mmproj Q8_0 y habilita imágenes
      --kv4              KV cache en q4_0 (menos VRAM, contexto largo)
      --api-key CLAVE    Exige Authorization: Bearer
      --no-download      No descargar modelos (ya están en disco)
      --reinstall        Vuelve a descargar los binarios de llama.cpp
      --dry-run          Detecta hardware y enseña la orden final, sin descargar
  -h, --help             Esta ayuda

ENTORNO
  LLAMA_RELEASE   Tag del release (defecto prism-b10828-a153697)
  LLAMA_REPO      Repo de binarios (defecto PrismML-Eng/llama.cpp)
  MODEL_REPO      Repo del GGUF (defecto prism-ml/Ternary-Bonsai-2-27B-gguf)
  BASE_DIR, PORT, HOST, MAX_MODEL_LEN, GPU_LAYERS, PARALLEL, PACKING,
  BACKEND, CUDA_BUILD, API_KEY, HF_TOKEN, EXTRA_ARGS, MIN_FREE_GB,
  VISION=1, KV4=1, ALLOW_CPU=1, MODEL=bonsai|glm47

EJEMPLOS
  bash serve-bonsai.sh -y
  bash serve-bonsai.sh -y --model glm47
  bash serve-bonsai.sh -p 9000 -l 32768
  bash serve-bonsai.sh --vision --kv4
  API_KEY=sk-local bash serve-bonsai.sh -y
  bash serve-bonsai.sh -- --reasoning-budget 8192
EOF
}

# --- Argumentos ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    -p|--port) PORT="${2:?falta el puerto}"; shift 2 ;;
    -l|--max-model-len) MAX_MODEL_LEN="${2:?falta el valor}"; shift 2 ;;
    --model) MODEL="${2:?falta el modelo}"; shift 2 ;;
    -q|--packing) PACKING="${2:?falta el packing}"; PACKING_EXPLICIT=1; shift 2 ;;
    -d|--dir) BASE_DIR="${2:?falta la ruta}"; shift 2 ;;
    --host) HOST="${2:?falta el host}"; shift 2 ;;
    --backend) BACKEND="${2:?falta el backend}"; if [[ "$BACKEND" == "cpu" ]]; then ALLOW_CPU=1; fi; shift 2 ;;
    --cuda-build) CUDA_BUILD="${2:?falta la versión}"; shift 2 ;;
    --cpu) BACKEND=cpu; GPU_LAYERS=0; ALLOW_CPU=1; shift ;;
    --allow-cpu) ALLOW_CPU=1; shift ;;
    --gpu-layers) GPU_LAYERS="${2:?falta el valor}"; shift 2 ;;
    --parallel) PARALLEL="${2:?falta el valor}"; shift 2 ;;
    --api-key) API_KEY="${2:?falta la clave}"; shift 2 ;;
    --vision) VISION=1; shift ;;
    --kv4) KV4=1; shift ;;
    --reinstall) REINSTALL=1; shift ;;
    --no-download) SKIP_DOWNLOAD=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; EXTRA_ARGS="${EXTRA_ARGS:+$EXTRA_ARGS }$*"; break ;;
    -h|--help) usage; exit 0 ;;
    *) die "opción desconocida: $1 (usa --help)" ;;
  esac
done

# --- Packing de Bonsai -----------------------------------------------------
case "$PACKING" in
  pq2|PQ2_0)
    PACKING=pq2
    BONSAI_FILE="Ternary-Bonsai-2-27B-PQ2_0.gguf"
    BONSAI_SIZE=7206168928
    BONSAI_TYPE=142           # GGML_TYPE_PQ2_0 (fork de PrismML)
    ;;
  ptq1|PTQ1_0)
    PACKING=ptq1
    BONSAI_FILE="Ternary-Bonsai-2-27B-PTQ1_0.gguf"
    BONSAI_SIZE=5946648928
    BONSAI_TYPE=143           # GGML_TYPE_PTQ1_0 (fork de PrismML)
    ;;
  q2|Q2_0)
    PACKING=q2
    BONSAI_FILE="Ternary-Bonsai-2-27B-Q2_0.gguf"
    BONSAI_SIZE=7626008928
    BONSAI_TYPE=42            # GGML_TYPE_Q2_0 (grupo 64; también en stock)
    ;;
  *) die "packing desconocido: $PACKING (usa pq2, ptq1 o q2)" ;;
esac

# --- Perfil del modelo -----------------------------------------------------
case "$MODEL" in
  bonsai|bonsai2|bonsai-2) MODEL=bonsai ;;
  glm|glm47|glm-4.7|glm4.7) MODEL=glm ;;
  *) die "modelo desconocido: $MODEL (usa bonsai o glm47)" ;;
esac

if [[ "$MODEL" == "glm" && "$PACKING_EXPLICIT" == "1" ]]; then
  die "--packing solo aplica a --model bonsai; GLM usa su propio GGUF"
fi

if [[ "$MODEL" == "bonsai" ]]; then
  MODEL_LABEL="Ternary Bonsai 2 27B"
  MODEL_QUANT_LABEL="$PACKING"
  MODEL_REPO="${MODEL_REPO:-prism-ml/Ternary-Bonsai-2-27B-gguf}"
  MODEL_FILE="$BONSAI_FILE"
  EXPECTED_SIZE="$BONSAI_SIZE"
  MODEL_TYPE="$BONSAI_TYPE"
  SERVED_NAME="${SERVED_NAME:-bonsai-2-27b}"
  MMPROJ_SUPPORTED=1
  MODEL_VALIDATOR="bonsai"
  SAMPLING=(--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.05)
else
  MODEL_LABEL="GLM-4.7-Flash 30B-A3B"
  MODEL_QUANT_LABEL="UD-Q4_K_XL"
  MODEL_REPO="${MODEL_REPO:-unsloth/GLM-4.7-Flash-GGUF}"
  MODEL_FILE="GLM-4.7-Flash-UD-Q4_K_XL.gguf"
  EXPECTED_SIZE=17520169312
  MODEL_TYPE=""
  SERVED_NAME="${SERVED_NAME:-glm-4.7-flash}"
  MMPROJ_SUPPORTED=0
  MODEL_VALIDATOR="generic"
  SAMPLING=(--temp 1.0 --top-p 0.95 --min-p 0.01)
fi

MMPROJ_FILE="Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf"
MMPROJ_SIZE=629246976

if (( VISION == 1 )) && (( MMPROJ_SUPPORTED == 0 )); then
  die "--vision no está disponible para $MODEL_LABEL (solo Bonsai trae mmproj)"
fi

[[ "$VISION" == 1 || "$VISION" == 0 ]] || die "VISION debe ser 0 o 1"
[[ "$KV4" == 1 || "$KV4" == 0 ]] || die "KV4 debe ser 0 o 1"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "puerto inválido: $PORT"
[[ "$PARALLEL" =~ ^[0-9]+$ ]] || die "parallel inválido: $PARALLEL"

# ---------------------------------------------------------------------------
step "1/6 · Detectando el sistema y el hardware"

[[ "$(uname -s)" == "Linux" ]] || die "este script es para Linux (x86_64 o aarch64)."
case "$(uname -m)" in
  x86_64|amd64) ARCH_TAG=x64 ;;
  aarch64|arm64) ARCH_TAG=arm64 ;;
  *) die "arquitectura no soportada: $(uname -m) (usa x86_64 o aarch64)" ;;
esac
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  info "distribución: ${PRETTY_NAME:-desconocida} · arquitectura: $(uname -m)"
fi
ensure_deps

# Backend: nunca se asume NVIDIA. Orden: override > NVIDIA > ROCm > Vulkan > CPU.
case "$BACKEND" in
  auto|cuda|rocm|vulkan|cpu) ;;
  *) die "backend desconocido: $BACKEND (auto, cuda, rocm, vulkan o cpu)" ;;
esac

if [[ "$BACKEND" == "auto" ]]; then
  if have nvidia-smi; then
    if nvidia-smi -L >/dev/null 2>&1; then
      BACKEND=cuda
    else
      warn "nvidia-smi está instalado pero el driver no responde; sigo buscando otra GPU"
    fi
  fi
fi
if [[ "$BACKEND" == "auto" ]]; then
  if have rocminfo || have rocm-smi || have hipcc; then
    BACKEND=rocm
  elif have vulkaninfo; then
    BACKEND=vulkan
  else
    BACKEND=cpu
  fi
fi

if [[ "$BACKEND" == "cuda" ]] && ! { have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; }; then
  die "backend cuda pedido, pero 'nvidia-smi' no funciona. Instala/actualiza el driver o usa --backend vulkan|cpu."
fi
if [[ "$BACKEND" == "rocm" ]] && ! { have rocminfo || have rocm-smi || have hipcc; }; then
  die "backend rocm pedido, pero no encuentro ROCm (rocminfo/rocm-smi/hipcc)."
fi
if [[ "$BACKEND" == "vulkan" ]] && ! have vulkaninfo; then
  die "backend vulkan pedido, pero no encuentro vulkaninfo (paquete vulkan-tools)."
fi

# Los binarios CUDA/ROCm solo existen para x64.
if [[ "$ARCH_TAG" == "arm64" && ( "$BACKEND" == "cuda" || "$BACKEND" == "rocm" ) ]]; then
  warn "no hay binarios precompilados de $BACKEND para arm64"
  if have vulkaninfo; then BACKEND=vulkan; else BACKEND=cpu; fi
fi

# --- GPU NVIDIA sin driver: no caer a CPU en silencio ---------------------
NVIDIA_HW=0
if have lspci && lspci -nn 2>/dev/null | grep -qiE '\[10de:[0-9a-f]{4}\]'; then
  NVIDIA_HW=1
fi
if (( NVIDIA_HW == 1 )) && [[ "$BACKEND" == "cpu" ]] && [[ "$ALLOW_CPU" == "0" ]]; then
  warn "hay una GPU NVIDIA pero el driver no está operativo (se iba a usar CPU)"
  DRIVER_CMD=""
  case "$PKG_MGR" in
    apt) if [[ "${ID:-}" == "ubuntu" ]]; then DRIVER_CMD="ubuntu-drivers install"; fi ;;
    pacman) DRIVER_CMD="pacman -S --needed nvidia-open" ;;
  esac
  if [[ -n "$DRIVER_CMD" ]] && (( ASSUME_YES == 0 )) && (( DRY_RUN == 0 )); then
    printf '    ¿Instalar el driver NVIDIA ahora? (%s) [s/N] ' "$DRIVER_CMD"
    read -r ans
    if [[ "$ans" =~ ^[sSyY]$ ]]; then
      SUDO=""
      if (( EUID != 0 )); then SUDO="sudo"; fi
      if [[ "$PKG_MGR" == "apt" ]]; then
        have ubuntu-drivers || $SUDO apt-get install -y ubuntu-drivers-common \
          || die "no pude instalar ubuntu-drivers-common"
        $SUDO ubuntu-drivers install || die "falló la instalación del driver NVIDIA"
      else
        $SUDO pacman -S --needed --noconfirm nvidia-open || die "falló la instalación del driver NVIDIA"
      fi
      info "Driver instalado. REINICIA la máquina y vuelve a ejecutar este script."
      exit 0
    fi
  fi
  die "instala el driver NVIDIA y reinicia, o usa --allow-cpu para ir por CPU.
      Ubuntu:        sudo ubuntu-drivers install
      Debian:        sudo apt install nvidia-driver   (repos non-free) y reinicia
      Arch:          sudo pacman -S nvidia-open       y reinicia
      Otras distros: consulta la guía de instalación de NVIDIA de tu distro"
fi
if have lspci && lspci -nn 2>/dev/null | grep -qiE '\[1002:[0-9a-f]{4}\]' && [[ "$BACKEND" == "cpu" ]]; then
  warn "hay una GPU AMD pero sin ROCm/Vulkan; se usará CPU. Instala los drivers y usa --backend rocm|vulkan."
fi

# Versión de CUDA del driver (solo para elegir el binario; no hace falta toolkit).
CUDA_TAG=""
if [[ "$BACKEND" == "cuda" ]]; then
  if [[ "$CUDA_BUILD" != "auto" ]]; then
    case "$CUDA_BUILD" in
      12.4|12.8|13.3) CUDA_TAG="$CUDA_BUILD" ;;
      *) die "CUDA_BUILD inválido: $CUDA_BUILD (12.4, 12.8 o 13.3)" ;;
    esac
  else
    CUDA_VER=""
    if have nvidia-smi; then
      CUDA_VER="$(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA[ A-Za-z]*Version:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' | head -n1 || true)"
    fi
    if [[ -z "$CUDA_VER" ]] && have nvcc; then
      CUDA_VER="$(nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9][0-9.]*\).*/\1/p' | head -n1 || true)"
    fi
    if [[ -z "$CUDA_VER" ]]; then
      warn "no pude leer la versión de CUDA del driver; uso el binario CUDA 12.4"
      CUDA_TAG=12.4
    elif [[ "$CUDA_VER" =~ ^([0-9]+)\.([0-9]+) ]]; then
      CUDA_MAJ="${BASH_REMATCH[1]}"
      CUDA_MIN="${BASH_REMATCH[2]}"
      if (( CUDA_MAJ > 13 || (CUDA_MAJ == 13 && CUDA_MIN >= 3) )); then
        CUDA_TAG=13.3
      elif (( CUDA_MAJ == 13 || (CUDA_MAJ == 12 && CUDA_MIN >= 8) )); then
        CUDA_TAG=12.8
      elif (( CUDA_MAJ == 12 && CUDA_MIN >= 4 )); then
        CUDA_TAG=12.4
      else
        warn "el driver reporta CUDA $CUDA_VER (< 12.4); el binario precompilado puede no arrancar"
        info "  actualiza el driver, o usa --backend vulkan / --backend cpu"
        CUDA_TAG=12.4
      fi
      info "driver con CUDA $CUDA_VER → binario CUDA $CUDA_TAG"
    else
      warn "versión de CUDA no reconocida ('$CUDA_VER'); uso 12.4"
      CUDA_TAG=12.4
    fi
  fi
fi

# Blackwell (compute >= 10.0, p. ej. RTX 5070/5080) necesita CUDA 12.8+.
if [[ "$BACKEND" == "cuda" ]]; then
  COMPUTE_CAP="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n1 || true)"
  if [[ "$COMPUTE_CAP" =~ ^([0-9]+)\.([0-9]+) ]]; then
    CAP_MAJ="${BASH_REMATCH[1]}"
    if (( CAP_MAJ >= 10 )) && [[ "$CUDA_TAG" == "12.4" ]]; then
      if [[ "$CUDA_BUILD" != "auto" ]]; then
        warn "GPU compute $COMPUTE_CAP (Blackwell) con CUDA 12.4 forzado: puede no arrancar"
      else
        DRV_OK=1
        if [[ "$CUDA_VER" =~ ^([0-9]+)\.([0-9]+) ]]; then
          if (( BASH_REMATCH[1] < 12 || (BASH_REMATCH[1] == 12 && BASH_REMATCH[2] < 8) )); then DRV_OK=0; fi
        fi
        if (( DRV_OK == 0 )); then
          die "la GPU es compute $COMPUTE_CAP (Blackwell) y necesita CUDA 12.8+, pero el driver reporta CUDA ${CUDA_VER:-desconocida}. Actualiza el driver NVIDIA."
        fi
        CUDA_TAG=12.8
        warn "GPU compute $COMPUTE_CAP (Blackwell): uso el binario CUDA 12.8"
      fi
    fi
  fi
fi

# VRAM (best-effort; 0 = desconocida → contexto conservador).
VRAM_MB=0
GPU_NAME=""
case "$BACKEND" in
  cuda)
    if have nvidia-smi; then
      GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || true)"
      _v="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' | sort -n | head -n1 || true)"
      if [[ "$_v" =~ ^[0-9]+$ ]]; then VRAM_MB="$_v"; fi
    fi
    ;;
  rocm)
    GPU_NAME="$(rocminfo 2>/dev/null | sed -n 's/.*Marketing Name:[[:space:]]*//p' | head -n1 || true)"
    if have rocm-smi; then
      _vb="$(rocm-smi --showmeminfo vram 2>/dev/null | sed -n 's/.*Total Memory (B):[[:space:]]*\([0-9][0-9]*\).*/\1/p' | sort -n | head -n1 || true)"
      if [[ "$_vb" =~ ^[0-9]+$ ]]; then VRAM_MB=$(( _vb / 1024 / 1024 )); fi
    fi
    if (( VRAM_MB == 0 )) && have rocminfo; then
      _vb="$(rocminfo 2>/dev/null | awk '/Size:/{print $2; exit}' || true)"
      if [[ "$_vb" =~ ^[0-9]+$ ]]; then VRAM_MB=$(( _vb / 1024 / 1024 )); fi
    fi
    ;;
  vulkan)
    GPU_NAME="$(vulkaninfo --summary 2>/dev/null | sed -n 's/.*deviceName[[:space:]]*=[[:space:]]*//p' | head -n1 || true)"
    ;;
  cpu)
    GPU_NAME="$(awk -F: '/model name/{gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
    ;;
esac

RAM_MB=0
if [[ -r /proc/meminfo ]]; then
  RAM_MB="$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)"
fi

case "$BACKEND" in
  cuda)   BACKEND_LABEL="NVIDIA CUDA" ;;
  rocm)   BACKEND_LABEL="AMD ROCm" ;;
  vulkan) BACKEND_LABEL="Vulkan" ;;
  cpu)    BACKEND_LABEL="CPU" ;;
esac
if (( VRAM_MB > 0 )); then
  ok "GPU: ${GPU_NAME:-desconocida} — ${VRAM_MB} MiB VRAM · $BACKEND_LABEL"
else
  ok "acelerador: $BACKEND_LABEL${GPU_NAME:+ ($GPU_NAME)}"
fi
if (( RAM_MB > 0 )); then info "RAM: $(( RAM_MB / 1024 )) GiB"; fi

if [[ "$BACKEND" == "cpu" ]]; then
  warn "sin GPU utilizable: se usará la CPU (mucho más lento)"
fi

# GLM-4.7-Flash pesa 17,5 GB: no cabe en 12 GB y necesita margen para el KV.
if [[ "$MODEL" == "glm" ]]; then
  if [[ "$BACKEND" == "cpu" ]]; then
    if (( RAM_MB > 0 && RAM_MB < 32768 )); then
      die "GLM-4.7-Flash necesita ~18 GB de pesos: usa ≥32 GB de RAM, o --model bonsai"
    fi
  elif (( VRAM_MB > 0 && VRAM_MB < 22000 )); then
    die "GLM-4.7-Flash UD-Q4_K_XL pesa 17,5 GB y tu GPU tiene ${VRAM_MB} MiB. Usa --model bonsai o una GPU de ≥22 GB (3090/4090)."
  fi
fi

# Contexto automático. En GPU manda la VRAM; en CPU, la RAM.
if [[ "$MAX_MODEL_LEN" == "auto" ]]; then
  if [[ "$MODEL" == "glm" ]]; then
    if [[ "$BACKEND" == "cpu" ]]; then
      if (( RAM_MB >= 65536 )); then MAX_MODEL_LEN=16384; else MAX_MODEL_LEN=8192; fi
    elif (( VRAM_MB >= 48000 )); then MAX_MODEL_LEN=131072
    elif (( VRAM_MB >= 32000 )); then MAX_MODEL_LEN=65536
    else                              MAX_MODEL_LEN=32768
    fi
  elif [[ "$BACKEND" == "cpu" ]]; then
    if   (( RAM_MB >= 49152 )); then MAX_MODEL_LEN=32768
    elif (( RAM_MB >= 24576 )); then MAX_MODEL_LEN=16384
    else                             MAX_MODEL_LEN=8192
    fi
  elif (( VRAM_MB >= 40960 )); then MAX_MODEL_LEN=131072
  elif (( VRAM_MB >= 18000 )); then MAX_MODEL_LEN=65536
  elif (( VRAM_MB >= 14000 )); then MAX_MODEL_LEN=32768
  elif (( VRAM_MB >= 10000 )); then
    if [[ "$PACKING" == "ptq1" ]]; then MAX_MODEL_LEN=32768; else MAX_MODEL_LEN=16384; fi
  elif (( VRAM_MB > 0 ));      then MAX_MODEL_LEN=8192
  else                              MAX_MODEL_LEN=32768
  fi
fi
[[ "$MAX_MODEL_LEN" =~ ^[0-9]+$ ]] || die "contexto inválido: $MAX_MODEL_LEN"

if [[ "$GPU_LAYERS" == "auto" ]]; then
  if [[ "$BACKEND" == "cpu" ]]; then GPU_LAYERS=0; else GPU_LAYERS=99; fi
fi
[[ "$GPU_LAYERS" =~ ^[0-9]+$ ]] || die "gpu-layers inválido: $GPU_LAYERS"

if [[ "$BACKEND" == "cpu" || "$BACKEND" == "vulkan" ]]; then
  FLASH_ATTN="auto"
else
  FLASH_ATTN="on"
fi

# --- Rutas -----------------------------------------------------------------
BIN_ROOT="$BASE_DIR/bin"
if [[ "$BACKEND" == "cuda" ]]; then
  BIN_DIR="$BIN_ROOT/cuda-$CUDA_TAG"
else
  BIN_DIR="$BIN_ROOT/$BACKEND"
fi
MODELS_DIR="$BASE_DIR/models"
GGUF_PATH="$MODELS_DIR/$MODEL_FILE"
MMPROJ_PATH="$MODELS_DIR/$MMPROJ_FILE"

# --- Asset del release -----------------------------------------------------
if [[ "$BACKEND" == "cuda" ]]; then
  ASSET="llama-${LLAMA_RELEASE}-bin-linux-cuda-${CUDA_TAG}-x64.tar.gz"
elif [[ "$BACKEND" == "rocm" ]]; then
  ASSET="llama-${LLAMA_RELEASE}-bin-ubuntu-rocm-7.2-x64.tar.gz"
elif [[ "$BACKEND" == "vulkan" ]]; then
  ASSET="llama-${LLAMA_RELEASE}-bin-ubuntu-vulkan-${ARCH_TAG}.tar.gz"
else
  ASSET="llama-${LLAMA_RELEASE}-bin-ubuntu-${ARCH_TAG}.tar.gz"
fi
RELEASE_URL="https://github.com/${LLAMA_REPO}/releases/download/${LLAMA_RELEASE}/${ASSET}"

if [[ "$MODEL" == "bonsai" && "$PACKING" != "q2" && "$LLAMA_RELEASE" != prism-* ]]; then
  warn "los packings pq2/ptq1 solo los lee el fork de PrismML;"
  info "  el release '$LLAMA_RELEASE' puede no cargarlos. Usa --packing q2 si es un llama.cpp oficial."
fi

# --- Espacio en disco ------------------------------------------------------
if [[ "$MIN_FREE_GB" == "0" ]]; then
  if [[ "$MODEL" == "glm" ]]; then
    MIN_FREE_GB=22
  elif [[ "$PACKING" == "ptq1" ]]; then
    MIN_FREE_GB=10
  else
    MIN_FREE_GB=12
  fi
  if (( VISION == 1 )); then MIN_FREE_GB=$(( MIN_FREE_GB + 1 )); fi
  # Si el modelo ya está descargado y completo, solo hace falta espacio para los binarios.
  if [[ -f "$GGUF_PATH" ]] && (( $(stat -Lc %s "$GGUF_PATH" 2>/dev/null || echo 0) == EXPECTED_SIZE )); then
    MIN_FREE_GB=2
  fi
fi
[[ "$MIN_FREE_GB" =~ ^[0-9]+$ ]] || die "MIN_FREE_GB inválido"
mkdir -p "$BASE_DIR"
FREE_GB="$(df -Pk "$BASE_DIR" | awk 'NR==2{printf "%d", $4/1024/1024}')"
[[ "$FREE_GB" =~ ^[0-9]+$ ]] || die "no pude leer el espacio libre de $BASE_DIR"
(( FREE_GB >= MIN_FREE_GB )) || die "necesito ${MIN_FREE_GB} GiB libres en $BASE_DIR y hay ${FREE_GB} GiB."
ok "espacio libre: ${FREE_GB} GiB"

info "configuración: modelo=$MODEL_LABEL ($MODEL_QUANT_LABEL)  contexto=$MAX_MODEL_LEN  slots=$PARALLEL  puerto=$PORT  host=$HOST"
info "binarios: $BIN_DIR"
info "modelo:   $GGUF_PATH"
if (( VISION == 1 )); then info "visión:   $MMPROJ_PATH"; fi

# --- Orden final -----------------------------------------------------------
SERVE_ARGS=(
  -m "$GGUF_PATH"
  --alias "$SERVED_NAME"
  --host "$HOST"
  --port "$PORT"
  -ngl "$GPU_LAYERS"
  -fa "$FLASH_ATTN"
  -c "$MAX_MODEL_LEN"
  -np "$PARALLEL"
  --jinja
  --metrics
  "${SAMPLING[@]}"
)
if (( VISION == 1 )); then SERVE_ARGS+=(-mm "$MMPROJ_PATH"); fi
if (( KV4 == 1 )); then SERVE_ARGS+=(-ctk q4_0 -ctv q4_0); fi
if [[ -n "$API_KEY" ]]; then SERVE_ARGS+=(--api-key "$API_KEY"); fi
if [[ -n "$EXTRA_ARGS" ]]; then
  # shellcheck disable=SC2206
  _extra=()
  read -r -a _extra <<< "$EXTRA_ARGS"
  SERVE_ARGS+=("${_extra[@]}")
fi

if [[ "$DRY_RUN" == "1" ]]; then
  printf '\n%sOrden que se ejecutaría:%s\n  ' "$B" "$N"
  printf '%q ' "$BIN_DIR/llama-server" "${SERVE_ARGS[@]}"
  printf '\n'
  exit 0
fi

if [[ "$ASSUME_YES" == "0" ]]; then
  printf '\n%s¿Continuar? [s/N] %s' "$B" "$N"
  read -r reply
  [[ "$reply" =~ ^[sSyY]$ ]] || { info "cancelado."; exit 0; }
fi

# ---------------------------------------------------------------------------
step "2/6 · Binarios de llama.cpp ($LLAMA_RELEASE)"
WANT_STAMP="$LLAMA_RELEASE $BACKEND${CUDA_TAG:+ cuda-$CUDA_TAG}"
if [[ "$REINSTALL" == "0" && -x "$BIN_DIR/llama-server" \
      && "$(cat "$BIN_DIR/.release" 2>/dev/null || true)" == "$WANT_STAMP" ]]; then
  ok "reutilizo $BIN_DIR"
else
  mkdir -p "$BIN_ROOT"
  TMP_DIR="$BIN_ROOT/.tmp-$$"
  TARBALL="$BIN_ROOT/.download-$$.tar.gz"
  rm -rf "$TMP_DIR"; mkdir -p "$TMP_DIR"
  info "descargando $ASSET"
  if have curl; then
    curl -fL --retry 5 --retry-delay 3 --progress-bar -o "$TARBALL" "$RELEASE_URL" \
      || die "no pude descargar $RELEASE_URL"
  else
    wget -O "$TARBALL" "$RELEASE_URL" || die "no pude descargar $RELEASE_URL"
  fi
  tar -xzf "$TARBALL" -C "$TMP_DIR" --strip-components=1 2>/dev/null || true
  if [[ ! -x "$TMP_DIR/llama-server" ]]; then
    rm -rf "$TMP_DIR"; mkdir -p "$TMP_DIR"
    tar -xzf "$TARBALL" -C "$TMP_DIR" || die "no pude extraer $ASSET"
  fi
  [[ -x "$TMP_DIR/llama-server" ]] || die "el paquete no contiene llama-server"
  rm -f "$TARBALL"
  rm -rf "$BIN_DIR"
  mkdir -p "$(dirname "$BIN_DIR")"
  mv "$TMP_DIR" "$BIN_DIR"
  printf '%s\n' "$WANT_STAMP" > "$BIN_DIR/.release"
  ok "instalado en $BIN_DIR"
fi

export LD_LIBRARY_PATH="$BIN_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$BIN_DIR/llama-server" --version >/dev/null 2>&1 \
  || die "llama-server no arranca en esta máquina (¿glibc < 2.34?). Prueba --backend cpu o compila desde fuente."
LLAMA_VERSION_LINE="$("$BIN_DIR/llama-server" --version 2>&1 | head -n1 || true)"
ok "${LLAMA_VERSION_LINE:-llama-server operativo}"

if [[ "$BACKEND" != "cpu" ]]; then
  DEVICES="$(timeout 30 "$BIN_DIR/llama-server" --list-devices 2>/dev/null || true)"
  if [[ -z "$DEVICES" || "$DEVICES" == *"(none)"* ]]; then
    warn "llama-server no ve ningún dispositivo $BACKEND"
    info "  revisa el driver; puedes forzar otro backend con --backend vulkan|cpu"
  fi
fi

# ---------------------------------------------------------------------------
step "3/6 · Modelo ($MODEL_FILE)"

file_size() { stat -Lc %s "$1" 2>/dev/null || echo 0; }

download_hf() {
  local repo="$1" file="$2" dest="$3" url auth=()
  url="https://huggingface.co/${repo}/resolve/main/${file}"

  if have hf; then
    if hf download "$repo" "$file" --local-dir "$(dirname "$dest")" \
       && [[ -f "$dest" ]]; then
      return 0
    fi
    warn "'hf download' falló; pruebo con curl"
  elif have huggingface-cli; then
    if huggingface-cli download "$repo" "$file" --local-dir "$(dirname "$dest")" \
       && [[ -f "$dest" ]]; then
      return 0
    fi
    warn "'huggingface-cli download' falló; pruebo con curl"
  fi

  [[ -n "$HF_TOKEN" ]] && auth=(-H "Authorization: Bearer $HF_TOKEN")
  if have curl; then
    if [[ -f "$dest.part" ]]; then
      curl -fL --retry 5 --retry-delay 3 "${auth[@]}" -C - --progress-bar -o "$dest.part" "$url"
    else
      curl -fL --retry 5 --retry-delay 3 "${auth[@]}" --progress-bar -o "$dest.part" "$url"
    fi
  elif have wget; then
    wget -c -O "$dest.part" "$url"
  else
    return 1
  fi
  mv -f "$dest.part" "$dest"
}

mkdir -p "$MODELS_DIR"

if [[ "$SKIP_DOWNLOAD" == "1" ]]; then
  [[ -f "$GGUF_PATH" ]] || die "--no-download pero no existe $GGUF_PATH"
  ACTUAL="$(file_size "$GGUF_PATH")"
  (( ACTUAL == EXPECTED_SIZE )) \
    || die "tamaño inesperado: $ACTUAL bytes (esperaba $EXPECTED_SIZE). Borra el fichero y reintenta."
  ok "uso el modelo existente: $GGUF_PATH"
elif [[ -f "$GGUF_PATH" ]] && (( $(file_size "$GGUF_PATH") == EXPECTED_SIZE )); then
  ok "reutilizo $GGUF_PATH ($(( EXPECTED_SIZE / 1000000000 )) GB)"
else
  info "descargando $MODEL_REPO · $MODEL_FILE ($(( EXPECTED_SIZE / 1000000000 )) GB)"
  download_hf "$MODEL_REPO" "$MODEL_FILE" "$GGUF_PATH" || die "falló la descarga del modelo"
  ACTUAL="$(file_size "$GGUF_PATH")"
  (( ACTUAL == EXPECTED_SIZE )) \
    || die "tamaño inesperado: $ACTUAL bytes (esperaba $EXPECTED_SIZE). Borra el fichero y reintenta."
  ok "modelo descargado: $GGUF_PATH"
fi

if [[ "$VISION" == "1" ]]; then
  if [[ -f "$MMPROJ_PATH" ]] && (( $(file_size "$MMPROJ_PATH") == MMPROJ_SIZE )); then
    ok "reutilizo $MMPROJ_PATH"
  elif [[ "$SKIP_DOWNLOAD" == "1" ]]; then
    [[ -f "$MMPROJ_PATH" ]] || die "--no-download pero no existe $MMPROJ_PATH"
    die "mmproj incompleto: $(file_size "$MMPROJ_PATH") bytes (esperaba $MMPROJ_SIZE). Bórralo y reintenta."
  else
    info "descargando $MMPROJ_FILE ($(( MMPROJ_SIZE / 1000000 )) MB)"
    download_hf "$MODEL_REPO" "$MMPROJ_FILE" "$MMPROJ_PATH" || die "falló la descarga del mmproj"
    (( $(file_size "$MMPROJ_PATH") == MMPROJ_SIZE )) || die "mmproj incompleto"
    ok "mmproj descargado"
  fi
fi

# ---------------------------------------------------------------------------
step "4/6 · Verificando el GGUF"

[[ "$(head -c 4 "$GGUF_PATH")" == "GGUF" ]] || die "$GGUF_PATH no es un fichero GGUF válido (¿descarga incompleta?)"
ok "cabecera GGUF correcta"

if [[ "$MODEL_VALIDATOR" == "bonsai" ]]; then
  if have python3; then
    python3 - "$GGUF_PATH" "$MODEL_TYPE" "$PACKING" <<'PY' || die "la verificación del GGUF falló"
import collections
import io
import struct
import sys

path, want_type, packing = sys.argv[1], int(sys.argv[2]), sys.argv[3]

with open(path, "rb") as fh:
    data = fh.read(32 * 1024 * 1024)

f = io.BytesIO(data)

def u32():
    return struct.unpack("<I", f.read(4))[0]

def u64():
    return struct.unpack("<Q", f.read(8))[0]

def string():
    n = u64()
    return f.read(n).decode("utf-8", "replace")

SCALAR = {0: "B", 1: "b", 2: "H", 3: "h", 4: "I", 5: "i", 6: "f",
          7: "?", 10: "Q", 11: "q", 12: "d"}

def skip(t):
    if t in SCALAR:
        f.seek(struct.calcsize("<" + SCALAR[t]), 1)
    elif t == 8:
        f.seek(u64(), 1)
    elif t == 9:
        et, n = u32(), u64()
        for _ in range(n):
            skip(et)
    else:
        raise ValueError("tipo de metadato desconocido: %d" % t)

magic = f.read(4)
if magic != b"GGUF":
    sys.exit("magic distinto de GGUF")
version = u32()
n_tensors, n_kv = u64(), u64()
meta = {}
for _ in range(n_kv):
    key = string()
    t = u32()
    if key in ("general.architecture", "general.name", "prism.hadamard.block_size",
               "prism.hadamard.transform"):
        if t == 8:
            meta[key] = string()
        elif t in SCALAR:
            meta[key] = struct.unpack("<" + SCALAR[t],
                                      f.read(struct.calcsize("<" + SCALAR[t])))[0]
        else:
            skip(t)
    else:
        skip(t)

types = collections.Counter()
for _ in range(n_tensors):
    string()
    nd = u32()
    for _ in range(nd):
        u64()
    types[u32()] += 1
    u64()

arch = meta.get("general.architecture", "?")
block = meta.get("prism.hadamard.block_size", "?")
print("    GGUF v%d · %d tensores · arquitectura=%s · hadamard=%s"
      % (version, n_tensors, arch, block))
print("    tipos de tensor:", dict(sorted(types.items())))

if arch not in ("qwen35", "qwen3_5"):
    print("    aviso: arquitectura inesperada para Bonsai 2: %s" % arch)
if block not in (1024, "?"):
    print("    aviso: bloque Hadamard inesperado: %s" % block)
if block == "?":
    print("    aviso: el GGUF no declara prism.hadamard.block_size")

if types[want_type] == 0:
    sys.exit("el fichero no contiene tensores del tipo %d (%s); "
             "¿packing equivocado? Usa --packing pq2/ptq1/q2 según el fichero."
             % (want_type, packing))
PY
    ok "packing $PACKING confirmado en el GGUF"
  else
    warn "python3 no está instalado; omito la verificación de arquitectura y packing"
  fi
else
  if have python3; then
    python3 - "$GGUF_PATH" <<'PY' || warn "no pude leer la cabecera del GGUF"
import io
import struct
import sys

with open(sys.argv[1], "rb") as fh:
    data = fh.read(1024 * 1024)
f = io.BytesIO(data)

def u32():
    return struct.unpack("<I", f.read(4))[0]

def u64():
    return struct.unpack("<Q", f.read(8))[0]

def string():
    n = u64()
    return f.read(n).decode("utf-8", "replace")

SCALAR = {0: "B", 1: "b", 2: "H", 3: "h", 4: "I", 5: "i", 6: "f",
          7: "?", 10: "Q", 11: "q", 12: "d"}

def skip(t):
    if t in SCALAR:
        f.seek(struct.calcsize("<" + SCALAR[t]), 1)
    elif t == 8:
        f.seek(u64(), 1)
    elif t == 9:
        et, n = u32(), u64()
        for _ in range(n):
            skip(et)
    else:
        raise ValueError(t)

magic = f.read(4)
if magic != b"GGUF":
    sys.exit("magic distinto de GGUF")
version = u32()
n_tensors, n_kv = u64(), u64()
meta = {}
for _ in range(n_kv):
    key = string()
    t = u32()
    if key in ("general.architecture", "general.name"):
        if t == 8:
            meta[key] = string()
        elif t in SCALAR:
            meta[key] = struct.unpack("<" + SCALAR[t],
                                      f.read(struct.calcsize("<" + SCALAR[t])))[0]
        else:
            skip(t)
    else:
        skip(t)
    if "general.architecture" in meta and "general.name" in meta:
        break
print("    GGUF v%d · %d tensores · arquitectura=%s · nombre=%s"
      % (version, n_tensors, meta.get("general.architecture", "?"),
         meta.get("general.name", "?")))
PY
  else
    warn "python3 no está instalado; omito la comprobación de arquitectura"
  fi
  ok "GGUF válido ($MODEL_QUANT_LABEL)"
fi

# ---------------------------------------------------------------------------
step "5/6 · Preparando el servidor"

DISPLAY_HOST="$HOST"
if [[ "$HOST" == "0.0.0.0" || "$HOST" == "::" ]]; then DISPLAY_HOST="localhost"; fi

printf '\n%s==>%s %sSirviendo la API%s\n' "$B" "$N" "$B" "$N"
info "OpenAI-compatible en http://${DISPLAY_HOST}:${PORT}/v1"
info "interfaz web:        http://${DISPLAY_HOST}:${PORT}/"
info "salud: /health · métricas: /metrics"
if (( VISION == 1 )); then info "visión activada (mmproj Q8_0)"; fi
if [[ -n "$API_KEY" ]]; then info "API_KEY activa: manda 'Authorization: Bearer \$API_KEY'"; fi
info "Ctrl+C para parar."

step "6/6 · Arrancando llama-server"
exec "$BIN_DIR/llama-server" "${SERVE_ARGS[@]}"
