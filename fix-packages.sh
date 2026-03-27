#!/usr/bin/env bash
set -euo pipefail

# === Auto-Fix Pipeline for Failing Packages ===
# Reads Bookworm smoke test results, invokes netlinux-ai-agent to fix failures,
# republishes fixed .debs, and re-tests in a fresh Bookworm VM.
# Called by nightly-packages.sh after test-packages.sh completes.
#
# Usage: fix-packages.sh --build-num NUM --repos-conf FILE --test-results FILE --output FILE --log-dir DIR

NIGHTLY_DIR="/home/graham/nightly"
FIX_SKIP_CONF="${NIGHTLY_DIR}/fix-skip.conf"
SMOKE_TESTS_CONF="${NIGHTLY_DIR}/smoke-tests.conf"
VM_IMAGES_DIR="${NIGHTLY_DIR}/vm-images"
BOOKWORM_BASE="${VM_IMAGES_DIR}/bookworm-base.qcow2"
BOOKWORM_SEED="${VM_IMAGES_DIR}/bookworm-seed.iso"
BUILD_DIR="${NIGHTLY_DIR}/build"
OUTPUT_DIR="${NIGHTLY_DIR}/output"
GITHUB_ORG="netlinux-ai"
PACKAGES_HOST="root@packages.netlinux.co.uk"
REPREPRO_BASE="/Sites/netlinux/packages/debian"
PACKAGES_LOG_DIR="/Sites/netlinux/packages/ci/logs"

# SSH settings
SSH_BASE_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"
BOOT_TIMEOUT=180
POLL_INTERVAL=5

# VM settings (same port as initial test — safe because that VM is shut down)
BOOKWORM_SSH_PORT=2224
BOOKWORM_USER="testuser"
BOOKWORM_PASS="testpass"

# Timeouts
FIX_TIMEOUT=1200       # 20 min per package fix attempt
FIX_PHASE_TIMEOUT=7200 # 2 hour global fix phase timeout
# Shared library fix mapping (shlib -> debian package for Bookworm)
SHLIB_FIXES_CONF="${NIGHTLY_DIR}/shlib-fixes.conf"

# LLM API for single-shot consultations (not agentic)
LLAMA_API_URL="${LLAMA_API_URL:-http://localhost:8090/v1/chat/completions}"
LLAMA_HEALTH_URL="${LLAMA_HEALTH_URL:-http://localhost:8090/health}"


# VM PID for cleanup
QEMU_PID_RETEST=""
BOOKWORM_OVERLAY=""

# --- Argument parsing ---

BUILD_NUM=""
REPOS_CONF=""
TEST_RESULTS=""
OUTPUT_FILE=""
LOG_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-num)     BUILD_NUM="$2"; shift 2 ;;
        --repos-conf)    REPOS_CONF="$2"; shift 2 ;;
        --test-results)  TEST_RESULTS="$2"; shift 2 ;;
        --output)        OUTPUT_FILE="$2"; shift 2 ;;
        --log-dir)       LOG_DIR="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

[ -z "$BUILD_NUM" ]    && { echo "ERROR: --build-num required"; exit 1; }
[ -z "$REPOS_CONF" ]   && { echo "ERROR: --repos-conf required"; exit 1; }
[ -z "$TEST_RESULTS" ] && { echo "ERROR: --test-results required"; exit 1; }
[ -z "$OUTPUT_FILE" ]  && { echo "ERROR: --output required"; exit 1; }
[ -z "$LOG_DIR" ]      && { echo "ERROR: --log-dir required"; exit 1; }

FIX_LOG_DIR="${LOG_DIR}/package-tests"
mkdir -p "$FIX_LOG_DIR"
FIX_LOG="${FIX_LOG_DIR}/fix-${BUILD_NUM}.log"

# --- Helpers ---

log() {
    local msg="[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"
    echo "$msg" >&2
    echo "$msg" >> "$FIX_LOG"
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/\\t}"
    echo -n "$s"
}

repo_to_pkg() {
    case "$1" in
        ssr)              echo "simplescreenrecorder" ;;
        applesmc-next)    echo "applesmc-next-dkms" ;;
        chromium-browser) echo "chromium-browser-stable" ;;
        *)                echo "$1" ;;
    esac
}

ssh_cmd() {
    local port="$1" user="$2" pass="$3"
    shift 3
    sshpass -p "$pass" ssh $SSH_BASE_OPTS -p "$port" "${user}@localhost" "$@" 2>/dev/null
}

wait_for_ssh() {
    local port="$1" user="$2" pass="$3" label="$4"
    local elapsed=0
    log "Waiting up to ${BOOT_TIMEOUT}s for SSH on ${label} (port ${port})..."
    while [[ $elapsed -lt $BOOT_TIMEOUT ]]; do
        if ssh_cmd "$port" "$user" "$pass" "echo SSH_OK" 2>/dev/null | grep -q SSH_OK; then
            log "  SSH connected to ${label} after ${elapsed}s"
            return 0
        fi
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done
    log "  ERROR: SSH timeout on ${label} after ${BOOT_TIMEOUT}s"
    return 1
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

cleanup() {
    if [[ -n "$QEMU_PID_RETEST" ]] && kill -0 "$QEMU_PID_RETEST" 2>/dev/null; then
        log "Cleaning up re-test VM (PID $QEMU_PID_RETEST)..."
        kill "$QEMU_PID_RETEST" 2>/dev/null || true
        local kcount=0
        while kill -0 "$QEMU_PID_RETEST" 2>/dev/null && [ $kcount -lt 10 ]; do
            sleep 1
            kcount=$((kcount + 1))
        done
    fi
    rm -f /tmp/smoke-test-bookworm-fix.pid
    if [[ -n "$BOOKWORM_OVERLAY" ]] && [[ -f "$BOOKWORM_OVERLAY" ]]; then
        rm -f "$BOOKWORM_OVERLAY"
    fi
}
trap cleanup EXIT

# --- Read smoke test commands ---

declare -A SMOKE_CMDS=()
while IFS= read -r line; do
    line=$(echo "$line" | sed 's/#.*//')
    [ -z "$(echo "$line" | xargs)" ] && continue
    pkg_name=$(echo "$line" | awk '{print $1}')
    smoke_cmd=$(echo "$line" | sed 's/^[^ \t]*//' | sed 's/^[ \t]*//')
    [ -n "$pkg_name" ] && [ -n "$smoke_cmd" ] && SMOKE_CMDS["$pkg_name"]="$smoke_cmd"
done < "$SMOKE_TESTS_CONF"

# --- Load fix-skip list ---

declare -A FIX_SKIP=()
if [ -f "$FIX_SKIP_CONF" ]; then
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/#.*//' | xargs)
        [ -z "$line" ] && continue
        pkg_name=$(echo "$line" | awk '{print $1}')
        reason=$(echo "$line" | awk '{print $2}')
        [ -n "$pkg_name" ] && FIX_SKIP["$pkg_name"]="${reason:-unknown}"
    done < "$FIX_SKIP_CONF"
    log "Loaded ${#FIX_SKIP[@]} entries from fix-skip.conf"

load_shlib_fixes
fi

# --- Extract Bookworm failures from test results ---

extract_bookworm_failures() {
    python3 -c "
import json, sys
data = json.load(open('$TEST_RESULTS'))
for env in data.get('environments', []):
    if 'bookworm' in env.get('name', '').lower():
        for pkg in env.get('packages', []):
            status = pkg.get('status', '')
            if status in ('install_failed', 'smoke_failed'):
                name = pkg.get('name', '')
                detail = pkg.get('detail', '')
                # Output: name|status|detail
                print(f'{name}|{status}|{detail}')
        break
"
}


# === Failure categorisation (Option A) ===

categorise_failure() {
    local detail="$1"

    if echo "$detail" | grep -qiE "GLIBC_[0-9.]+ .* not found|version.*GLIBC.*not found"; then
        echo "glibc_mismatch"
    elif echo "$detail" | grep -qiE "error while loading shared libraries.*cannot open shared object|\.so\.[0-9]+.*No such file"; then
        echo "missing_shlib"
    elif echo "$detail" | grep -qiE "Depends:.*not installable|dependency.*not satisf"; then
        echo "missing_dep"
    else
        echo "unknown"
    fi
}

# Extract the missing shared library name from the failure detail
extract_missing_shlib() {
    local detail="$1"
    echo "$detail" | grep -oP '[a-zA-Z0-9_+-]+\.so\.[0-9]+' | head -1
}

# === Shared library fix mapping ===

declare -A SHLIB_MAP=()

load_shlib_fixes() {
    if [ ! -f "$SHLIB_FIXES_CONF" ]; then
        log "WARNING: ${SHLIB_FIXES_CONF} not found"
        return
    fi
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/#.*//' | xargs)
        [ -z "$line" ] && continue
        local shlib pkg
        shlib=$(echo "$line" | awk '{print $1}')
        pkg=$(echo "$line" | awk '{print $2}')
        [ -n "$shlib" ] && [ -n "$pkg" ] && SHLIB_MAP["$shlib"]="$pkg"
    done < "$SHLIB_FIXES_CONF"
    log "Loaded ${#SHLIB_MAP[@]} shared library mappings"
}

# === LLM single-shot helper (no agentic loop, no tools) ===

llm_single_shot() {
    local prompt="$1"

    # Skip if LLM isn't available
    if ! curl -sf --max-time 3 "$LLAMA_HEALTH_URL" >/dev/null 2>&1; then
        echo ""
        return 1
    fi

    local payload
    payload=$(python3 -c "
import json, sys
print(json.dumps({
    'model': 'local',
    'messages': [
        {'role': 'system', 'content': 'You are a Debian packaging expert. Answer concisely.'},
        {'role': 'user', 'content': sys.stdin.read()}
    ],
    'max_tokens': 1024,
    'temperature': 0.3
}))
" <<< "$prompt")

    local response
    response=$(curl -sf --max-time 60 \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$LLAMA_API_URL" 2>/dev/null) || { echo ""; return 1; }

    python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    print(data['choices'][0]['message']['content'].strip())
except:
    pass
" "$response" 2>/dev/null
}


# === Web lookups — script fetches context, LLM reasons ===

# Search packages.debian.org for which Bookworm package provides a file
search_debian_package() {
    local filename="$1"
    curl -sf --max-time 15 \
        "https://packages.debian.org/search?searchon=contents&keywords=${filename}&mode=filename&suite=bookworm&arch=amd64" \
        2>/dev/null | python3 -c "
import sys, re
html = sys.stdin.read()
pkgs = re.findall(r'bookworm/([a-zA-Z0-9._+-]+)', html)
seen = set()
for p in pkgs:
    if p not in ('amd64','i386','all','source') and p not in seen:
        seen.add(p)
        print(p)
" 2>/dev/null | head -3
}

# Search the web for an error message and return relevant snippets
web_search_error() {
    local query="$1"
    local encoded
    encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$query")
    curl -sf --max-time 15 \
        -H "User-Agent: Mozilla/5.0" \
        "https://lite.duckduckgo.com/lite/?q=${encoded}" \
        2>/dev/null | python3 -c "
import sys, re, html as h
text = sys.stdin.read()
snippets = re.findall(r'class=.result-snippet.>(.*?)</td>', text, re.DOTALL)
links = re.findall(r'class=.result-link.[^>]*>(.*?)</a>', text, re.DOTALL)
out = []
for i, s in enumerate(snippets[:5]):
    clean = re.sub(r'<[^>]+>', '', s).strip()
    clean = h.unescape(clean)
    link = links[i].strip() if i < len(links) else ''
    link = re.sub(r'<[^>]+>', '', link).strip()
    if clean:
        out.append(f'{link}: {clean}')
result = chr(10).join(out)
if len(result) > 2000:
    result = result[:2000] + '...'
print(result)
" 2>/dev/null
}

# Search for a Debian packaging solution
search_packaging_fix() {
    local pkg="$1" error="$2"
    web_search_error "debian bookworm ${pkg} ${error} fix packaging"
}

# === Workflow parser — extracts build steps from release-deb.yml ===

parse_workflow_steps() {
    local workflow_file="$1"
    python3 -c "
import yaml, sys, re

with open(sys.argv[1]) as f:
    wf = yaml.safe_load(f)

for job in wf.get('jobs', {}).values():
    for step in job.get('steps', []):
        run_cmd = step.get('run', '')
        if not run_cmd:
            continue
        name = step.get('name', 'unnamed')
        # Strip GitHub Actions template syntax
        run_cmd = re.sub(r'\\\$\\\{\\\{.*?\\\}\\\}', '', run_cmd)
        print(f'### {name}')
        print(run_cmd.strip())
        print('---')
" "$workflow_file" 2>/dev/null
}

# Extract the --requires value from a workflow file
extract_requires() {
    local workflow_file="$1"
    python3 -c "
import re, sys
with open(sys.argv[1]) as f:
    content = f.read()
# Find --requires=... or --requires \"...\" across possibly multiple lines
# The requires can span multiple lines with backslash continuations
m = re.search(r'--requires=[\"'\''](.*?)[\"'\'']|--requires=([^\s\\\\]+(?:\\\\\n[^\s]*)*)', content, re.DOTALL)
if m:
    req = m.group(1) or m.group(2)
    # Clean up line continuations and extra whitespace
    req = re.sub(r'\\\\\n\s*', '', req)
    req = req.strip().strip('\"').strip(\"'\")
    print(req)
" "$workflow_file" 2>/dev/null
}

# Extract the checkinstall command from a workflow file
extract_checkinstall_cmd() {
    local workflow_file="$1"
    python3 -c "
import yaml, sys, re

with open(sys.argv[1]) as f:
    wf = yaml.safe_load(f)

for job in wf.get('jobs', {}).values():
    for step in job.get('steps', []):
        run_cmd = step.get('run', '')
        if 'checkinstall' in run_cmd:
            print(run_cmd.strip())
            sys.exit(0)
" "$workflow_file" 2>/dev/null
}

# Extract install dependencies step from a workflow file
extract_build_deps() {
    local workflow_file="$1"
    python3 -c "
import yaml, sys

with open(sys.argv[1]) as f:
    wf = yaml.safe_load(f)

for job in wf.get('jobs', {}).values():
    for step in job.get('steps', []):
        name = step.get('name', '').lower()
        run_cmd = step.get('run', '')
        if ('depend' in name or 'install' in name.lower()) and 'apt' in run_cmd:
            print(run_cmd.strip())
            break
" "$workflow_file" 2>/dev/null
}

# === Fix: missing shared library (repack existing .deb with added dep) ===

fix_missing_shlib() {
    local repo="$1" detail="$2"
    local repo_output_dir="${OUTPUT_DIR}/${repo}"
    local fix_build_dir="${BUILD_DIR}/${repo}-fix"
    local fix_log_file="${FIX_LOG_DIR}/${repo}-fix.log"

    FIX_DEB_PATH=""
    : > "$fix_log_file"

    local missing_shlib
    missing_shlib=$(extract_missing_shlib "$detail")
    log "  Missing shared library: ${missing_shlib}" | tee -a "$fix_log_file"

    # Look up the Debian package for this shared lib
    local fix_pkg="${SHLIB_MAP[$missing_shlib]:-}"
    if [ -z "$fix_pkg" ]; then
        # Step 1: search packages.debian.org (script does the web lookup)
        log "  Not in shlib-fixes.conf, searching packages.debian.org..." | tee -a "$fix_log_file"
        fix_pkg=$(search_debian_package "$missing_shlib" | head -1)
        if [ -n "$fix_pkg" ]; then
            log "  packages.debian.org found: ${fix_pkg}" | tee -a "$fix_log_file"
        fi
    fi

    if [ -z "$fix_pkg" ]; then
        # Step 2: web search + LLM (script fetches context, LLM reasons)
        log "  Searching web for package providing ${missing_shlib}..." | tee -a "$fix_log_file"
        local web_results
        web_results=$(web_search_error "debian bookworm package provides ${missing_shlib}")
        local llm_prompt
        if [ -n "$web_results" ]; then
            llm_prompt="I need the Debian Bookworm apt package that provides '${missing_shlib}'.

Web search results:
${web_results}

Based on these results, what is the exact package name? Answer with ONLY the package name."
        else
            llm_prompt="On Debian Bookworm (12), which apt package provides '${missing_shlib}'? Answer with ONLY the package name."
        fi
        local llm_answer
        llm_answer=$(llm_single_shot "$llm_prompt") | tee -a "$fix_log_file"
        local llm_answer

    fi

    if [ -z "$fix_pkg" ]; then
        log "  ERROR: Could not determine package for ${missing_shlib}" | tee -a "$fix_log_file"
        return 1
    fi

    # Find existing .deb
    local existing_deb
    existing_deb=$(find "$repo_output_dir" -maxdepth 1 -name '*.deb' -type f 2>/dev/null | sort -t_ -k2 -V | tail -1)
    if [ -z "$existing_deb" ]; then
        log "  ERROR: No existing .deb found in ${repo_output_dir}" | tee -a "$fix_log_file"
        return 1
    fi
    log "  Repacking: $(basename "$existing_deb")" | tee -a "$fix_log_file"
    log "  Adding dependency: ${fix_pkg}" | tee -a "$fix_log_file"

    # Repack the .deb with the missing dependency added
    local repack_dir="${fix_build_dir}/repack-shlib"
    rm -rf "$repack_dir"
    mkdir -p "$repack_dir"

    cd "$repack_dir"
    ar x "$existing_deb" >> "$fix_log_file" 2>&1

    # Extract control archive
    local control_archive=""
    if [ -f control.tar.xz ]; then
        control_archive="control.tar.xz"
        xz -d control.tar.xz
    elif [ -f control.tar.gz ]; then
        control_archive="control.tar.gz"
        gzip -d control.tar.gz
    elif [ -f control.tar.zst ]; then
        control_archive="control.tar.zst"
        zstd -d control.tar.zst
    fi

    if [ ! -f control.tar ]; then
        log "  ERROR: Could not extract control archive" | tee -a "$fix_log_file"
        return 1
    fi

    mkdir control_dir
    tar xf control.tar -C control_dir

    # Add the missing dependency to the Depends line
    local control_file="control_dir/control"
    if [ ! -f "$control_file" ]; then
        log "  ERROR: No control file found" | tee -a "$fix_log_file"
        return 1
    fi

    log "  Original Depends:" | tee -a "$fix_log_file"
    grep "^Depends:" "$control_file" | tee -a "$fix_log_file" || true

    python3 -c "
import sys

pkg = sys.argv[1]
control_file = sys.argv[2]

with open(control_file) as f:
    lines = f.readlines()

new_lines = []
found_depends = False
for line in lines:
    if line.startswith('Depends:'):
        found_depends = True
        deps = line.strip()
        if pkg not in deps:
            deps = deps.rstrip() + ', ' + pkg
        new_lines.append(deps + '\n')
    else:
        new_lines.append(line)

if not found_depends:
    # Insert Depends after Package line
    final = []
    for line in new_lines:
        final.append(line)
        if line.startswith('Package:'):
            final.append(f'Depends: {pkg}\n')
    new_lines = final

with open(control_file, 'w') as f:
    f.writelines(new_lines)
" "$fix_pkg" "$control_file"

    log "  Updated Depends:" | tee -a "$fix_log_file"
    grep "^Depends:" "$control_file" | tee -a "$fix_log_file" || true

    # Repack control archive
    cd control_dir
    tar cf ../control.tar ./*
    cd ..
    xz control.tar
    rm -rf control_dir

    # Also ensure data archive is xz (repack zstd if present)
    if [ -f data.tar.zst ]; then
        zstd -d data.tar.zst
        xz data.tar
        rm -f data.tar.zst
    elif [ -f data.tar.gz ]; then
        gzip -d data.tar.gz
        xz data.tar
    fi

    # Rebuild .deb
    local new_deb_name
    new_deb_name=$(basename "$existing_deb")
    ar rcs "$new_deb_name" debian-binary control.tar.xz data.tar.xz >> "$fix_log_file" 2>&1

    if [ ! -f "$new_deb_name" ]; then
        log "  ERROR: Failed to create repacked .deb" | tee -a "$fix_log_file"
        return 1
    fi

    # Verify the new .deb
    log "  Verifying repacked .deb..." | tee -a "$fix_log_file"
    dpkg-deb -I "$new_deb_name" >> "$fix_log_file" 2>&1 || true

    # Copy to output
    cp "$new_deb_name" "$repo_output_dir/"
    FIX_DEB_PATH="${repo_output_dir}/${new_deb_name}"
    log "  Fixed .deb: ${new_deb_name}" | tee -a "$fix_log_file"

    # Upload fix log
    local log_remote_dir="${PACKAGES_LOG_DIR}/${BUILD_NUM}"
    ssh -qn "$PACKAGES_HOST" "mkdir -p ${log_remote_dir}" 2>/dev/null
    scp -q "$fix_log_file" "${PACKAGES_HOST}:${log_remote_dir}/${repo}-fix.log" < /dev/null 2>/dev/null

    # Cleanup
    rm -rf "$repack_dir"

    return 0
}

# === Fix: GLIBC mismatch ===

fix_glibc_mismatch() {
    local repo="$1" detail="$2"
    local glibc_version
    glibc_version=$(echo "$detail" | grep -oP "GLIBC_[0-9.]+" | head -1)
    log "  ${repo}: GLIBC mismatch (needs ${glibc_version}, Bookworm has 2.36)"
    log "  Auto-skipping — needs in-VM Bookworm rebuild (not yet implemented)"
    return 1
}

# === Fix: unknown failure — ask LLM for diagnosis ===

fix_unknown() {
    local repo="$1" detail="$2"
    local fix_log_file="${FIX_LOG_DIR}/${repo}-fix.log"

    log "  ${repo}: Unknown failure type"

    # Search the web for this error before consulting LLM
    log "  Searching web for: ${repo} error..." | tee -a "$fix_log_file"
    local web_results
    web_results=$(search_packaging_fix "$repo" "${detail:0:100}")

    if [ -n "$web_results" ]; then
        log "  Found web results (${#web_results} chars)" | tee -a "$fix_log_file"
        echo "=== Web search results ===" >> "$fix_log_file"
        echo "$web_results" >> "$fix_log_file"
    fi

    # Ask LLM with web context included
    log "  Consulting LLM with web context..." | tee -a "$fix_log_file"
    local llm_prompt="A Debian package '${repo}' on Debian Bookworm failed its smoke test.

Error output:
${detail}"

    if [ -n "$web_results" ]; then
        llm_prompt+="

Web search results about this error:
${web_results}"
    fi

    llm_prompt+="

Based on the error and any search results, what is the most likely cause and how would you fix the packaging? Be specific about which files to change and what commands to run."

    local llm_answer
    llm_answer=$(llm_single_shot "$llm_prompt")

    if [ -n "$llm_answer" ]; then
        log "  LLM diagnosis: ${llm_answer}"
        echo "$llm_answer" >> "$fix_log_file"
    else
        log "  LLM unavailable for diagnosis"
    fi

    # Upload diagnosis log
    local log_remote_dir="${PACKAGES_LOG_DIR}/${BUILD_NUM}"
    ssh -qn "$PACKAGES_HOST" "mkdir -p ${log_remote_dir}" 2>/dev/null
    scp -q "$fix_log_file" "${PACKAGES_HOST}:${log_remote_dir}/${repo}-fix.log" < /dev/null 2>/dev/null

    return 1
}

# === Main fix dispatcher (replaces old fix_one_package) ===

fix_one_package() {
    local repo="$1" original_status="$2" failure_detail="$3"
    local fix_log_file="${FIX_LOG_DIR}/${repo}-fix.log"
    : > "$fix_log_file"

    FIX_DEB_PATH=""

    # Categorise the failure
    local category
    category=$(categorise_failure "$failure_detail")
    log "  Category: ${category}"

    case "$category" in
        glibc_mismatch)
            fix_glibc_mismatch "$repo" "$failure_detail"
            return $?
            ;;
        missing_shlib)
            fix_missing_shlib "$repo" "$failure_detail"
            return $?
            ;;
        *)
            fix_unknown "$repo" "$failure_detail"
            return $?
            ;;
    esac
}

# --- Test one package on re-test VM ---
# Args: repo
# Returns: 0 if smoke test passes, 1 otherwise

test_package() {
    local repo="$1"
    local pkg_name
    pkg_name=$(repo_to_pkg "$repo")

    local smoke_cmd="${SMOKE_CMDS[$repo]:-}"
    if [ -z "$smoke_cmd" ]; then
        log "  [retest] ${repo}: no smoke test defined"
        return 1
    fi

    # Install
    # For 'linux' repo, the actual package name is linux-image-<version>, so find it dynamically
    local install_pkg="$pkg_name"
    if [ "$repo" = "linux" ]; then
        install_pkg="\$(apt-cache search '^linux-image-[0-9]' | head -1 | awk '{print \$1}')"
    fi
    log "  [retest] ${repo}: installing ${pkg_name}..."
    local install_output
    if install_output=$(sshpass -p "$BOOKWORM_PASS" ssh $SSH_BASE_OPTS \
        -o ServerAliveInterval=15 -o ServerAliveCountMax=8 \
        -p "$BOOKWORM_SSH_PORT" "${BOOKWORM_USER}@localhost" \
        "PKG=${install_pkg}; out=\$(sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-unauthenticated \$PKG 2>&1); rc=\$?; echo \"\$out\" | tail -5; exit \$rc" 2>&1); then
        log "  [retest] ${repo}: install OK"
    else
        log "  [retest] ${repo}: INSTALL FAILED on retest"
        return 1
    fi

    # Smoke test
    log "  [retest] ${repo}: running smoke test..."
    local smoke_output
    if smoke_output=$(sshpass -p "$BOOKWORM_PASS" ssh $SSH_BASE_OPTS \
        -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
        -p "$BOOKWORM_SSH_PORT" "${BOOKWORM_USER}@localhost" \
        "$smoke_cmd" 2>&1); then
        log "  [retest] ${repo}: PASS"
        return 0
    else
        log "  [retest] ${repo}: SMOKE FAILED on retest"
        return 1
    fi
}

# ============================================================
# MAIN
# ============================================================

FIX_START=$(date +%s)
log "=== Auto-fix pipeline starting (build #${BUILD_NUM}) ==="

# Verify test results file exists
if [ ! -f "$TEST_RESULTS" ]; then
    log "ERROR: Test results file not found: $TEST_RESULTS"
    exit 1
fi

# Extract Bookworm failures
declare -a FAIL_NAMES=()
declare -a FAIL_STATUSES=()
declare -a FAIL_DETAILS=()

while IFS='|' read -r name status detail; do
    [ -z "$name" ] && continue
    FAIL_NAMES+=("$name")
    FAIL_STATUSES+=("$status")
    FAIL_DETAILS+=("$detail")
done < <(extract_bookworm_failures)

TOTAL_FAILURES=${#FAIL_NAMES[@]}
log "Found ${TOTAL_FAILURES} Bookworm failures"

if [ "$TOTAL_FAILURES" -eq 0 ]; then
    log "No failures to fix"
    printf '{"duration":0,"total_failures":0,"attempted":0,"fix_skipped":0,"rebuilt":0,"retest_pass":0,"retest_fail":0,"packages":[]}' > "$OUTPUT_FILE"
    log "Results written to ${OUTPUT_FILE}"
    exit 0
fi

# Process each failure
declare -a PKG_RESULTS=()
declare -a REBUILT_PACKAGES=()
attempted=0
fix_skipped=0
rebuilt=0
fix_timeout=0
fix_no_output=0

for i in "${!FAIL_NAMES[@]}"; do
    repo="${FAIL_NAMES[$i]}"
    original_status="${FAIL_STATUSES[$i]}"
    failure_detail="${FAIL_DETAILS[$i]}"

    # Check global timeout
    elapsed=$(( $(date +%s) - FIX_START ))
    if [ "$elapsed" -ge "$FIX_PHASE_TIMEOUT" ]; then
        log "GLOBAL TIMEOUT: Fix phase exceeded ${FIX_PHASE_TIMEOUT}s, stopping"
        # Mark remaining as skipped due to timeout
        for j in $(seq "$i" $(( ${#FAIL_NAMES[@]} - 1 )) ); do
            r="${FAIL_NAMES[$j]}"
            os="${FAIL_STATUSES[$j]}"
            od="${FAIL_DETAILS[$j]}"
            PKG_RESULTS+=("{\"name\":\"$(json_escape "$r")\",\"original_status\":\"$(json_escape "$os")\",\"original_detail\":\"$(json_escape "$od")\",\"fix_status\":\"fix_timeout\",\"fix_detail\":\"Global timeout exceeded\",\"deb\":\"\",\"fix_duration\":0,\"fix_log_url\":\"\"}")
        done
        break
    fi

    # Check skip list
    if [ -n "${FIX_SKIP[$repo]:-}" ]; then
        skip_reason="${FIX_SKIP[$repo]}"
        log "[${repo}] Skipping — ${skip_reason}"
        fix_skipped=$((fix_skipped + 1))
        PKG_RESULTS+=("{\"name\":\"$(json_escape "$repo")\",\"original_status\":\"$(json_escape "$original_status")\",\"original_detail\":\"$(json_escape "$failure_detail")\",\"fix_status\":\"fix_skipped\",\"fix_detail\":\"$(json_escape "$skip_reason")\",\"deb\":\"\",\"fix_duration\":0,\"fix_log_url\":\"\"}")
        continue
    fi

    log "[${repo}] Attempting fix (${original_status}: ${failure_detail})"
    attempted=$((attempted + 1))
    fix_start_time=$(date +%s)

    if fix_one_package "$repo" "$original_status" "$failure_detail"; then
        fix_duration=$(( $(date +%s) - fix_start_time ))
        deb_name=$(basename "$FIX_DEB_PATH")
        fix_log_url="/ci/logs/${BUILD_NUM}/${repo}-fix.log"

        # Publish rebuilt .deb
        if publish_deb "$repo" "$FIX_DEB_PATH"; then
            rebuilt=$((rebuilt + 1))
            REBUILT_PACKAGES+=("$repo")
            PKG_RESULTS+=("{\"name\":\"$(json_escape "$repo")\",\"original_status\":\"$(json_escape "$original_status")\",\"original_detail\":\"$(json_escape "$failure_detail")\",\"fix_status\":\"fix_rebuilt\",\"fix_detail\":\"\",\"deb\":\"$(json_escape "$deb_name")\",\"fix_duration\":${fix_duration},\"fix_log_url\":\"$(json_escape "$fix_log_url")\"}")
        else
            fix_duration=$(( $(date +%s) - fix_start_time ))
            PKG_RESULTS+=("{\"name\":\"$(json_escape "$repo")\",\"original_status\":\"$(json_escape "$original_status")\",\"original_detail\":\"$(json_escape "$failure_detail")\",\"fix_status\":\"fix_publish_failed\",\"fix_detail\":\"Publish to repo failed\",\"deb\":\"$(json_escape "$deb_name")\",\"fix_duration\":${fix_duration},\"fix_log_url\":\"$(json_escape "$fix_log_url")\"}")
        fi
    else
        fix_duration=$(( $(date +%s) - fix_start_time ))
        fix_log_url="/ci/logs/${BUILD_NUM}/${repo}-fix.log"

        # Determine if it was a timeout or no output
        if [ "$fix_duration" -ge "$FIX_TIMEOUT" ]; then
            PKG_RESULTS+=("{\"name\":\"$(json_escape "$repo")\",\"original_status\":\"$(json_escape "$original_status")\",\"original_detail\":\"$(json_escape "$failure_detail")\",\"fix_status\":\"fix_timeout\",\"fix_detail\":\"Agent timed out after ${FIX_TIMEOUT}s\",\"deb\":\"\",\"fix_duration\":${fix_duration},\"fix_log_url\":\"$(json_escape "$fix_log_url")\"}")
        else
            fix_no_output=$((fix_no_output + 1))
            PKG_RESULTS+=("{\"name\":\"$(json_escape "$repo")\",\"original_status\":\"$(json_escape "$original_status")\",\"original_detail\":\"$(json_escape "$failure_detail")\",\"fix_status\":\"fix_no_output\",\"fix_detail\":\"No .deb produced\",\"deb\":\"\",\"fix_duration\":${fix_duration},\"fix_log_url\":\"$(json_escape "$fix_log_url")\"}")
        fi
    fi
done

# --- Re-test rebuilt packages in fresh Bookworm VM ---

retest_pass=0
retest_fail=0

if [ "${#REBUILT_PACKAGES[@]}" -gt 0 ]; then
    log "=== Re-testing ${#REBUILT_PACKAGES[@]} rebuilt packages ==="

    if [ ! -f "$BOOKWORM_BASE" ]; then
        log "ERROR: Bookworm base image not found, skipping re-test"
    elif ss -tln | grep -q ":${BOOKWORM_SSH_PORT} "; then
        log "ERROR: Port ${BOOKWORM_SSH_PORT} already in use, skipping re-test"
    else
        # Create provisioned overlay (apt repo + update baked in)
        BOOKWORM_OVERLAY="${VM_IMAGES_DIR}/bookworm-overlay-fix-${BUILD_NUM}.qcow2"
        log "Creating provisioned overlay for re-test: $BOOKWORM_OVERLAY"
        qemu-img create -f qcow2 -b "$BOOKWORM_BASE" -F qcow2 "$BOOKWORM_OVERLAY"

        log "Booting Bookworm VM for provisioning..."
        qemu-system-x86_64 \
            -drive file="$BOOKWORM_OVERLAY",format=qcow2 \
            -cdrom "$BOOKWORM_SEED" \
            -m 2048 \
            -enable-kvm \
            -cpu host \
            -smp 2 \
            -net nic \
            -net user,hostfwd=tcp::${BOOKWORM_SSH_PORT}-:22 \
            -display none \
            -daemonize \
            -pidfile /tmp/smoke-test-bookworm-fix.pid

        QEMU_PID_RETEST=$(cat /tmp/smoke-test-bookworm-fix.pid)
        log "Bookworm re-test provisioning VM started (PID $QEMU_PID_RETEST)"

        if wait_for_ssh "$BOOKWORM_SSH_PORT" "$BOOKWORM_USER" "$BOOKWORM_PASS" "bookworm-retest"; then
            log "[bookworm-retest] Provisioning: configuring NetLinux apt repository..."
            ssh_cmd "$BOOKWORM_SSH_PORT" "$BOOKWORM_USER" "$BOOKWORM_PASS" \
                "echo 'deb [trusted=yes] https://packages.netlinux.co.uk/debian stable main' | sudo tee /etc/apt/sources.list.d/netlinux.list > /dev/null" || \
                log "  WARNING: Failed to configure NetLinux apt repository"

            log "[bookworm-retest] Running apt-get update..."
            ssh_cmd "$BOOKWORM_SSH_PORT" "$BOOKWORM_USER" "$BOOKWORM_PASS" "sudo apt-get update -qq" >/dev/null 2>&1 || true

            # Flush disk and shut down cleanly to capture provisioned state
            ssh_cmd "$BOOKWORM_SSH_PORT" "$BOOKWORM_USER" "$BOOKWORM_PASS" "sudo sync && sudo shutdown -h now" >/dev/null 2>&1 || true
            sleep 5
            if kill -0 "$QEMU_PID_RETEST" 2>/dev/null; then
                kill "$QEMU_PID_RETEST" 2>/dev/null || true
                local kcount=0
                while kill -0 "$QEMU_PID_RETEST" 2>/dev/null && [ $kcount -lt 30 ]; do
                    sleep 1
                    kcount=$((kcount + 1))
                done
            fi
            QEMU_PID_RETEST=""
            rm -f /tmp/smoke-test-bookworm-fix.pid

            # Re-test each rebuilt package in its own fresh VM
            for repo in "${REBUILT_PACKAGES[@]}"; do
                local pkg_overlay="${VM_IMAGES_DIR}/bookworm-retest-${repo}.qcow2"
                qemu-img create -f qcow2 -b "$BOOKWORM_OVERLAY" -F qcow2 "$pkg_overlay" >/dev/null 2>&1

                log "  [retest] ${repo}: booting fresh VM..."
                qemu-system-x86_64 \
                    -drive file="$pkg_overlay",format=qcow2 \
                    -cdrom "$BOOKWORM_SEED" \
                    -m 2048 \
                    -enable-kvm \
                    -cpu host \
                    -smp 2 \
                    -net nic \
                    -net user,hostfwd=tcp::${BOOKWORM_SSH_PORT}-:22 \
                    -display none \
                    -daemonize \
                    -pidfile /tmp/smoke-test-bookworm-fix.pid

                QEMU_PID_RETEST=$(cat /tmp/smoke-test-bookworm-fix.pid)

                local retest_ok=false
                if wait_for_ssh "$BOOKWORM_SSH_PORT" "$BOOKWORM_USER" "$BOOKWORM_PASS" "bookworm-retest"; then
                    if test_package "$repo"; then
                        retest_ok=true
                    fi
                else
                    log "  [retest] ${repo}: VM failed to boot"
                fi

                # Tear down — poll until QEMU exits (not a child, can't use wait)
                if kill -0 "$QEMU_PID_RETEST" 2>/dev/null; then
                    kill "$QEMU_PID_RETEST" 2>/dev/null || true
                    local kcount=0
                    while kill -0 "$QEMU_PID_RETEST" 2>/dev/null && [ $kcount -lt 15 ]; do
                        sleep 1
                        kcount=$((kcount + 1))
                    done
                fi
                QEMU_PID_RETEST=""
                rm -f /tmp/smoke-test-bookworm-fix.pid "$pkg_overlay"

                # Update results
                if $retest_ok; then
                    retest_pass=$((retest_pass + 1))
                    for j in "${!PKG_RESULTS[@]}"; do
                        if echo "${PKG_RESULTS[$j]}" | grep -q "\"name\":\"$(json_escape "$repo")\"" && \
                           echo "${PKG_RESULTS[$j]}" | grep -q '"fix_status":"fix_rebuilt"'; then
                            PKG_RESULTS[$j]=$(echo "${PKG_RESULTS[$j]}" | sed 's/"fix_status":"fix_rebuilt"/"fix_status":"retest_pass"/')
                            PKG_RESULTS[$j]=$(echo "${PKG_RESULTS[$j]}" | sed 's/"fix_detail":""/"fix_detail":"Fixed and verified"/')
                        fi
                    done
                else
                    retest_fail=$((retest_fail + 1))
                    for j in "${!PKG_RESULTS[@]}"; do
                        if echo "${PKG_RESULTS[$j]}" | grep -q "\"name\":\"$(json_escape "$repo")\"" && \
                           echo "${PKG_RESULTS[$j]}" | grep -q '"fix_status":"fix_rebuilt"'; then
                            PKG_RESULTS[$j]=$(echo "${PKG_RESULTS[$j]}" | sed 's/"fix_status":"fix_rebuilt"/"fix_status":"retest_fail"/')
                            PKG_RESULTS[$j]=$(echo "${PKG_RESULTS[$j]}" | sed 's/"fix_detail":""/"fix_detail":"Rebuilt but still failing"/')
                        fi
                    done
                fi
            done
        else
            log "ERROR: Could not connect to provisioning VM, marking all as retest_fail"
            retest_fail=${#REBUILT_PACKAGES[@]}
            for repo in "${REBUILT_PACKAGES[@]}"; do
                for j in "${!PKG_RESULTS[@]}"; do
                    if echo "${PKG_RESULTS[$j]}" | grep -q "\"name\":\"$(json_escape "$repo")\"" && \
                       echo "${PKG_RESULTS[$j]}" | grep -q '"fix_status":"fix_rebuilt"'; then
                        PKG_RESULTS[$j]=$(echo "${PKG_RESULTS[$j]}" | sed 's/"fix_status":"fix_rebuilt"/"fix_status":"retest_fail"/')
                        PKG_RESULTS[$j]=$(echo "${PKG_RESULTS[$j]}" | sed 's/"fix_detail":""/"fix_detail":"Re-test VM failed to boot"/')
                    fi
                done
            done
            # Kill provisioning VM
            if [[ -n "$QEMU_PID_RETEST" ]] && kill -0 "$QEMU_PID_RETEST" 2>/dev/null; then
                kill "$QEMU_PID_RETEST" 2>/dev/null || true
                local kcount=0
                while kill -0 "$QEMU_PID_RETEST" 2>/dev/null && [ $kcount -lt 15 ]; do
                    sleep 1
                    kcount=$((kcount + 1))
                done
            fi
            QEMU_PID_RETEST=""
            rm -f /tmp/smoke-test-bookworm-fix.pid
        fi

        # Clean up provisioned overlay
        rm -f "$BOOKWORM_OVERLAY"
        BOOKWORM_OVERLAY=""
        rm -f "${VM_IMAGES_DIR}"/bookworm-retest-*.qcow2 2>/dev/null
        log "Re-test complete, overlays removed"
    fi
else
    log "No packages were rebuilt, skipping re-test"
fi

# --- Write JSON results ---

FIX_DURATION=$(( $(date +%s) - FIX_START ))
log "=== Auto-fix pipeline complete (${FIX_DURATION}s) ==="
log "Summary: total_failures=${TOTAL_FAILURES} attempted=${attempted} fix_skipped=${fix_skipped} rebuilt=${rebuilt} retest_pass=${retest_pass} retest_fail=${retest_fail}"

{
    printf '{"duration":%d,"total_failures":%d,"attempted":%d,"fix_skipped":%d,"rebuilt":%d,"retest_pass":%d,"retest_fail":%d,"packages":[' \
        "$FIX_DURATION" "$TOTAL_FAILURES" "$attempted" "$fix_skipped" "$rebuilt" "$retest_pass" "$retest_fail"
    first=true
    for r in "${PKG_RESULTS[@]}"; do
        [ "$first" = true ] && first=false || printf ','
        printf '%s' "$r"
    done
    printf ']}'
} > "$OUTPUT_FILE"

log "Results written to ${OUTPUT_FILE}"

# Upload fix log to packages server
LOG_REMOTE_DIR="${PACKAGES_LOG_DIR}/${BUILD_NUM}"
if ssh -qn "$PACKAGES_HOST" "mkdir -p ${LOG_REMOTE_DIR}" && \
   scp -q "$FIX_LOG" "${PACKAGES_HOST}:${LOG_REMOTE_DIR}/fix-pipeline.log" < /dev/null; then
    log "Fix pipeline log uploaded to /ci/logs/${BUILD_NUM}/fix-pipeline.log"
else
    log "WARNING: Failed to upload fix pipeline log"
fi
