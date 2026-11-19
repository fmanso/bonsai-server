# bonsai-server

Servir **Ternary Bonsai 2 27B** (PrismML, GGUF) como API compatible con OpenAI usando `llama-server`, en una orden.

El repo conserva el nombre `bonsai-vllm-server` por historial, pero **ya no usa vLLM**: vLLM no puede servir Bonsai 2 hoy (ver [Por qué no vLLM](#por-qué-no-vllm)).

---

## Empieza aquí

Pensado para una máquina Linux con **RTX 3090 (24 GB)** o **RTX 5070 (12 GB)**, pero la detección es automática y también funciona con AMD, Vulkan o CPU.

### 0. Comprueba el driver NVIDIA

```bash
nvidia-smi
```

Si no funciona, instala el driver y **reinicia**:

```bash
sudo ubuntu-drivers install     # Ubuntu
sudo apt install nvidia-driver  # Debian (repos non-free)
sudo pacman -S nvidia-open      # Arch
```

El script también lo detecta, te ofrece instalarlo (Ubuntu/Arch) o te da la orden exacta. No se queda usando la CPU en silencio.

### 1. Clona y arranca

```bash
git clone https://github.com/fmanso/bonsai-vllm-server.git
cd bonsai-vllm-server
bash serve-bonsai.sh -y
```

Si no tienes `git` en la máquina, descarga los dos scripts y ejecuta:

```bash
curl -fsSLO https://raw.githubusercontent.com/fmanso/bonsai-vllm-server/main/serve-bonsai.sh
curl -fsSLO https://raw.githubusercontent.com/fmanso/bonsai-vllm-server/main/test-api.sh
bash serve-bonsai.sh -y
```

La primera ejecución instala lo que falte (`curl`, `tar`, `python3`), descarga el binario de llama.cpp (unos 200 MB con CUDA) y el modelo (7,21 GB), lo verifica y arranca la API. Tarda unos minutos según la conexión; las siguientes arrancan en segundos.

### 2. Comprueba

```bash
bash test-api.sh
```

Deberías ver `OK: el endpoint responde en formato OpenAI.`

### 3. Qué esperar en cada máquina

| Máquina | Qué detecta | Contexto por defecto | Comando |
|---|---|---|---|
| RTX 3090 24 GB | CUDA (12.8 o 13.3) | `65536` | `bash serve-bonsai.sh -y` |
| RTX 5070 12 GB | CUDA 12.8+ (Blackwell) | `16384` | `bash serve-bonsai.sh -y` |

En la 5070, si quieres más contexto para que el razonamiento tenga sitio, usa el packing pequeño:

```bash
bash serve-bonsai.sh -y --packing ptq1 -l 32768
```

### 4. Acceso desde otra máquina de la red

Por defecto escucha solo en `127.0.0.1`. Para exponerlo:

```bash
API_KEY=sk-local bash serve-bonsai.sh -y --host 0.0.0.0
```

Y desde el otro equipo:

```bash
BASE_URL=http://IP-DEL-SERVIDOR:8000 API_KEY=sk-local bash test-api.sh
```

Abre el puerto en el firewall si hace falta. El health check (`/health`) es público; el resto exige la clave.

### Antes de descargar 7 GB: `--dry-run`

```bash
bash serve-bonsai.sh --dry-run
```

Enseña el backend, la VRAM, el contexto y la orden final que ejecutaría, sin tocar nada.

---

## Qué hace

```
instala dependencias que falten → detecta GPU/CPU → descarga el binario de
llama.cpp (CUDA/ROCm/Vulkan/CPU) → descarga el GGUF (PQ2_0, 7,21 GB)
→ verifica el fichero → llama-server
```

Es idempotente: si lo relanzas, reutiliza los binarios y el modelo ya descargados.

No compila nada y no necesita toolkit CUDA: usa los binarios precompilados de [PrismML-Eng/llama.cpp](https://github.com/PrismML-Eng/llama.cpp). Las dependencias del sistema (`curl`/`wget`, `tar`, `python3`) se instalan solas con el gestor de paquetes de la distro si faltan (necesita `sudo`).

---

## Por qué no vLLM

Los scripts antiguos instalaban vLLM + un plugin GGUF *out-of-tree*. No puede funcionar con Bonsai 2:

1. **Layout incompatible.** El `Q2_0` de Bonsai 2 usa tipo 42 con **bloques de 64 pesos (18 bytes)**. El plugin fijado (commit de julio de 2026) espera el layout antiguo de **128 pesos (34 bytes)** y rechaza explícitamente el de grupo 64.
2. **Falta la rotación Hadamard.** Los pesos de Bonsai 2 se guardan en una base rotada (`prism.hadamard.*`, bloque 1024) y el runtime debe aplicar la transformación a las activaciones. El plugin no tiene ninguna implementación de Hadamard: aunque cargara, generaría basura.
3. **Soporte oficial.** La model card y el `KNOWN_ISSUES` de Bonsai 2 dan **llama.cpp** como backend. `PQ2_0`/`PTQ1_0` necesitan el fork de PrismML; `Q2_0` funciona en llama.cpp oficial desde `b11556`.

Por eso este repo sirve el modelo por el camino soportado. Si necesitas PagedAttention o el batching de vLLM, hoy no hay forma con Bonsai 2.

---

## Requisitos

| | Mínimo | Recomendado |
|---|---|---|
| Sistema | Linux x86_64 (glibc ≥ 2.34: Ubuntu 22.04+, Debian 12+) | Ubuntu 24.04 / Arch actualizado |
| Acelerador | GPU Vulkan o CPU (lento) | NVIDIA (CUDA) o AMD (ROCm) |
| VRAM | 8 GB con `--packing ptq1` y `-l 8192` | 12 GB (16k) · 16 GB (32k) · 24 GB (64k) |
| RAM | 16 GB en CPU | 32 GB+ en CPU |
| Disco | 10 GB (`ptq1`) | 15 GB |
| Software | se instala solo: `curl`/`wget`, `tar`, `python3` | `hf` (descarga paralela, opcional) |

No hace falta `nvcc` ni compilador; `git` solo para clonar el repo. El script instala las dependencias que falten (pide `sudo`). La detección de hardware es automática; no se asume ninguna marca ni modelo de GPU.

---

## Uso

```bash
# valores por defecto (detecta hardware)
bash serve-bonsai.sh

# sin preguntas, otro puerto y 32k de contexto
bash serve-bonsai.sh --yes --port 9000 --max-model-len 32768

# con clave de API y expuesto en la red
API_KEY=sk-local bash serve-bonsai.sh --host 0.0.0.0 -y

# solo CPU (si no hay GPU o el driver falla)
bash serve-bonsai.sh --cpu

# el packing más pequeño y visión
bash serve-bonsai.sh --packing ptq1 --vision

# contexto largo con KV cache de 4 bits
bash serve-bonsai.sh --kv4 --max-model-len 131072

# pasar flags directamente a llama-server
bash serve-bonsai.sh -- --reasoning-budget 8192

# ver qué haría, sin descargar nada
bash serve-bonsai.sh --dry-run
```

### Opciones

| Flag | Por defecto | Qué hace |
|---|---|---|
| `-y, --yes` | no | No pedir confirmación |
| `-p, --port N` | `8000` | Puerto HTTP |
| `-l, --max-model-len N` | `auto` | Contexto máximo. `auto` se calcula con VRAM/RAM |
| `-q, --packing P` | `pq2` | `pq2` (7,21 GB) · `ptq1` (5,95 GB) · `q2` (7,63 GB) |
| `-d, --dir RUTA` | `~/.local/share/bonsai` | Binarios y modelos |
| `--host HOST` | `127.0.0.1` | Interfaz de escucha. `0.0.0.0` para exponer |
| `--backend B` | `auto` | `cuda` · `rocm` · `vulkan` · `cpu` |
| `--cpu` | — | Atajo de `--backend cpu --gpu-layers 0` |
| `--allow-cpu` | — | Permite ir por CPU aunque haya una GPU NVIDIA sin driver |
| `--cuda-build V` | `auto` | `12.4` · `12.8` · `13.3`; por defecto según el driver |
| `--gpu-layers N` | `99` en GPU, `0` en CPU | Capas en GPU |
| `--parallel N` | `1` | Slots concurrentes; el contexto se reparte entre ellos |
| `--vision` | no | Descarga el `mmproj` Q8_0 y habilita imágenes |
| `--kv4` | no | KV cache en `q4_0` (menos VRAM, útil para contexto largo) |
| `--api-key CLAVE` | — | Exige `Authorization: Bearer` |
| `--reinstall` | — | Vuelve a descargar los binarios de llama.cpp |
| `--no-download` | — | No descarga; usa los ficheros que ya están en disco |
| `--dry-run` | — | Detecta hardware y enseña la orden final, sin descargar |
| `-h, --help` | — | Ayuda |

Variables de entorno: `LLAMA_RELEASE`, `LLAMA_REPO`, `MODEL_REPO`, `BASE_DIR`, `PORT`, `HOST`, `MAX_MODEL_LEN`, `GPU_LAYERS`, `PARALLEL`, `PACKING`, `BACKEND`, `CUDA_BUILD`, `API_KEY`, `HF_TOKEN`, `EXTRA_ARGS`, `MIN_FREE_GB`, `VISION=1`, `KV4=1`, `ALLOW_CPU=1`.

---

## Detección de hardware

El script prueba, en este orden: NVIDIA → AMD → Vulkan → CPU. Si no encuentra GPU usa CPU. Si hay una GPU NVIDIA pero el driver no responde, se detiene y te guía (o `--allow-cpu`).

| Detectado | Binario | Notas |
|---|---|---|
| `nvidia-smi` funciona | CUDA 12.4 / 12.8 / 13.3 | Elige según la versión de CUDA del driver. RTX 50 usa 12.8+ |
| `rocminfo`/`rocm-smi`/`hipcc` | ROCm 7.2 (x64) | Requiere driver ROCm instalado |
| `vulkaninfo` | Vulkan | Útil para Intel Arc, AMD sin ROCm o GPUs no soportadas |
| ninguno | CPU | Mucho más lento; usa `-l` para ajustar el contexto |

Los binarios CUDA/ROCm solo existen para x86_64. En aarch64 se cae a Vulkan o CPU.

Los builds CUDA se compilan para todas las arquitecturas que soporta ese toolkit, así que cubren tanto Ampere (`sm_86`, RTX 3090) como Blackwell (`sm_120`, RTX 5070/5080): no hay que recompilar kernels por tarjeta. Para Blackwell el script fuerza como mínimo el binario CUDA 12.8.

### Contexto automático

| VRAM detectada | Contexto |
|---|---|
| ≥ 40 GB | 131072 |
| ≥ 18 GB | 65536 |
| ≥ 14 GB | 32768 |
| ≥ 10 GB | 16384 (32768 con `ptq1`) |
| < 10 GB | 8192 |
| desconocida | 32768 |

En CPU se usa la RAM: 32k (≥48 GB), 16k (≥24 GB) u 8k.

En la práctica: una RTX 5070 de 12 GB cae en 16384 (o 32768 con `--packing ptq1`); una RTX 3090 de 24 GB, en 65536. No es una suposición del script: se calcula con la VRAM que reporte el driver.

Con `--kv4` puedes subir el contexto en GPUs justas de VRAM. Si arranca con OOM, baja `-l`.

### Packings

| Packing | Tamaño | Quién lo lee | Cuándo usarlo |
|---|---|---|---|
| `pq2` (defecto) | 7,21 GB | Fork de PrismML (el que descarga el script) | Mejor decode en H100/A100/Blackwell, y prompt processing más rápido |
| `ptq1` | 5,95 GB | Fork de PrismML | VRAM más justa; buen decode en Ada y L4 |
| `q2` | 7,63 GB | Fork y llama.cpp oficial ≥ b11556 | Si quieres usar un llama-server oficial |

---

## Probar la API

```bash
# prueba rápida (sin razonamiento, ~1k tokens de salida)
bash test-api.sh

# viendo el razonamiento del modelo
MAX_TOKENS=16384 REASONING_EFFORT=medium bash test-api.sh

# o a mano:
curl -s http://localhost:8000/v1/models | python3 -m json.tool

curl -s http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "bonsai-2-27b",
    "messages": [{"role":"user","content":"¿Qué es un peso ternario?"}],
    "max_tokens": 16384,
    "temperature": 1.0,
    "top_p": 0.95,
    "reasoning_effort": "medium"
  }' | python3 -m json.tool
```

Con el SDK de OpenAI:

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8000/v1", api_key="not-needed")
r = client.chat.completions.create(
    model="bonsai-2-27b",
    messages=[{"role": "user", "content": "Explica la rotación de Hadamard en una frase."}],
    max_tokens=16384,
    temperature=1.0,
    top_p=0.95,
    extra_body={"reasoning_effort": "medium"},
)
print(r.choices[0].message.content)
```

> **`max_tokens` alto, siempre.** El modelo razona antes de contestar y el razonamiento consume presupuesto de salida. Con `max_tokens` pequeño recibirás respuestas vacías o cortadas. Es el problema más reportado en el `KNOWN_ISSUES` del modelo.

> **El contexto debe dar cabida a prompt + respuesta + razonamiento.** Si el servidor arranca con `-l 16384`, no pidas `max_tokens: 16384` y esperes una respuesta completa. En la 5070: `--packing ptq1 -l 32768`.

Ajustes recomendados (thinking): `temperature=1.0`, `top_p=0.95`, `top_k=20`, `min_p=0.05`. El script ya los pasa como valores por defecto de `llama-server`.

---

## Dejarlo corriendo (systemd)

Ejecuta el script una vez a mano (para descargar el modelo y las dependencias) y luego crea el unit. Ajusta `User`, la ruta y la clave:

```ini
# /etc/systemd/system/bonsai.service
[Unit]
Description=Bonsai 2 (llama-server, API OpenAI)
After=network-online.target

[Service]
User=TU_USUARIO
ExecStart=/usr/bin/bash /RUTA/A/bonsai-vllm-server/serve-bonsai.sh -y --host 0.0.0.0 --api-key sk-local
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now bonsai
sudo systemctl status bonsai
```

Sin systemd, para una prueba en segundo plano: `tmux` o `nohup bash serve-bonsai.sh -y &`.

---

## Limitaciones

1. **No es vLLM.** No hay PagedAttention ni su gestor de batching. `llama-server` ofrece slots (`--parallel`), continuous batching y `/metrics`, pero no la gestión de memoria ni las métricas internas de vLLM.
2. **Un solo nodo.** Multi-GPU funciona por capas (`-ngl 99`, split por defecto). El split `row`/`tensor` no está soportado en este modelo.
3. **Contexto y VRAM.** 262k es el máximo del modelo, no lo que cabe en tu tarjeta. Usa la tabla de arriba y `--kv4` si vas justo.
4. **Visión opcional.** Sin `--vision` no se carga el `mmproj`; con él se añaden 0,63 GB y el modelo acepta imágenes.
5. **CPU es lento.** Un 27B ternario en CPU funciona, pero no es interactivo. Para CPU, considera los modelos 2B/4B/9B de PrismML.
6. **Sin speculative decoding.** El launcher no configura drafters. Puedes pasarlos con `--` si sabes lo que haces.
7. **El servidor no se queda en segundo plano.** Termina con `exec llama-server` en primer plano; usa `systemd`, `tmux` o `nohup`.
8. **Repos de terceros.** Los binarios vienen de un release fijado (`prism-b10828-a153697`). No lo cambies por un `llama-server` cualquiera si usas `pq2`/`ptq1`: solo el fork de PrismML lee esos tipos.

---

## Problemas frecuentes

| Síntoma | Causa | Solución |
|---|---|---|
| `CUDA out of memory` al arrancar | Contexto o KV demasiado grandes | `-l 16384` (o `8192`) y/o `--packing ptq1`, `--kv4` |
| `unknown type 142` / `143` al cargar | Estás usando un llama.cpp oficial con `pq2`/`ptq1` | Usa el script (fork de PrismML) o `--packing q2` |
| `no suitable device` / no ve la GPU | Driver o backend mal detectado | `bash serve-bonsai.sh --dry-run` y luego `--backend vulkan` o `--cpu` |
| Error de CUDA al arrancar | Driver más antiguo que el binario | Actualiza el driver o `--backend vulkan` |
| `error while loading shared libraries` | `LD_LIBRARY_PATH` no incluye el directorio de binarios | Usa el script; si lanzas a mano: `export LD_LIBRARY_PATH=<dir>` |
| `GLIBC_2.34 not found` | Sistema demasiado antiguo para el binario | Ubuntu 22.04+/Debian 12+, o compila desde fuente (enlace abajo) |
| Respuestas vacías o cortadas | `max_tokens` pequeño o contexto lleno | `max_tokens` 16384+, `reasoning_effort: "medium"`, `-l 32768` |
| HTTP 500 con `reasoning_effort: "high"` | La plantilla acepta `low`, `medium` y `xhigh`; `high` no existe | Usa `medium` o `xhigh` |
| Descarga muy lenta | HF sin CDN cercana | Instala `hf` (`pip install huggingface_hub`) o define `HF_TOKEN` |
| `puerto ocupado` | Otro proceso en el 8000 | `-p 9000` |
| No responde desde otra máquina | Escucha en `127.0.0.1` | `--host 0.0.0.0` y abre el puerto en el firewall |

Los binarios que fallan al arrancar se pueden sustituir por una compilación propia: [PrismML-Eng/llama.cpp](https://github.com/PrismML-Eng/llama.cpp).

---

## Verificación honesta

El script se ha validado sin GPU: detección de hardware, descarga y extracción de binarios, `--dry-run`, sintaxis, y la verificación de los tres GGUF (`Q2_0`, `PQ2_0`, `PTQ1_0`) leyendo su cabecera real desde Hugging Face (arquitectura `qwen35`, Hadamard 1024 y el tipo de tensor correcto en cada packing).

Lo que **no** se ha podido probar aquí es el arranque con GPU: esta máquina no tiene driver NVIDIA operativo. La primera ejecución en tu tarjeta es la prueba real; si algo falla, el mensaje dirá si es el driver, el backend o el contexto.

---

## Créditos y licencia

- Modelo: [PrismML](https://prismml.com) — Ternary Bonsai 2 27B, derivado de Qwen3.8-27B, licencia **Apache 2.0**.
- Runtime: [PrismML-Eng/llama.cpp](https://github.com/PrismML-Eng/llama.cpp) y [Bonsai-demo](https://github.com/PrismML-Eng/Bonsai-demo), que es la fuente de verdad para flags y releases.
- Scripts de este repo: **MIT** (ver `LICENSE`).

Este repo nació como intento de servir el modelo con vLLM. El análisis de por qué no es viable está en [Por qué no vLLM](#por-qué-no-vllm), y los scripts antiguos siguen en el historial de git.
