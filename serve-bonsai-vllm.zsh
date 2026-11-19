#!/usr/bin/env zsh
# ---------------------------------------------------------------------------
# serve-bonsai-vllm.zsh — Arch Linux (zsh)
# Descarga Ternary Bonsai 2 27B (GGUF Q2_0) y lo sirve con vLLM como API
# compatible con OpenAI.
#
#   zsh serve-bonsai-vllm.zsh             # instala, descarga y sirve
#   zsh serve-bonsai-vllm.zsh --help
#
# Requiere: driver NVIDIA funcionando (nvidia-smi), git, curl.
# ---------------------------------------------------------------------------
set -euo pipefail

VERSION="1.0.0"

# --- Configuración por defecto (todo se puede sobrescribir por entorno) -----
PLUGIN_REPO="${PLUGIN_REPO:-https://github.com/estridell/vllm-gguf-plugin.git}"
PLUGIN_COMMIT="${PLUGIN_COMMIT:-8f179856c037d7c4aa246abb6a2fac596b957410}"
BASE_DIR="${BASE_DIR:-$HOME/.local/share/bonsai-vllm}"
PROFILE="${PROFILE:-bonsai2}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8000}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-auto}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.90}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}"
API_KEY="${API_KEY:-}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
MIN_FREE_GB="${MIN_FREE_GB:-25}"

ASSUME_YES=0
SKIP_DOWNLOAD=0
REINSTALL=0

# --- Salida ----------------------------------------------------------------
if [[ -t 1 ]]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else
  B=""; G=""; Y=""; R=""; N=""
fi
step() { printf '\n%s==>%s %s%s\n' "$B" "$N" "$B" "$*$N" }
info() { printf '    %s\n' "$*" }
ok()   { printf '    %s✓%s %s\n' "$G" "$N" "$*" }
warn() { printf '    %s!%s %s\n' "$Y" "$N" "$*" }
die()  { printf '\n%s✗ %s%s\n' "$R" "$*" "$N" >&2; exit 1 }

usage() {
  cat <<EOF
serve-bonsai-vllm.zsh v${VERSION} — sirve Ternary Bonsai con vLLM (Arch Linux)

USO
  zsh serve-bonsai-vllm.zsh [opciones]

OPCIONES
  -y, --yes              No preguntar nada
  -p, --port N           Puerto HTTP (por defecto 8000)
  -l, --max-model-len N  Contexto máximo en tokens (por defecto: auto según VRAM)
  -g, --gpu-mem F        Fracción de VRAM para vLLM (por defecto 0.90)
  -m, --profile P        bonsai2 (defecto) | bonsai1 (generación anterior, par validado)
  -d, --dir RUTA         Directorio base (defecto ~/.local/share/bonsai-vllm)
      --reinstall        Recrea el entorno virtual desde cero
      --no-download      No descargar el modelo (ya está en disco)
  -h, --help             Esta ayuda

ENTORNO
  API_KEY=sk-...         Si se define, la API exige Authorization: Bearer
  EXTRA_ARGS="..."       Flags extra para 'vllm serve'
  HF_TOKEN=...           Si el repo exigiera autenticación
  BASE_DIR, PORT, MAX_MODEL_LEN, GPU_MEM_UTIL, MAX_NUM_SEQS, PLUGIN_COMMIT

PAQUETES ARCH
  sudo pacman -S --needed curl git base-devel cuda   # 'cuda' solo si falta nvcc

EJEMPLOS
  zsh serve-bonsai-vllm.zsh --yes
  zsh serve-bonsai-vllm.zsh --port 9000 --max-model-len 8192
  API_KEY=sk-local zsh serve-bonsai-vllm.zsh -y
EOF
}

while (( $# > 0 )); do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    -p|--port) PORT="${2:?falta el puerto}"; shift 2 ;;
    -l|--max-model-len) MAX_MODEL_LEN="${2:?falta el valor}"; shift 2 ;;
    -g|--gpu-mem) GPU_MEM_UTIL="${2:?falta el valor}"; shift 2 ;;
    -m|--profile) PROFILE="${2:?falta el perfil}"; shift 2 ;;
    -d|--dir) BASE_DIR="${2:?falta la ruta}"; shift 2 ;;
    --reinstall) REINSTALL=1; shift ;;
    --no-download) SKIP_DOWNLOAD=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "opción desconocida: $1 (usa --help)" ;;
  esac
done

case "$PROFILE" in
  bonsai2)
    MODEL_REPO="prism-ml/Ternary-Bonsai-2-27B-gguf"
    MODEL_FILE="Ternary-Bonsai-2-27B-Q2_0.gguf"
    TOKENIZER="Qwen/Qwen3.8-27B"
    SERVED_NAME="bonsai-2-27b"
    ;;
  bonsai1)
    MODEL_REPO="prism-ml/Ternary-Bonsai-27B-gguf"
    MODEL_FILE="Ternary-Bonsai-27B-Q2_0.gguf"
    TOKENIZER="prism-ml/Ternary-Bonsai-27B-unpacked"
    SERVED_NAME="bonsai-27b"
    ;;
  *) die "perfil desconocido: $PROFILE (usa bonsai2 o bonsai1)" ;;
esac

VENV_DIR="$BASE_DIR/venv"
PLUGIN_DIR="$BASE_DIR/vllm-gguf-plugin"
MODELS_DIR="$BASE_DIR/models"
export HF_HOME="${HF_HOME:-$BASE_DIR/hf}"

# ---------------------------------------------------------------------------
step "1/7 · Comprobando el sistema"
[[ "$(uname -s)" == "Linux" ]] || die "este script es para Linux (Arch)."
if [[ -r /etc/os-release ]]; then
  source /etc/os-release
  info "distribución: ${PRETTY_NAME:-desconocida}"
  if [[ "${ID:-}" == "arch" || "${ID_LIKE:-}" == *arch* ]]; then
    ok "Arch Linux detectado"
  else
    warn "no parece Arch; para Ubuntu/Debian usa serve-bonsai-vllm.sh"
  fi
fi
command -v curl >/dev/null || die "falta curl: sudo pacman -S curl"
command -v git  >/dev/null || die "falta git: sudo pacman -S git"
command -v nvidia-smi >/dev/null || die "no encuentro nvidia-smi: instala nvidia-open o nvidia-dkms y reinicia."
nvidia-smi -L >/dev/null 2>&1 || die "el driver NVIDIA no responde (¿módulo cargado?). Prueba 'nvidia-smi' y 'dmesg | grep -i nvidia'."
VRAM_MB="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n1 | tr -d ' ')"
[[ "$VRAM_MB" == <-> ]] || die "no puedo leer la VRAM de la GPU."
ok "GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1) — ${VRAM_MB} MiB"
if (( $+commands[nvcc] )); then
  ok "CUDA toolkit: $(nvcc --version | awk -F'release ' '/release/{print $2}' | cut -d, -f1)"
else
  warn "no hay nvcc (paquete 'cuda'). El plugin puede necesitar compilar kernels."
  info "  Arch: sudo pacman -S --needed cuda"
fi
mkdir -p "$BASE_DIR"
FREE_GB="$(df -BG --output=avail "$BASE_DIR" | tail -n1 | tr -dc '0-9')"
(( ${FREE_GB:-0} >= MIN_FREE_GB )) || die "necesito ${MIN_FREE_GB} GB libres en $BASE_DIR y hay ${FREE_GB} GB."
ok "espacio libre: ${FREE_GB} GB"

# Contexto por defecto según VRAM (8k es la forma validada por el autor del plugin)
if [[ "$MAX_MODEL_LEN" == "auto" ]]; then
  if (( VRAM_MB >= 20000 )); then MAX_MODEL_LEN=32768; else MAX_MODEL_LEN=8192; fi
fi
info "configuración: perfil=$PROFILE  modelo=$MODEL_FILE  contexto=$MAX_MODEL_LEN  puerto=$PORT"

if (( ASSUME_YES == 0 )); then
  read "reply?¿Continuar? [s/N] "
  [[ "$reply" == [sSyY] ]] || { info "cancelado."; exit 0 }
fi

# ---------------------------------------------------------------------------
step "2/7 · Preparando uv"
if (( $+commands[uv] )); then
  ok "uv $(uv --version | awk '{print $2}')"
else
  info "instalando uv en ~/.local/bin"
  curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 || die "falló la instalación de uv"
  export PATH="$HOME/.local/bin:$PATH"
  (( $+commands[uv] )) || die "uv no está en el PATH tras instalarlo"
  ok "uv $(uv --version | awk '{print $2}')"
fi

# ---------------------------------------------------------------------------
step "3/7 · Clonando el plugin GGUF de vLLM (rama prism-ternary)"
if [[ -d "$PLUGIN_DIR/.git" ]]; then
  info "reutilizando $PLUGIN_DIR"
  git -C "$PLUGIN_DIR" fetch --quiet origin || warn "no pude hacer fetch; sigo con lo que hay"
else
  rm -rf "$PLUGIN_DIR"
  git clone --quiet --branch prism-ternary --single-branch "$PLUGIN_REPO" "$PLUGIN_DIR" \
    || die "no pude clonar $PLUGIN_REPO"
fi
git -C "$PLUGIN_DIR" checkout --quiet "$PLUGIN_COMMIT" 2>/dev/null \
  || warn "no pude fijar el commit $PLUGIN_COMMIT; usando el HEAD de la rama"
ok "plugin en $(git -C "$PLUGIN_DIR" rev-parse --short HEAD)"

# ---------------------------------------------------------------------------
step "4/7 · Creando el entorno virtual (Python $PYTHON_VERSION)"
if (( REINSTALL == 1 )) && [[ -d "$VENV_DIR" ]]; then
  info "borrando $VENV_DIR"
  rm -rf "$VENV_DIR"
fi
if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  uv venv --python "$PYTHON_VERSION" "$VENV_DIR" >/dev/null || die "no pude crear el venv"
fi
source "$VENV_DIR/bin/activate"
ok "python $(python --version 2>&1 | awk '{print $2}') en $VENV_DIR"

# ---------------------------------------------------------------------------
step "5/7 · Instalando vLLM y el plugin (esto tarda: 5–20 min)"
info "compilando/instalando; el log completo está en $BASE_DIR/install.log"
set +e
( cd "$PLUGIN_DIR" && uv pip install -e . --torch-backend=auto ) 2>&1 | tee "$BASE_DIR/install.log" | tail -n 5
install_rc=(${pipestatus[@]})
set -e
(( ${install_rc[1]} == 0 )) || die "falló la instalación. Revisa $BASE_DIR/install.log"
ok "instalado: $(python -c 'import vllm; print("vllm", vllm.__version__)')"

# ---------------------------------------------------------------------------
step "6/7 · Verificando el lector GGUF ternario"
verif="$(python - <<'PY'
import gguf
for name in ("Q1_0", "Q2_0"):
    t = getattr(gguf.GGMLQuantizationType, name)
    print(name, int(t), gguf.GGML_QUANT_SIZES[t])
PY
)"
print -r -- "$verif" | sed 's/^/    /'
print -r -- "$verif" | grep -q "^Q1_0 41 (128, 18)$" || die "layout Q1_0 inesperado: el lector GGUF no es el de PrismML"
print -r -- "$verif" | grep -q "^Q2_0 42 (128, 34)$" || die "layout Q2_0 inesperado: el lector GGUF no es el de PrismML"
ok "lector ternario correcto (Q1_0 = 128/18, Q2_0 = 128/34)"

# ---------------------------------------------------------------------------
step "7/7 · Descargando el modelo"
GGUF_PATH="$MODELS_DIR/$MODEL_FILE"
if (( SKIP_DOWNLOAD == 1 )); then
  [[ -f "$GGUF_PATH" ]] || die "--no-download pero no existe $GGUF_PATH"
  ok "uso el modelo existente: $GGUF_PATH"
else
  mkdir -p "$MODELS_DIR"
  info "repo $MODEL_REPO · fichero $MODEL_FILE"
  if (( $+commands[hf] )); then
    hf download "$MODEL_REPO" "$MODEL_FILE" --local-dir "$MODELS_DIR" \
      || die "falló la descarga del modelo"
  else
    huggingface-cli download "$MODEL_REPO" "$MODEL_FILE" --local-dir "$MODELS_DIR" \
      || die "falló la descarga del modelo"
  fi
  [[ -f "$GGUF_PATH" ]] || die "el fichero no está donde debería: $GGUF_PATH"
  ok "$(du -h "$GGUF_PATH" | cut -f1) en $GGUF_PATH"
  info "descargando el tokenizer/config de $TOKENIZER"
  hf download "$TOKENIZER" --local-dir "$BASE_DIR/tokenizer" >/dev/null 2>&1 \
    || warn "no pude pre-descargar el tokenizer; vLLM lo bajará al arrancar"
fi

# ---------------------------------------------------------------------------
step "Sirviendo la API"
BASE_URL="http://localhost:$PORT"
info "OpenAI-compatible en $BASE_URL/v1"
info "documentación interactiva: $BASE_URL/docs"
if [[ -n "$API_KEY" ]]; then info "API_KEY activa: manda 'Authorization: Bearer \$API_KEY'"; fi
info "Ctrl+C para parar."

SERVE_ARGS=(
  "$GGUF_PATH"
  --served-model-name "$SERVED_NAME"
  --tokenizer "$TOKENIZER"
  --host "$HOST"
  --port "$PORT"
  --max-model-len "$MAX_MODEL_LEN"
  --gpu-memory-utilization "$GPU_MEM_UTIL"
  --max-num-seqs "$MAX_NUM_SEQS"
  --kv-cache-dtype auto
  --mamba-ssm-cache-dtype float32
  --generation-config vllm
  --seed 0
)
if [[ -n "$API_KEY" ]]; then SERVE_ARGS+=(--api-key "$API_KEY"); fi
if [[ -n "$EXTRA_ARGS" ]]; then SERVE_ARGS+=(${=EXTRA_ARGS}); fi

exec vllm serve "${SERVE_ARGS[@]}"
