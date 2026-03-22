#!/usr/bin/env bash
set -euo pipefail

# === NetLinux Nightly Package Builder ===
# Orchestrates netlinux-ai-agent to build .deb packages from netlinux-ai repos.
# Runs on dev2 (147.182.205.211) at 03:00 UTC via cron.

NIGHTLY_DIR="/home/graham/nightly"
REPOS_CONF="${REPOS_CONF:-${NIGHTLY_DIR}/repos.conf}"
LAST_COMMITS_DIR="${NIGHTLY_DIR}/last-commits"
BUILD_DIR="${NIGHTLY_DIR}/build"
OUTPUT_DIR="${NIGHTLY_DIR}/output"
LOG_DIR="${NIGHTLY_DIR}/logs"
LOCKFILE="/tmp/netlinux-ai-agent-ci.lock"
GITHUB_ORG="netlinux-ai"
GITHUB_API="https://api.github.com"
PACKAGES_HOST="root@packages.netlinux.co.uk"
REPREPRO_BASE="/Sites/netlinux/packages/debian"
PACKAGES_LOG_DIR="/Sites/netlinux/packages/ci/logs"
# grahams-brain LLM server (accessed via reverse SSH tunnel)
BRAIN_SSH="ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -p 2222 graham@localhost"
LLAMA_SERVER_BIN="/home/graham/llama.cpp/build/bin/llama-server"
LLAMA_MODEL="/brain/Projects/AI/Qwen2.5-Coder-14B-Instruct-Q5_K_M.gguf"
LLAMA_PORT=8080
LLAMA_HEALTH_URL="http://localhost:8090/health"
LLAMA_START_TIMEOUT=300


# Build number file — increments each nightly run
BUILD_NUM_FILE="${NIGHTLY_DIR}/build-number"

# Report files
REPORT_DIR="${NIGHTLY_DIR}/reports"
HISTORY_FILE="${REPORT_DIR}/history.jsonl"
REPORT_HTML="${REPORT_DIR}/agentic-ci.html"
PACKAGES_HTML_DIR="/Sites/netlinux/packages"

# Timeout per repo build (60 minutes — dev2 has 8 CPUs, 15GB RAM)
BUILD_TIMEOUT=3600

# Per-repo result tracking (parallel indexed arrays)
declare -a RESULT_REPOS=()
declare -a RESULT_STATUSES=()
declare -a RESULT_COMMITS=()
declare -a RESULT_DEBS=()
declare -a RESULT_DURATIONS=()
declare -a RESULT_DETAILS=()
declare -a RESULT_LOG_URLS=()

record_result() {
    RESULT_REPOS+=("$1")
    RESULT_STATUSES+=("$2")
    RESULT_COMMITS+=("$3")
    RESULT_DEBS+=("$4")
    RESULT_DURATIONS+=("$5")
    RESULT_DETAILS+=("$6")
    RESULT_LOG_URLS+=("${7:-}")
}

# --- Helpers ---

log() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"
}

cleanup() {
    # Stop llama-server if running
    stop_llama_server 2>/dev/null || true
    rm -f "$LOCKFILE"
    log "Released lockfile"
}

acquire_lock() {
    local max_wait=600  # wait up to 10 minutes for existing lock
    local waited=0
    while [ -f "$LOCKFILE" ]; do
        local lock_pid
        lock_pid=$(cat "$LOCKFILE" 2>/dev/null || echo "")
        if [ -z "$lock_pid" ] || ! kill -0 "$lock_pid" 2>/dev/null; then
            log "Stale lockfile (PID: ${lock_pid:-empty}), removing"
            rm -f "$LOCKFILE"
            break
        fi
        if [ "$waited" -ge "$max_wait" ]; then
            log "ERROR: Lockfile held for ${max_wait}s, aborting"
            exit 1
        fi
        log "Waiting for lockfile (held by PID $lock_pid)..."
        sleep 30
        waited=$((waited + 30))
    done
    echo $$ > "$LOCKFILE"
    trap cleanup EXIT
    log "Acquired lockfile (PID $$)"
}

get_latest_commit() {
    local repo="$1"
    # Fetch the default branch first (may be main, master, netlinux, etc.)
    local branch
    branch=$(curl -sf "${GITHUB_API}/repos/${GITHUB_ORG}/${repo}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['default_branch'])" 2>/dev/null || echo "")
    [ -z "$branch" ] && { echo ""; return; }
    curl -sf "${GITHUB_API}/repos/${GITHUB_ORG}/${repo}/commits/${branch}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['sha'])" 2>/dev/null || echo ""
}

get_stored_commit() {
    local repo="$1"
    cat "${LAST_COMMITS_DIR}/${repo}.commit" 2>/dev/null || echo ""
}

store_commit() {
    local repo="$1" commit="$2"
    echo "$commit" > "${LAST_COMMITS_DIR}/${repo}.commit"
}

# Map repo name to package name for reprepro (mirrors update-repo.sh)
repo_to_pkg() {
    case "$1" in
        ssr)              echo "simplescreenrecorder" ;;
        applesmc-next)    echo "applesmc-next-dkms" ;;
        *)                echo "$1" ;;
    esac
}

publish_deb() {
    local repo="$1" deb_path="$2"
    local deb_name pkg_name
    deb_name=$(basename "$deb_path")
    pkg_name=$(repo_to_pkg "$repo")

    log "  Publishing ${deb_name} to packages.netlinux.co.uk"
    if ! scp -q "$deb_path" "${PACKAGES_HOST}:/tmp/${deb_name}" < /dev/null; then
        log "  ERROR: SCP failed for ${deb_name}"
        return 1
    fi

    ssh -qn "$PACKAGES_HOST" "
        reprepro -b ${REPREPRO_BASE} removesrc stable ${pkg_name} 2>/dev/null || true
        reprepro -b ${REPREPRO_BASE} includedeb stable /tmp/${deb_name}
        rm -f /tmp/${deb_name}
    "
    log "  Published ${deb_name} successfully"
}

build_repo() {
    local repo="$1" build_num="$2"
    local repo_build_dir="${BUILD_DIR}/${repo}"
    local repo_output_dir="${OUTPUT_DIR}/${repo}"
    local repo_log_dir="${LOG_DIR}/${repo}"
    local repo_src_dir="${repo_build_dir}/src"

    mkdir -p "$repo_build_dir" "$repo_output_dir" "$repo_log_dir"

    # Clean previous build
    rm -rf "$repo_src_dir"

    log "  Cloning ${GITHUB_ORG}/${repo}..."
    if ! git clone --depth 1 "https://github.com/${GITHUB_ORG}/${repo}.git" "$repo_src_dir" 2>&1; then
        log "  ERROR: Clone failed for ${repo}"
        return 1
    fi

    local log_file="${repo_log_dir}/latest.log"
    local mc_output="${repo_build_dir}/netlinux-ai-agent-output.txt"

    log "  Invoking netlinux-ai-agent for ${repo} (build #${build_num})..."

    local prompt
    prompt="You are a CI build agent. Your task is to build a .deb package from the
netlinux-ai/${repo} GitHub repository.

Working directory: ${repo_build_dir}
The repo has been cloned to: ${repo_src_dir}

Steps:
1. Read ${repo_src_dir}/.github/workflows/release-deb.yml to understand the build process
2. Install any missing build dependencies (use apt-get install -y)
3. Apply patches if a patches/ directory exists
4. Build the software following the workflow steps
5. Package with checkinstall (or dpkg-deb for simple packages)
6. Repack the .deb from zstd to xz if needed (for reprepro compatibility):
   mkdir -p repack && cd repack
   ar x ../PKG.deb
   for f in *.zst; do [ -f \"\$f\" ] || continue; zstd -d \"\$f\"; xz \"\${f%.zst}\"; rm \"\$f\"; done
   rm ../PKG.deb
   ar rcs ../PKG.deb debian-binary control.tar.xz data.tar.xz
7. Test the .deb installs with: dpkg -i --dry-run <package>.deb
8. Copy the final .deb to ${repo_output_dir}/

If the build fails, report what went wrong. Do not spend more than 20 minutes
on any single step. The server has 15GB RAM and 8 CPUs.

Build number to use: ${build_num}"

    # Run netlinux-ai-agent with timeout
    if timeout "$BUILD_TIMEOUT" netlinux-ai-agent --prompt "$prompt" \
        --output-file "$mc_output" > "$log_file" 2>&1; then
        log "  netlinux-ai-agent completed for ${repo}"
    else
        local exit_code=$?
        if [ "$exit_code" -eq 124 ]; then
            log "  ERROR: netlinux-ai-agent timed out for ${repo} (${BUILD_TIMEOUT}s)"
        else
            log "  ERROR: netlinux-ai-agent failed for ${repo} (exit code ${exit_code})"
        fi
        # Still check if a .deb was produced before the failure
    fi

    # Archive the log with timestamp
    cp "$log_file" "${repo_log_dir}/$(date -u '+%Y%m%d-%H%M%S').log"

    # Upload log to packages server for web access
    local log_remote_dir="${PACKAGES_LOG_DIR}/${build_num}"
    if ssh -qn "$PACKAGES_HOST" "mkdir -p ${log_remote_dir}" && \
       scp -q "$log_file" "${PACKAGES_HOST}:${log_remote_dir}/${repo}.log" < /dev/null; then
        log "  Log uploaded to /ci/logs/${build_num}/${repo}.log"
    else
        log "  WARNING: Failed to upload build log"
    fi

    # Check for .deb output
    local deb_count
    deb_count=$(find "$repo_output_dir" -maxdepth 1 -name '*.deb' -newer "$log_file" -o \
                -name '*.deb' -newer "${repo_build_dir}" 2>/dev/null | head -1)

    # Also check build dir for any .deb files netlinux-ai-agent may have left there
    if [ -z "$deb_count" ]; then
        local found_deb
        found_deb=$(find "$repo_build_dir" -maxdepth 3 -name '*.deb' -type f 2>/dev/null | head -1)
        if [ -n "$found_deb" ]; then
            cp "$found_deb" "$repo_output_dir/"
            deb_count="$found_deb"
        fi
    fi

    if [ -z "$deb_count" ]; then
        # Check output dir for any .deb at all (netlinux-ai-agent may have copied it)
        deb_count=$(find "$repo_output_dir" -maxdepth 1 -name '*.deb' -type f 2>/dev/null | head -1)
    fi

    if [ -n "$deb_count" ]; then
        log "  .deb found for ${repo}"
        return 0
    else
        log "  WARNING: No .deb produced for ${repo}"
        return 1
    fi
}


# --- LLM server management (grahams-brain via reverse tunnel) ---

start_llama_server() {
    log "Starting llama-server on grahams-brain..."

    # Check if already running
    if curl -sf --max-time 5 "$LLAMA_HEALTH_URL" >/dev/null 2>&1; then
        log "llama-server already running"
        return 0
    fi

    # Start llama-server on grahams-brain (daemonized via nohup)
    $BRAIN_SSH "nohup ${LLAMA_SERVER_BIN} \
        -m ${LLAMA_MODEL} \
        --port ${LLAMA_PORT} \
        -ngl 99 \
        -c 8192 \
        --host 127.0.0.1 \
        > /tmp/llama-server-nightly.log 2>&1 &
        echo \$!" || {
        log "ERROR: Failed to start llama-server on grahams-brain"
        return 1
    }

    # Wait for health check
    local waited=0
    while [ "$waited" -lt "$LLAMA_START_TIMEOUT" ]; do
        if curl -sf --max-time 5 "$LLAMA_HEALTH_URL" >/dev/null 2>&1; then
            log "llama-server healthy after ${waited}s"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
        log "  Waiting for llama-server... (${waited}s)"
    done

    log "ERROR: llama-server did not become healthy within ${LLAMA_START_TIMEOUT}s"
    return 1
}

stop_llama_server() {
    log "Stopping llama-server on grahams-brain..."
    $BRAIN_SSH "pkill -f llama-server 2>/dev/null || true" 2>/dev/null || true

    # Verify it stopped and GPU memory is freed
    sleep 2
    if $BRAIN_SSH "pgrep -f llama-server >/dev/null 2>&1"; then
        log "  llama-server still running, sending SIGKILL"
        $BRAIN_SSH "pkill -9 -f llama-server 2>/dev/null || true" 2>/dev/null || true
        sleep 2
    fi

    if ! $BRAIN_SSH "pgrep -f llama-server >/dev/null 2>&1"; then
        log "llama-server stopped, GPU VRAM freed"
    else
        log "WARNING: llama-server may still be running on grahams-brain"
    fi
}

# --- Main ---

RUN_START_EPOCH=$(date +%s)
log "=== Nightly package build starting ==="

# Create dirs
mkdir -p "$LAST_COMMITS_DIR" "$BUILD_DIR" "$OUTPUT_DIR" "$LOG_DIR"

# Acquire lock (waits if post-receive CI is running)
acquire_lock

# Increment build number
if [ -f "$BUILD_NUM_FILE" ]; then
    BUILD_NUM=$(( $(cat "$BUILD_NUM_FILE") + 1 ))
else
    BUILD_NUM=1
fi
echo "$BUILD_NUM" > "$BUILD_NUM_FILE"
log "Build number: ${BUILD_NUM}"

# Start LLM server on grahams-brain
if ! start_llama_server; then
    log "FATAL: Cannot start llama-server, aborting nightly build"
    exit 1
fi

# Counters
total=0
skipped=0
unchanged=0
built=0
failed=0
published=0

# Parse repos.conf and process each
while IFS= read -r line; do
    # Skip comments and blank lines
    line=$(echo "$line" | sed 's/#.*//' | xargs)
    [ -z "$line" ] && continue

    repo=$(echo "$line" | awk '{print $1}')
    action=$(echo "$line" | awk '{print $2}')
    total=$((total + 1))

    if [ "$action" = "skip" ]; then
        log "SKIP: ${repo} (marked skip in repos.conf)"
        skipped=$((skipped + 1))
        record_result "$repo" "skipped" "" "" "" "Skipped" ""
        continue
    fi

    # Check for new commits
    log "Checking ${repo}..."
    latest_commit=$(get_latest_commit "$repo")
    if [ -z "$latest_commit" ]; then
        log "  WARNING: Could not fetch latest commit for ${repo}, skipping"
        failed=$((failed + 1))
        record_result "$repo" "error" "" "" "" "Could not fetch latest commit from GitHub" ""
        continue
    fi

    stored_commit=$(get_stored_commit "$repo")
    if [ "$latest_commit" = "$stored_commit" ]; then
        log "  No new commits (${latest_commit:0:8}), skipping"
        unchanged=$((unchanged + 1))
        record_result "$repo" "unchanged" "${latest_commit:0:8}" "" "" "No new commits" ""
        continue
    fi

    prev="${stored_commit:0:8}"
    log "  New commit: ${latest_commit:0:8} (was: ${prev:-none})"

    # Build the repo (with timing)
    repo_start=$(date +%s)
    if build_repo "$repo" "$BUILD_NUM"; then
        repo_duration=$(( $(date +%s) - repo_start ))
        # Find the .deb name
        deb_name=$(find "${OUTPUT_DIR}/${repo}" -maxdepth 1 -name '*.deb' -type f -printf '%f\n' 2>/dev/null | head -1)

        # Publish only the newest .deb(s) — avoid overwriting with stale versions
        local_published=0
        while IFS= read -r deb_file; do
            if publish_deb "$repo" "$deb_file"; then
                local_published=$((local_published + 1))
            fi
        done < <(find "${OUTPUT_DIR}/${repo}" -maxdepth 1 -name '*.deb' -type f -printf '%T@ %p\n' 2>/dev/null \
                 | sort -rn | head -3 | awk '{print $2}')

        log_url="/ci/logs/${BUILD_NUM}/${repo}.log"
        if [ "$local_published" -gt 0 ]; then
            published=$((published + local_published))
            built=$((built + 1))
            store_commit "$repo" "$latest_commit"
            log "  SUCCESS: ${repo} built and published (${local_published} .deb(s))"
            record_result "$repo" "published" "${latest_commit:0:8}" "$deb_name" "$repo_duration" "Built and published" "$log_url"
        else
            log "  WARNING: ${repo} built but publish failed"
            failed=$((failed + 1))
            record_result "$repo" "failed" "${latest_commit:0:8}" "$deb_name" "$repo_duration" "Built but publish to repo failed" "$log_url"
        fi
    else
        repo_duration=$(( $(date +%s) - repo_start ))
        failed=$((failed + 1))
        log "  FAILED: ${repo}"
        log_url="/ci/logs/${BUILD_NUM}/${repo}.log"
        record_result "$repo" "failed" "${latest_commit:0:8}" "" "$repo_duration" "Build failed" "$log_url"
    fi

    # Clean up build dir to save disk space (sudo for root-owned checkinstall files)
    sudo rm -rf "${BUILD_DIR}/${repo}/src" 2>/dev/null || true

done < "$REPOS_CONF"

log "=== Nightly build complete ==="
log "Summary: total=${total} skipped=${skipped} unchanged=${unchanged} built=${built} failed=${failed} published=${published}"

# --- Run package smoke tests ---

log "=== Starting package smoke tests ==="
TEST_RESULTS_FILE="${REPORT_DIR}/test-results-${BUILD_NUM}.json"
mkdir -p "${LOG_DIR}/package-tests"
if "${NIGHTLY_DIR}/test-packages.sh" \
    --build-num "$BUILD_NUM" \
    --repos-conf "$REPOS_CONF" \
    --output "$TEST_RESULTS_FILE" \
    --log-dir "$LOG_DIR" 2>&1 | tee -a "${LOG_DIR}/package-tests/test-${BUILD_NUM}.log"; then
    log "Package tests completed"
else
    log "WARNING: Package tests encountered errors"
fi

# --- Auto-fix failing packages ---

FIX_RESULTS_FILE="${REPORT_DIR}/fix-results-${BUILD_NUM}.json"
if [ -f "$TEST_RESULTS_FILE" ]; then
    log "=== Starting auto-fix for failing packages ==="
    if "${NIGHTLY_DIR}/fix-packages.sh" \
        --build-num "$BUILD_NUM" \
        --repos-conf "$REPOS_CONF" \
        --test-results "$TEST_RESULTS_FILE" \
        --output "$FIX_RESULTS_FILE" \
        --log-dir "$LOG_DIR" 2>&1; then
        log "Auto-fix completed"
    else
        log "WARNING: Auto-fix encountered errors"
    fi
fi

# --- Generate report ---

RUN_END=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
RUN_DURATION=$(( $(date +%s) - RUN_START_EPOCH ))

mkdir -p "$REPORT_DIR"

# Append this run to history JSONL
{
    printf '{"build":%d,"date":"%s","duration":%d,"total":%d,"skipped":%d,"unchanged":%d,"built":%d,"failed":%d,"published":%d,"repos":[' \
        "$BUILD_NUM" "$RUN_END" "$RUN_DURATION" "$total" "$skipped" "$unchanged" "$built" "$failed" "$published"
    for i in "${!RESULT_REPOS[@]}"; do
        [ "$i" -gt 0 ] && printf ','
        # Escape any double quotes in detail strings
        detail=$(echo "${RESULT_DETAILS[$i]}" | sed 's/"/\\"/g')
        printf '{"name":"%s","status":"%s","commit":"%s","deb":"%s","duration":"%s","detail":"%s","log_url":"%s"}' \
            "${RESULT_REPOS[$i]}" "${RESULT_STATUSES[$i]}" "${RESULT_COMMITS[$i]}" \
            "${RESULT_DEBS[$i]}" "${RESULT_DURATIONS[$i]}" "$detail" "${RESULT_LOG_URLS[$i]}"
    done
    printf ']'
    if [ -f "$TEST_RESULTS_FILE" ]; then
        printf ',"tests":%s' "$(cat "$TEST_RESULTS_FILE")"
    fi
    if [ -f "$FIX_RESULTS_FILE" ]; then
        printf ',"fixes":%s' "$(cat "$FIX_RESULTS_FILE")"
    fi
    printf '}\n'
} >> "$HISTORY_FILE"

# Stop LLM server to free GPU VRAM
stop_llama_server

log "Generating HTML report..."

# Generate report with Python script
if python3 "${NIGHTLY_DIR}/generate-report.py" "$HISTORY_FILE" "$REPORT_HTML"; then
    log "Report generated at ${REPORT_HTML}"
else
    log "WARNING: Report generation failed"
fi

# Push report to packages server
if scp -q "$REPORT_HTML" "${PACKAGES_HOST}:${PACKAGES_HTML_DIR}/agentic-ci.html"; then
    log "Report uploaded to packages.netlinux.co.uk/agentic-ci.html"
else
    log "WARNING: Failed to upload report"
fi
