#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# collect_nsys_profile.sh
#
# Collect NSYS profiles from vLLM runs on OpenShift.
#
# Usage:
#   ./collect_nsys_profile.sh --version v0.20.0
#   ./collect_nsys_profile.sh --version v0.20.0 --model gpt-oss-120b --tp 4
#   ./collect_nsys_profile.sh --version v0.21.0 --tokens 1000:1000 --concurrency 100
# ==============================================================================

# ── Defaults ──────────────────────────────────────────────────────────────────

VERSION=""
MODEL="nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-FP8"
MODEL_SHORT="nemotron-120b"
TP=2
INPUT_TOKENS=1000
OUTPUT_TOKENS=1000
CONCURRENCY=100
NAMESPACE="llmd-bench"
NGC_IMAGE="nvcr.io/nvidia/pytorch:24.12-py3"
PROFILER_RANGE="100-110"
OUTPUT_DIR="${OUTPUT_DIR:-./profiles/nsys-collected}"

# ── Parse args ────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case $1 in
        --version)     VERSION="$2";      shift 2 ;;
        --model)       MODEL="$2";        shift 2 ;;
        --model-short) MODEL_SHORT="$2";  shift 2 ;;
        --tp)          TP="$2";           shift 2 ;;
        --tokens)      IFS=':' read -r INPUT_TOKENS OUTPUT_TOKENS <<< "$2"; shift 2 ;;
        --concurrency) CONCURRENCY="$2";  shift 2 ;;
        --namespace)   NAMESPACE="$2";    shift 2 ;;
        --image)       NGC_IMAGE="$2";    shift 2 ;;
        --range)       PROFILER_RANGE="$2"; shift 2 ;;
        --output-dir)  OUTPUT_DIR="$2";   shift 2 ;;
        -h|--help)
            cat << 'EOF'
Usage: collect_nsys_profile.sh --version <ver> [options]

Required:
  --version <ver>       vLLM version (e.g. v0.20.0)

Optional:
  --model <id>          HuggingFace model ID (default: nemotron-120b)
  --model-short <name>  Short name for filenames (default: nemotron-120b)
  --tp <n>              Tensor parallel size (default: 2)
  --tokens <in:out>     Input:output tokens (default: 1000:1000)
  --concurrency <n>     Benchmark concurrency (default: 100)
  --namespace <ns>      OpenShift namespace (default: llmd-bench)
  --image <img>         NGC container image (default: nvcr.io/nvidia/pytorch:24.12-py3)
  --range <start-end>   Profiler capture range (default: 100-110)
  --output-dir <dir>    Where to save .nsys-rep files
EOF
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -z "$VERSION" ]] && { echo "ERROR: --version is required"; exit 1; }

# ── Setup ─────────────────────────────────────────────────────────────────────

VER_CLEAN="${VERSION#v}"
POD_NAME="nsys-${MODEL_SHORT}-v${VER_CLEAN//\./-}-$(date +%s)"
NSYS_OUTPUT="/tmp/nsys_${MODEL_SHORT}_v${VER_CLEAN}"
mkdir -p "$OUTPUT_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "=== NSYS Profile Collection ==="
log "  Version:     vLLM ${VER_CLEAN}"
log "  Model:       ${MODEL}"
log "  TP:          ${TP}"
log "  Tokens:      ${INPUT_TOKENS} in / ${OUTPUT_TOKENS} out"
log "  Concurrency: ${CONCURRENCY}"
log "  Pod:         ${POD_NAME}"
log ""

# ── Step 1: Deploy pod with nsys wrapping vLLM ────────────────────────────────

log "Step 1: Deploying pod..."

cat << EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: nsys-profiler
spec:
  containers:
  - name: vllm
    image: ${NGC_IMAGE}
    command:
    - bash
    - -c
    - |
      set -e
      echo "Installing vLLM ${VER_CLEAN}..."
      pip install -q vllm==${VER_CLEAN}

      echo "Starting vLLM under nsys..."
      nsys profile \
        -t cuda,osrt,nvtx \
        -o ${NSYS_OUTPUT} \
        --capture-range=none \
        python3 -m vllm.entrypoints.openai.api_server \
          --model ${MODEL} \
          --tensor-parallel-size ${TP} \
          --gpu-memory-utilization 0.92 \
          --dtype auto \
          --trust-remote-code
    securityContext:
      runAsUser: 0
    ports:
    - containerPort: 8000
    resources:
      limits:
        nvidia.com/gpu: "${TP}"
      requests:
        nvidia.com/gpu: "${TP}"
    volumeMounts:
    - name: shm
      mountPath: /dev/shm
    - name: model-cache
      mountPath: /model-cache
    env:
    - name: HF_HUB_CACHE
      value: /model-cache/models
    - name: TRANSFORMERS_CACHE
      value: /model-cache/models
    - name: HF_HOME
      value: /model-cache
  volumes:
  - name: shm
    emptyDir:
      medium: Memory
      sizeLimit: 16Gi
  - name: model-cache
    persistentVolumeClaim:
      claimName: model-storage
  restartPolicy: Never
EOF

# ── Step 2: Wait for vLLM to be ready ─────────────────────────────────────────

log "Step 2: Waiting for vLLM to start..."

TIMEOUT=600
ELAPSED=0
while [[ $ELAPSED -lt $TIMEOUT ]]; do
    POD_IP=$(oc get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.podIP}' 2>/dev/null || true)

    if [[ -n "$POD_IP" ]]; then
        # Check if vLLM is responding
        if oc exec "$POD_NAME" -n "$NAMESPACE" -- curl -s "http://localhost:8000/health" &>/dev/null; then
            log "  vLLM is ready (pod IP: $POD_IP)"
            break
        fi
    fi

    sleep 10
    ELAPSED=$((ELAPSED + 10))
    echo -n "."
done
echo ""

if [[ $ELAPSED -ge $TIMEOUT ]]; then
    log "ERROR: vLLM did not start within ${TIMEOUT}s"
    oc logs "$POD_NAME" -n "$NAMESPACE" --tail=30 2>/dev/null || true
    oc delete pod "$POD_NAME" -n "$NAMESPACE" --wait=false 2>/dev/null || true
    exit 1
fi

# ── Step 3: Run benchmark to generate GPU activity ───────────────────────────

log "Step 3: Running benchmark (${INPUT_TOKENS}in/${OUTPUT_TOKENS}out, concurrency=${CONCURRENCY})..."

oc exec "$POD_NAME" -n "$NAMESPACE" -- bash -c "
    pip install -q guidellm 2>/dev/null || true
    python3 -c \"
import requests, json, time, concurrent.futures

url = 'http://localhost:8000/v1/completions'
headers = {'Content-Type': 'application/json'}

def send_request(i):
    payload = {
        'model': '${MODEL}',
        'prompt': 'Explain the theory of ' + 'quantum ' * ${INPUT_TOKENS},
        'max_tokens': ${OUTPUT_TOKENS},
    }
    try:
        r = requests.post(url, json=payload, headers=headers, timeout=300)
        return r.status_code
    except Exception as e:
        return str(e)

print(f'Sending requests with concurrency=${CONCURRENCY}...')
start = time.time()
with concurrent.futures.ThreadPoolExecutor(max_workers=${CONCURRENCY}) as pool:
    futures = [pool.submit(send_request, i) for i in range(${CONCURRENCY})]
    results = [f.result() for f in concurrent.futures.as_completed(futures)]

elapsed = time.time() - start
ok = sum(1 for r in results if r == 200)
print(f'Done: {ok}/${CONCURRENCY} succeeded in {elapsed:.1f}s')
\"
" 2>&1 | while read -r line; do log "  $line"; done

# ── Step 4: Stop vLLM to flush nsys trace ─────────────────────────────────────

log "Step 4: Stopping vLLM to flush nsys trace..."

oc exec "$POD_NAME" -n "$NAMESPACE" -- bash -c "
    # Send SIGINT to nsys (which wraps vLLM) to trigger trace flush
    kill -INT \$(pgrep -f 'nsys profile' | head -1) 2>/dev/null || true
    sleep 10
"

# ── Step 5: Pull .nsys-rep file ───────────────────────────────────────────────

log "Step 5: Extracting .nsys-rep from pod..."

# Find the output file
REMOTE_FILE=$(oc exec "$POD_NAME" -n "$NAMESPACE" -- bash -c "ls ${NSYS_OUTPUT}*.nsys-rep 2>/dev/null | head -1" || true)

if [[ -z "$REMOTE_FILE" ]]; then
    log "ERROR: No .nsys-rep file found at ${NSYS_OUTPUT}*.nsys-rep"
    log "Checking /tmp/ for any nsys output..."
    oc exec "$POD_NAME" -n "$NAMESPACE" -- ls -lh /tmp/*.nsys-rep 2>/dev/null || true
    oc delete pod "$POD_NAME" -n "$NAMESPACE" --wait=false 2>/dev/null || true
    exit 1
fi

LOCAL_FILE="${OUTPUT_DIR}/nsys_${MODEL_SHORT}_v${VER_CLEAN}_${INPUT_TOKENS}_${OUTPUT_TOKENS}_c${CONCURRENCY}.nsys-rep"
oc cp "${NAMESPACE}/${POD_NAME}:${REMOTE_FILE}" "$LOCAL_FILE"

FILE_SIZE=$(du -h "$LOCAL_FILE" | cut -f1)
log "  Saved: $LOCAL_FILE ($FILE_SIZE)"

# ── Step 6: Clean up pod ─────────────────────────────────────────────────────

log "Step 6: Cleaning up pod..."
oc delete pod "$POD_NAME" -n "$NAMESPACE" --wait=false 2>/dev/null || true

# ── Done ──────────────────────────────────────────────────────────────────────

log ""
log "=== Done ==="
log "  Profile: $LOCAL_FILE"
log "  Size:    $FILE_SIZE"
log ""
log "To analyze locally (requires nsys CLI):"
log "  nsys stats $LOCAL_FILE"
log ""
log "To upload for MCP analysis:"
log "  ./collect_and_upload_nsys.sh upload --file $LOCAL_FILE --version ${VERSION} --model ${MODEL_SHORT}"
