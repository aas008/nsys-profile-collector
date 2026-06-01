#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# collect_and_upload_nsys.sh
#
# Collect NSYS profiles from OpenShift pods, export to JSON, and upload to S3
# for analysis by the NYSY MCP tool.
#
# Usage:
#   # Collect from a running pod and upload:
#   ./collect_and_upload_nsys.sh collect --pod <pod-name> --version v0.20.0 --model nemotron-120b
#
#   # Export a local .nsys-rep to JSON and upload:
#   ./collect_and_upload_nsys.sh upload --file /path/to/profile.nsys-rep --version v0.20.0 --model nemotron-120b
#
#   # Export only (no upload):
#   ./collect_and_upload_nsys.sh export --file /path/to/profile.nsys-rep
#
#   # List what's currently in S3:
#   ./collect_and_upload_nsys.sh list
# ==============================================================================

# ── Configuration ─────────────────────────────────────────────────────────────

S3_BUCKET="psap-dashboard-data"
S3_PREFIX="profiles/nsys"
ACCELERATOR="H200"
NAMESPACE="${NAMESPACE:-llmd-bench}"

# AWS credentials (override via environment)
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-AKIAS2QIQH3JEJOLIMUR}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-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}"

# Local directories
LOCAL_PROFILES_DIR="${LOCAL_PROFILES_DIR:-/Users/aansharm/vllm-profiler/profiles}"
LOCAL_EXPORT_DIR="${LOCAL_EXPORT_DIR:-/Users/aansharm/vllm-profiler/profiles/nsys-json}"

# ── Helpers ───────────────────────────────────────────────────────────────────

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
err()  { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; }
die()  { err "$@"; exit 1; }

require_cmd() {
    command -v "$1" &>/dev/null || die "$1 is required but not found. $2"
}

# ── collect: pull .nsys-rep from OpenShift pod ────────────────────────────────

cmd_collect() {
    local pod="" version="" model="" rank=0

    while [[ $# -gt 0 ]]; do
        case $1 in
            --pod)       pod="$2";     shift 2 ;;
            --version)   version="$2"; shift 2 ;;
            --model)     model="$2";   shift 2 ;;
            --rank)      rank="$2";    shift 2 ;;
            --namespace) NAMESPACE="$2"; shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -z "$pod" ]]     && die "--pod is required"
    [[ -z "$version" ]] && die "--version is required (e.g. v0.20.0)"
    [[ -z "$model" ]]   && die "--model is required (e.g. nemotron-120b)"

    require_cmd oc "Install the OpenShift CLI."

    # Normalize version: strip leading 'v' for folder name
    local ver_folder="vLLM-${version#v}"

    # Find .nsys-rep file on the pod
    log "Looking for .nsys-rep files on pod $pod..."
    local remote_file
    remote_file=$(oc exec "$pod" -n "$NAMESPACE" -- bash -c 'ls /tmp/*.nsys-rep 2>/dev/null | head -1' || true)

    if [[ -z "$remote_file" ]]; then
        # Try alternate locations
        remote_file=$(oc exec "$pod" -n "$NAMESPACE" -- bash -c 'ls /tmp/nsys_*/*.nsys-rep 2>/dev/null | head -1' || true)
    fi

    [[ -z "$remote_file" ]] && die "No .nsys-rep file found on pod $pod in /tmp/"

    log "Found: $remote_file"

    # Download from pod
    local local_dir="${LOCAL_PROFILES_DIR}/nsys-collected"
    mkdir -p "$local_dir"
    local local_file="${local_dir}/${model}_${ver_folder}_rank${rank}.nsys-rep"

    log "Downloading to $local_file..."
    oc cp "${NAMESPACE}/${pod}:${remote_file}" "$local_file"
    log "Downloaded: $(du -h "$local_file" | cut -f1)"

    # Now export and upload
    cmd_upload --file "$local_file" --version "$version" --model "$model" --rank "$rank"
}

# ── export: convert .nsys-rep → JSON ─────────────────────────────────────────

do_export() {
    local nsys_file="$1"
    local json_output="$2"

    # Check if nsys CLI is available
    if command -v nsys &>/dev/null; then
        log "Exporting with nsys CLI..."
        nsys export \
            --type json \
            --output "$json_output" \
            "$nsys_file" 2>/dev/null

        if [[ -f "$json_output" ]] && [[ -s "$json_output" ]]; then
            log "Exported: $(du -h "$json_output" | cut -f1)"
            return 0
        fi
    fi

    # Fallback: try nsys stats to extract kernel summary as JSON
    if command -v nsys &>/dev/null; then
        log "Trying nsys stats export..."
        local stats_csv="/tmp/nsys_stats_$$.csv"
        nsys stats \
            --report gpukernsum \
            --format csv \
            --output "$stats_csv" \
            "$nsys_file" 2>/dev/null || true

        if [[ -f "${stats_csv}_gpukernsum.csv" ]]; then
            log "Converting kernel stats CSV to JSON..."
            python3 - "$stats_csv" "$json_output" << 'PYEOF'
import csv, json, sys

stats_file = sys.argv[1] + "_gpukernsum.csv"
json_file  = sys.argv[2]

events = []
with open(stats_file) as f:
    reader = csv.DictReader(f)
    for row in reader:
        # nsys stats columns: "Time (%)", "Total Time (ns)", "Instances",
        # "Avg (ns)", "Med (ns)", "Min (ns)", "Max (ns)", "StdDev (ns)", "Name"
        name = row.get("Name", "unknown")
        total_ns = int(row.get("Total Time (ns)", 0))
        count = int(row.get("Instances", 0))
        min_ns = int(row.get("Min (ns)", 0))
        max_ns = int(row.get("Max (ns)", 0))
        avg_ns = int(row.get("Avg (ns)", 0))

        # Generate individual events from summary stats
        # Each "event" represents the average invocation
        for _ in range(count):
            events.append({
                "name": name,
                "duration_ns": avg_ns,
                "type": "kernel",
            })

output = {"events": events, "source": "nsys_stats_gpukernsum"}
with open(json_file, "w") as f:
    json.dump(output, f, indent=2)

print(f"Converted {len(events)} kernel events from {stats_file}")
PYEOF
            # Clean up CSV
            rm -f "${stats_csv}"* 2>/dev/null
            return 0
        fi
    fi

    # nsys not available at all
    err "nsys CLI not found."
    err "Install NVIDIA Nsight Systems, or run this on a machine with nsys."
    err ""
    err "Alternatives:"
    err "  1. Run on GPU node:  ssh gpu-node 'nsys export --type json -o out.json profile.nsys-rep'"
    err "  2. Run in NGC container:  docker run --rm -v \$(pwd):/data nvcr.io/nvidia/pytorch:24.12-py3 \\"
    err "       nsys export --type json -o /data/out.json /data/profile.nsys-rep"
    err "  3. Upload the .nsys-rep directly (analysis tool will attempt export at runtime)"
    return 1
}

cmd_export() {
    local file=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --file) file="$2"; shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -z "$file" ]] && die "--file is required"
    [[ -f "$file" ]] || die "File not found: $file"

    mkdir -p "$LOCAL_EXPORT_DIR"
    local basename
    basename=$(basename "$file" .nsys-rep)
    local json_output="${LOCAL_EXPORT_DIR}/${basename}.json"

    do_export "$file" "$json_output"
    log "JSON output: $json_output"
}

# ── upload: export + push to S3 ──────────────────────────────────────────────

cmd_upload() {
    local file="" version="" model="" rank=0 skip_export=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --file)        file="$2";    shift 2 ;;
            --version)     version="$2"; shift 2 ;;
            --model)       model="$2";   shift 2 ;;
            --rank)        rank="$2";    shift 2 ;;
            --accelerator) ACCELERATOR="$2"; shift 2 ;;
            --skip-export) skip_export=true; shift ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -z "$file" ]]    && die "--file is required"
    [[ -f "$file" ]]    || die "File not found: $file"
    [[ -z "$version" ]] && die "--version is required (e.g. v0.20.0)"
    [[ -z "$model" ]]   && die "--model is required (e.g. nemotron-120b)"

    require_cmd aws "Install the AWS CLI."

    # Normalize version
    local ver_folder="vLLM-${version#v}"
    local s3_dir="s3://${S3_BUCKET}/${S3_PREFIX}/${ACCELERATOR}/${model}/${ver_folder}"

    # Step 1: Export to JSON if possible
    mkdir -p "$LOCAL_EXPORT_DIR"
    local basename
    basename=$(basename "$file" .nsys-rep)
    local json_file="${LOCAL_EXPORT_DIR}/${basename}.json"
    local uploaded_json=false

    if [[ "$skip_export" != "true" ]] && [[ "$file" == *.nsys-rep ]]; then
        log "Step 1: Exporting .nsys-rep to JSON..."
        if do_export "$file" "$json_file"; then
            uploaded_json=true
        else
            log "JSON export failed. Will upload binary .nsys-rep only."
        fi
    elif [[ "$file" == *.json ]]; then
        json_file="$file"
        uploaded_json=true
    fi

    # Step 2: Upload to S3
    log "Step 2: Uploading to S3..."
    log "  Destination: $s3_dir/"

    if [[ "$uploaded_json" == "true" ]] && [[ -f "$json_file" ]]; then
        local json_basename
        json_basename=$(basename "$json_file")
        aws s3 cp "$json_file" "${s3_dir}/${json_basename}"
        log "  Uploaded JSON: ${json_basename} ($(du -h "$json_file" | cut -f1))"
    fi

    # Always upload the binary .nsys-rep as backup
    if [[ "$file" == *.nsys-rep ]]; then
        local nsys_basename
        nsys_basename=$(basename "$file")
        aws s3 cp "$file" "${s3_dir}/${nsys_basename}"
        log "  Uploaded binary: ${nsys_basename} ($(du -h "$file" | cut -f1))"
    fi

    log ""
    log "Upload complete!"
    log "  S3 location: $s3_dir/"
    log "  MCP tool:    analyze_nysy_profile(version='${version}', model='${model}')"
}

# ── upload-all: batch upload from local profiles directory ────────────────────

cmd_upload_all() {
    local model="" dry_run=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --model)   model="$2"; shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    log "Scanning for .nsys-rep files in ${LOCAL_PROFILES_DIR}..."

    local found=0
    while IFS= read -r -d '' nsys_file; do
        local basename
        basename=$(basename "$nsys_file")

        # Try to extract version from filename patterns:
        #   nsys_profile_nemotron_v0.20.0_1k1k_c100_ngc.nsys-rep
        #   vllm_v0.16.0_nsys.nsys-rep
        local version=""
        if [[ "$basename" =~ v([0-9]+\.[0-9]+\.[0-9]+) ]]; then
            version="${BASH_REMATCH[1]}"
        fi

        # Try to extract model from filename or parent directory
        local detected_model="${model}"
        if [[ -z "$detected_model" ]]; then
            if [[ "$basename" == *nemotron* ]]; then
                detected_model="nemotron-120b"
            elif [[ "$basename" == *gpt* ]]; then
                detected_model="gpt-oss-120b"
            elif [[ "$basename" == *deepseek* ]]; then
                detected_model="deepseek-r1"
            else
                detected_model="unknown"
            fi
        fi

        if [[ -z "$version" ]]; then
            log "  SKIP: $basename (cannot detect version)"
            continue
        fi

        found=$((found + 1))
        log "  Found: $basename → model=$detected_model version=v$version"

        if [[ "$dry_run" == "false" ]]; then
            cmd_upload --file "$nsys_file" --version "v${version}" --model "$detected_model"
            echo ""
        fi

    done < <(find "$LOCAL_PROFILES_DIR" -name "*.nsys-rep" -print0 2>/dev/null)

    log ""
    log "Found $found .nsys-rep files."
    if [[ "$dry_run" == "true" ]]; then
        log "(Dry run -- nothing uploaded. Remove --dry-run to upload.)"
    fi
}

# ── list: show what's in S3 ──────────────────────────────────────────────────

cmd_list() {
    require_cmd aws "Install the AWS CLI."

    log "NYSY profiles in s3://${S3_BUCKET}/${S3_PREFIX}/:"
    echo ""

    aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" --recursive \
        | grep -v '.placeholder' \
        | while read -r line; do
            echo "  $line"
        done

    echo ""
}

# ── Main dispatch ─────────────────────────────────────────────────────────────

usage() {
    cat << 'EOF'
Usage: collect_and_upload_nsys.sh <command> [options]

Commands:
  collect     Pull .nsys-rep from an OpenShift pod, export to JSON, upload to S3
  upload      Export a local .nsys-rep to JSON and upload to S3
  upload-all  Batch upload all .nsys-rep files found in profiles directory
  export      Export .nsys-rep to JSON locally (no upload)
  list        List NYSY profiles currently in S3

Options for 'collect':
  --pod <name>         Pod name in OpenShift (required)
  --version <ver>      vLLM version, e.g. v0.20.0 (required)
  --model <name>       Model name, e.g. nemotron-120b (required)
  --rank <n>           GPU rank (default: 0)
  --namespace <ns>     OpenShift namespace (default: llmd-bench)

Options for 'upload':
  --file <path>        Path to .nsys-rep or .json file (required)
  --version <ver>      vLLM version (required)
  --model <name>       Model name (required)
  --rank <n>           GPU rank (default: 0)
  --accelerator <gpu>  GPU type (default: H200)
  --skip-export        Upload binary only, skip JSON export

Options for 'upload-all':
  --model <name>       Override model name for all files
  --dry-run            Show what would be uploaded without uploading

Options for 'export':
  --file <path>        Path to .nsys-rep file (required)

Examples:
  # Collect from a running pod:
  ./collect_and_upload_nsys.sh collect \
    --pod profile-nemotron-vllm-0.20 \
    --version v0.20.0 \
    --model nemotron-120b

  # Upload an existing .nsys-rep file:
  ./collect_and_upload_nsys.sh upload \
    --file profiles/nemotron-pytorch-guidellm/nsys_profile_nemotron_v0.20.0_1k1k_c100_ngc.nsys-rep \
    --version v0.20.0 \
    --model nemotron-120b

  # Batch upload all local profiles:
  ./collect_and_upload_nsys.sh upload-all --dry-run

  # List what's in S3:
  ./collect_and_upload_nsys.sh list
EOF
}

main() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    local cmd="$1"; shift

    case "$cmd" in
        collect)    cmd_collect "$@" ;;
        upload)     cmd_upload "$@" ;;
        upload-all) cmd_upload_all "$@" ;;
        export)     cmd_export "$@" ;;
        list)       cmd_list "$@" ;;
        -h|--help)  usage ;;
        *)          die "Unknown command: $cmd. Run with --help for usage." ;;
    esac
}

main "$@"
