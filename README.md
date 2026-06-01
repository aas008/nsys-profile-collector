# nsys-profile-collector

Collect NVIDIA Nsight Systems (NSYS) profiles from vLLM runs on OpenShift.

## Scripts

### `collect_nsys_profile.sh`

Deploys a pod with `nsys profile` wrapping vLLM, runs a benchmark, and pulls the `.nsys-rep` file locally.

```bash
# Basic usage:
./collect_nsys_profile.sh --version v0.20.0

# With options:
./collect_nsys_profile.sh --version v0.21.0 \
  --model openai/gpt-oss-120b \
  --model-short gpt-oss-120b \
  --tp 4 \
  --tokens 1000:1000 \
  --concurrency 100
```

**Steps:**
1. Deploy NGC PyTorch pod with `nsys profile` wrapping vLLM
2. Wait for vLLM health check
3. Run benchmark to generate GPU activity
4. SIGINT to flush nsys trace
5. `oc cp` the `.nsys-rep` to local machine
6. Delete the pod

**Options:**

| Flag | Default | Description |
|------|---------|-------------|
| `--version` | (required) | vLLM version, e.g. `v0.20.0` |
| `--model` | nemotron-120b | HuggingFace model ID |
| `--model-short` | nemotron-120b | Short name for output filename |
| `--tp` | 2 | Tensor parallel size |
| `--tokens` | 1000:1000 | Input:output token counts |
| `--concurrency` | 100 | Benchmark concurrency |
| `--namespace` | llmd-bench | OpenShift namespace |
| `--image` | nvcr.io/nvidia/pytorch:24.12-py3 | NGC container image |
| `--range` | 100-110 | Profiler capture range |
| `--output-dir` | profiles/nsys-collected | Local output directory |

### `collect_and_upload_nsys.sh`

Export `.nsys-rep` to JSON and upload to S3 for analysis by the PSAP MCP server.

```bash
# Upload a collected profile:
./collect_and_upload_nsys.sh upload \
  --file profiles/nsys_nemotron-120b_v0.20.0_1000_1000_c100.nsys-rep \
  --version v0.20.0 \
  --model nemotron-120b

# List what's in S3:
./collect_and_upload_nsys.sh list

# Batch upload all local profiles (dry run first):
./collect_and_upload_nsys.sh upload-all --dry-run
```

## Prerequisites

- `oc` CLI (OpenShift) with cluster access
- OpenShift cluster with NVIDIA GPUs
- Model PVC (`model-storage`) mounted in the namespace
- `aws` CLI (for upload script only)
