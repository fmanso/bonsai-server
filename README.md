# bonsai-vllm-server

Scripts para **descargar Ternary Bonsai 2 27B** (PrismML, GGUF `Q2_0`) y **servirlo con vLLM** como API compatible con OpenAI, en una sola orden.

- `serve-bonsai-vllm.sh` → Ubuntu / Debian (bash)
- `serve-bonsai-vllm.zsh` → Arch Linux (zsh)
- `test-api.sh` → comprobación del endpoint

> **Estado: experimental.** vLLM no soporta de serie los pesos ternarios de Bonsai. Este repo usa el plugin GGUF *out-of-tree* [`estridell/vllm-gguf-plugin`](https://github.com/estridell/vllm-gguf-plugin), rama `prism-ternary`, que el autor ha validado **solo en `sm_75` y `sm_120`** (RTX 2070 y RTX 5060 Ti) con **Q2_0 de 27B a 8.192 tokens**. Todo lo demás — tu GPU, más contexto, visión — está sin verificar. Está explicado en [Limitaciones](#limitaciones).

---

## Qué hace

```
descarga el plugin (commit fijado) → crea un venv con uv → instala vLLM ≥ 0.25.1
→ verifica el lector GGUF ternario → descarga el .gguf (7,63 GB) → vllm serve
```

Es idempotente: si lo relanzas, reutiliza el venv y el modelo ya descargados.

---

## Requisitos

| | Mínimo | Recomendado |
|---|---|---|
| GPU | NVIDIA con ≥ 16 GB y `sm_75`/`sm_120` (validado) | 24 GB (RTX 3090/4090) |
| Driver | `nvidia-smi` funcionando | driver propietario reciente |
| Disco | 25 GB libres | 40 GB |
| Sistema | Ubuntu 22.04+/Debian 12+ o Arch actualizado | — |
| Software | `git`, `curl`, `nvcc` (toolkit CUDA) | `bash` 5 / `zsh` 5.9 |

El script comprueba driver, GPU, VRAM, espacio y `nvcc` antes de tocar nada, y aborta con un mensaje claro si falta algo.

---

## Instalación rápida

### Ubuntu / Debian

```bash
sudo apt update && sudo apt install -y curl git
# toolkit CUDA solo si no tienes nvcc:
# sudo apt install -y nvidia-cuda-toolkit

git clone https://github.com/fmanso/bonsai-vllm-server.git
cd bonsai-vllm-server
bash serve-bonsai-vllm.sh
```

### Arch Linux

```bash
sudo pacman -S --needed curl git base-devel
# toolkit CUDA solo si no tienes nvcc:
# sudo pacman -S --needed cuda

git clone https://github.com/fmanso/bonsai-vllm-server.git
cd bonsai-vllm-server
zsh serve-bonsai-vllm.zsh
```

La primera ejecución tarda **entre 10 y 30 minutos**: instala PyTorch + vLLM (unos 8–10 GB de dependencias) y descarga 7,63 GB del modelo. Las siguientes arrancan en segundos.

Al terminar verás:

```
==> Sirviendo la API
    OpenAI-compatible en http://localhost:8000/v1
    documentación interactiva: http://localhost:8000/docs
    Ctrl+C para parar.
INFO:     Uvicorn running on http://0.0.0.0:8000
```

---

## Uso

```bash
# valores por defecto
bash serve-bonsai-vllm.sh

# sin preguntas, en otro puerto y con 16k de contexto
bash serve-bonsai-vllm.sh --yes --port 9000 --max-model-len 16384

# con clave de API
API_KEY=sk-local bash serve-bonsai-vllm.sh -y

# reutilizar un modelo ya descargado, sin red
bash serve-bonsai-vllm.sh --no-download
```

### Opciones

| Flag | Por defecto | Qué hace |
|---|---|---|
| `-y, --yes` | no | No pedir confirmación |
| `-p, --port N` | `8000` | Puerto HTTP |
| `-l, --max-model-len N` | `auto` | Contexto máximo. `auto` = 32768 con ≥20 GB de VRAM, 8192 por debajo |
| `-g, --gpu-mem F` | `0.90` | Fracción de VRAM reservada por vLLM |
| `-m, --profile P` | `bonsai2` | `bonsai2` (Bonsai 2 27B) o `bonsai1` (generación anterior: es el par exacto que el autor del plugin validó) |
| `-d, --dir RUTA` | `~/.local/share/bonsai-vllm` | Dónde viven venv, plugin y modelos |
| `--reinstall` | — | Recrea el venv desde cero |
| `--no-download` | — | No descarga; usa el `.gguf` que ya está en disco |
| `-h, --help` | — | Ayuda |

Variables de entorno útiles: `API_KEY`, `EXTRA_ARGS` (flags extra para `vllm serve`), `HF_TOKEN`, `BASE_DIR`, `PLUGIN_COMMIT`, `HF_HOME`.

---

## Probar la API

```bash
bash test-api.sh
# o a mano:
curl -s http://localhost:8000/v1/models | python3 -m json.tool

curl -s http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "bonsai-2-27b",
    "messages": [{"role":"user","content":"¿Qué es un peso ternario?"}],
    "max_tokens": 16384,
    "reasoning_effort": "medium"
  }' | python3 -m json.tool
```

Con el SDK de OpenAI, apuntando a tu servidor:

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8000/v1", api_key="not-needed")
r = client.chat.completions.create(
    model="bonsai-2-27b",
    messages=[{"role": "user", "content": "Explica la rotación de Hadamard en una frase."}],
    max_tokens=16384,
    extra_body={"reasoning_effort": "medium"},
)
print(r.choices[0].message.content)
```

> **`max_tokens` alto, siempre.** El modelo razona antes de contestar y el razonamiento consume presupuesto de salida. Con `max_tokens` pequeño recibirás respuestas vacías o cortadas. Es el problema más reportado en el `KNOWN_ISSUES` del modelo.

---

## Limitaciones

Esto no es un servidor de producción. Léelo antes de fiarte:

1. **Cobertura de GPU.** El plugin solo se ha validado en `sm_75` (RTX 2070) y `sm_120` (RTX 5060 Ti). Ampere (`sm_86`, RTX 3090) y Ada (`sm_89`, RTX 4090) probablemente funcionen —los kernels son CUDA estándar— pero **no está verificado**. Si falla, el error saldrá al cargar el modelo, no después.
2. **Solo `Q2_0`.** Las otras dos empaquetaduras de Bonsai 2 (`PTQ1_0`, 5,95 GB, y `PQ2_0`, 7,21 GB) usan kernels propios de PrismML y **no** están cubiertas por este plugin. Con vLLM, `Q2_0` (7,63 GB) es la única opción.
3. **Sin visión.** Este camino es solo texto. El proyector multimodal (`mmproj`) no está integrado.
4. **Lotes de 8.** El kernel ternario nativo (MMVQ) está validado hasta batch 8. Por encima, el decodificador dequantiza por trozos y va más lento: subir `--max-num-seqs` no acelera nada.
5. **Contexto > 8k sin validar.** El autor probó 8.192 tokens. `auto` pone 32.768 en GPUs de 24 GB; si arranca con OOM, baja a 16.384 o 8.192 con `--max-model-len`.
6. **Bonsai 2 no tiene repo de tokenizer publicado.** PrismML publica `Ternary-Bonsai-27B-unpacked` solo para la generación anterior. Para Bonsai 2 el script usa `Qwen/Qwen3.8-27B` —la arquitectura es idéntica, así que el vocabulario coincide— pero **el chat template de Bonsai 2 no se aplica**. Consecuencia práctica: `reasoning_effort` puede no comportarse igual. El perfil `--profile bonsai1` usa el par exacto que el autor validó.
7. **Conflicto de type-ID 42.** PrismML y ggml upstream usan el mismo número para layouts distintos. Por eso el script fija el commit del lector GGUF y **verifica los layouts al instalar** (`Q1_0 = 128/18`, `Q2_0 = 128/34`). No lo sustituyas por un `gguf` de PyPI.
8. **El servidor no se queda en segundo plano.** El script termina con `exec vllm serve` en primer plano. Para dejarlo corriendo: `tmux`, `nohup`, o un unit de systemd con `ExecStart=` apuntando al script.

### Si lo que quieres es el camino soportado

Para uso serio, PrismML soporta **llama.cpp**: los binarios de [PrismML-Eng/llama.cpp](https://github.com/PrismML-Eng/llama.cpp/releases) traen los kernels `PQ2_0` y `PTQ1_0`, y `llama-server` también expone una API compatible con OpenAI (`/v1/chat/completions`). Ahí sí funcionan los 5,95 GB, la visión con `mmproj` y el contexto de 262k. Este repo existe porque pediste vLLM: batching real, `/v1` con métricas y PagedAttention. Si lo que buscas es que funcione hoy, usa llama.cpp.

---

## Problemas frecuentes

| Síntoma | Causa | Solución |
|---|---|---|
| `CUDA out of memory` al arrancar | Contexto o `--gpu-mem` demasiado altos | `--max-model-len 8192` y `--gpu-mem 0.85` |
| Respuestas vacías o cortadas | `max_tokens` pequeño; el razonamiento se come el presupuesto | `max_tokens: 16384` o más, `reasoning_effort: "medium"` |
| HTTP 500 con `reasoning_effort: "high"` | El template acepta `low`, `medium` y `xhigh`; `high` no existe | Usa `medium` o `xhigh` |
| `layout Q2_0 inesperado` | Se instaló un `gguf` de PyPI en vez del de PrismML | `--reinstall`; no toques las dependencias del plugin |
| `no encuentro nvidia-smi` | Driver no instalado o módulo no cargado | Ubuntu: `ubuntu-drivers autoinstall` · Arch: `pacman -S nvidia-open` + reboot |
| La instalación falla compilando kernels | Falta `nvcc` | Ubuntu: `nvidia-cuda-toolkit` · Arch: `cuda` |
| Descarga muy lenta | HF sin CDN cercana | `HF_HUB_ENABLE_HF_TRANSFER=1` (requiere `hf_transfer`) |

Log completo de la instalación: `~/.local/share/bonsai-vllm/install.log`.

---

## Verificación honesta

Estos scripts se publicaron sin haberse ejecutado en una máquina con GPU. Están construidos sobre los comandos documentados por el autor del plugin (commit `8f17985`, rama `prism-ternary`) y sobre los ficheros publicados en Hugging Face, y la comprobación de layouts GGUF es la misma que propone su guía de instalación. Aun así, **la primera ejecución en tu tarjeta es la prueba real**: si algo falla, el error aparecerá en el paso 5 (instalación) o al cargar el modelo, y el log dirá exactamente dónde.

## Créditos y licencia

- Modelo: [PrismML](https://prismml.com) — Ternary Bonsai 2 27B, derivado de Qwen3.8-27B, licencia **Apache 2.0**.
- Soporte vLLM: [estridell/vllm-gguf-plugin](https://github.com/estridell/vllm-gguf-plugin) (rama `prism-ternary`), y el trabajo de [Anthony Morley](https://anthonymorley.com/projects/prism) sobre PQ2 en vLLM.
- Scripts de este repo: **MIT** (ver `LICENSE`).
