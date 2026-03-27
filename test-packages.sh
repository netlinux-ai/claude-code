#!/usr/bin/env bash
set -euo pipefail

# === Package Smoke Test Pipeline ===
# Boots VMs (NetLinux Server ISO + Debian bookworm), installs each package,
# runs a smoke test command, and records results as JSON.
# Called by nightly-packages.sh after builds complete.
#
# Usage: test-packages.sh --build-num NUM --repos-conf FILE --output FILE --log-dir DIR

NIGHTLY_DIR="/home/graham/nightly"
SMOKE_TESTS_CONF="${NIGHTLY_DIR}/smoke-tests.conf"
VM_IMAGES_DIR="${NIGHTLY_DIR}/vm-images"
BOOKWORM_BASE="${VM_IMAGES_DIR}/bookworm-base.qcow2"
BOOKWORM_SEED="${VM_IMAGES_DIR}/bookworm-seed.iso"
NETLINUX_ISO="/Data/netlinux-server/netlinux-server-amd64.hybrid.iso"
PACKAGES_HOST="root@packages.netlinux.co.uk"
PACKAGES_LOG_DIR="/Sites/netlinux/packages/ci/logs"

# SSH settings
SSH_BASE_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"
BOOT_TIMEOUT=180
POLL_INTERVAL=5
INSTALL_TIMEOUT=120
SMOKE_TIMEOUT=30

# VM ports
NETLINUX_SSH_PORT=2223
BOOKWORM_SSH_PORT=2224

# VM credentials
NETLINUX_USER="user"
NETLINUX_PASS="live"
BOOKWORM_USER="testuser"
BOOKWORM_PASS="testpass"

# PIDs for cleanup
QEMU_PID_NETLINUX=""
QEMU_PID_BOOKWORM=""
BOOKWORM_OVERLAY=""

# --- Argument parsing ---

BUILD_NUM=""
REPOS_CONF=""
OUTPUT_FILE=""
LOG_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-num)  BUILD_NUM="$2"; shift 2 ;;
        --repos-conf) REPOS_CONF="$2"; shift 2 ;;
        --output)     OUTPUT_FILE="$2"; shift 2 ;;
        --log-dir)    LOG_DIR="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

[ -z "$BUILD_NUM" ] && { echo "ERROR: --build-num required"; exit 1; }
[ -z "$REPOS_CONF" ] && { echo "ERROR: --repos-conf required"; exit 1; }
[ -z "$OUTPUT_FILE" ] && { echo "ERROR: --output required"; exit 1; }
[ -z "$LOG_DIR" ] && { echo "ERROR: --log-dir required"; exit 1; }

TEST_LOG_DIR="${LOG_DIR}/package-tests"
mkdir -p "$TEST_LOG_DIR"
TEST_LOG="${TEST_LOG_DIR}/test-${BUILD_NUM}.log"

# --- Helpers ---

log() {
    local msg="[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"
    echo "$msg" >&2
    echo "$msg" >> "$TEST_LOG"
}

# Map repo name to package name (mirrors nightly-packages.sh)
repo_to_pkg() {
    case "$1" in
        ssr)              echo "simplescreenrecorder" ;;
        applesmc-next)    echo "applesmc-next-dkms" ;;
        chromium-browser) echo "chromium-browser-stable" ;;
        *)                echo "$1" ;;
    esac
}

cleanup() {
    log "Cleaning up VMs..."
    for pid_var in QEMU_PID_NETLINUX QEMU_PID_BOOKWORM; do
        local pid="${!pid_var}"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log "  Killing QEMU PID $pid"
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    rm -f /tmp/smoke-test-netlinux.pid /tmp/smoke-test-bookworm.pid
    if [[ -n "$BOOKWORM_OVERLAY" ]] && [[ -f "$BOOKWORM_OVERLAY" ]]; then
        log "  Removing bookworm overlay: $BOOKWORM_OVERLAY"
        rm -f "$BOOKWORM_OVERLAY"
    fi
    # Clean up any leftover per-package overlays
    rm -f "${VM_IMAGES_DIR}"/bookworm-pkg-*.qcow2 2>/dev/null
}
trap cleanup EXIT

ssh_cmd() {
    local port="$1" user="$2" pass="$3"
    shift 3
    sshpass -p "$pass" ssh $SSH_BASE_OPTS -p "$port" "${user}@localhost" "$@" 2>/dev/null
}

# Wait for SSH on a VM, return 0 on success, 1 on timeout
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

# --- Read package list from repos.conf ---

declare -a PACKAGES=()
while IFS= read -r line; do
    line=$(echo "$line" | sed 's/#.*//' | xargs)
    [ -z "$line" ] && continue
    repo=$(echo "$line" | awk '{print $1}')
    action=$(echo "$line" | awk '{print $2}')
    [ "$action" = "skip" ] && continue
    PACKAGES+=("$repo")
done < "$REPOS_CONF"

log "Loaded ${#PACKAGES[@]} packages from repos.conf"

# --- Read smoke test commands ---

declare -A SMOKE_CMDS=()
while IFS= read -r line; do
    line=$(echo "$line" | sed 's/#.*//')
    [ -z "$(echo "$line" | xargs)" ] && continue
    pkg_name=$(echo "$line" | awk '{print $1}')
    # Everything after the first field is the command
    smoke_cmd=$(echo "$line" | sed 's/^[^ \t]*//' | sed 's/^[ \t]*//')
    [ -n "$pkg_name" ] && [ -n "$smoke_cmd" ] && SMOKE_CMDS["$pkg_name"]="$smoke_cmd"
done < "$SMOKE_TESTS_CONF"

log "Loaded ${#SMOKE_CMDS[@]} smoke test definitions"

# --- JSON output helpers ---

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/\\t}"
    echo -n "$s"
}

# --- LLM-based smoke test verification ---
# Uses the llama-server (available during nightly runs) to assess whether
# smoke test output indicates a genuine pass or a false positive.

LLAMA_HEALTH_URL="${LLAMA_HEALTH_URL:-http://localhost:8090/health}"
LLAMA_API_URL="${LLAMA_API_URL:-http://localhost:8090/v1/chat/completions}"

llm_verify_smoke() {
    local repo="$1" smoke_cmd="$2" smoke_output="$3" exit_code="$4"

    # Skip if LLM isn't available
    if ! curl -sf --max-time 3 "$LLAMA_HEALTH_URL" >/dev/null 2>&1; then
        echo "pass"
        return
    fi

    # Truncate long output
    local truncated_output
    truncated_output=$(echo "$smoke_output" | head -10)

    local prompt
    prompt="A CI smoke test ran for package '${repo}'.
Command: ${smoke_cmd}
Exit code: ${exit_code}
Output:
${truncated_output}

Does this output indicate the package is working correctly? Answer ONLY 'pass' or 'fail' followed by a one-sentence reason.
- 'fail' if the output shows missing libraries, missing symbols, GLIBC errors, segfaults, 'not found' errors, or any indication the binary cannot actually run.
- 'pass' if the output shows a version string, help text, or other sign the binary works.
- An error about a missing display/X11 is OK for GUI apps and should be 'pass' as long as the binary itself loaded."

    local payload
    payload=$(python3 -c "
import json, sys
payload = {
    'model': 'local',
    'messages': [{'role': 'user', 'content': sys.stdin.read()}],
    'max_tokens': 60,
    'temperature': 0.0
}
print(json.dumps(payload))
" <<< "$prompt")

    local response
    response=$(curl -sf --max-time 30         -H "Content-Type: application/json"         -d "$payload"         "$LLAMA_API_URL" 2>/dev/null) || { echo "pass"; return; }

    local verdict
    verdict=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    text = data['choices'][0]['message']['content'].strip().lower()
    print('fail' if text.startswith('fail') else 'pass')
except:
    print('pass')
" "$response" 2>/dev/null) || verdict="pass"

    local reason
    reason=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    print(data['choices'][0]['message']['content'].strip())
except:
    print('')
" "$response" 2>/dev/null) || reason=""

    if [ -n "$reason" ]; then
        log "  LLM verdict: ${reason}"
    fi

    echo "$verdict"
}

# --- Test one package on a VM ---
# Returns: writes result to ENV_RESULTS array
# Args: repo_name port user pass env_label

declare -a ENV_RESULTS=()

test_package() {
    local repo="$1" port="$2" user="$3" pass="$4" env_label="$5"
    local pkg_name
    pkg_name=$(repo_to_pkg "$repo")

    local smoke_cmd="${SMOKE_CMDS[$repo]:-}"
    if [ -z "$smoke_cmd" ]; then
        log "  [${env_label}] ${repo}: no smoke test defined, skipping"
        ENV_RESULTS+=("{\"name\":\"$(json_escape "$repo")\",\"status\":\"skipped\",\"detail\":\"No smoke test defined\"}")
        return
    fi

    # Install
    # For 'linux' repo, the actual package name is linux-image-<version>, so find it dynamically
    local install_pkg="$pkg_name"
    if [ "$repo" = "linux" ]; then
        install_pkg="\$(apt-cache search '^linux-image-[0-9]' | head -1 | awk '{print \$1}')"
    fi
    log "  [${env_label}] ${repo}: installing ${pkg_name}..."
    local install_output
    if install_output=$(sshpass -p "$pass" ssh $SSH_BASE_OPTS \
        -o ServerAliveInterval=15 -o ServerAliveCountMax=8 \
        -p "$port" "${user}@localhost" \
        "PKG=${install_pkg}; sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-unauthenticated \$PKG >/tmp/apt-install.log 2>&1; rc=\$?; tail -5 /tmp/apt-install.log; exit \$rc" 2>&1); then
        log "  [${env_label}] ${repo}: install OK"
    else
        local detail
        detail=$(echo "$install_output" | tail -2 | tr '\n' ' ')
        log "  [${env_label}] ${repo}: INSTALL FAILED"
        ENV_RESULTS+=("{\"name\":\"$(json_escape "$repo")\",\"status\":\"install_failed\",\"detail\":\"$(json_escape "$detail")\"}")
        return
    fi

    # Smoke test
    log "  [${env_label}] ${repo}: running smoke test..."
    local smoke_output
    if smoke_output=$(sshpass -p "$pass" ssh $SSH_BASE_OPTS \
        -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
        -p "$port" "${user}@localhost" \
        "$smoke_cmd" 2>&1); then
        local detail
        detail=$(echo "$smoke_output" | head -3 | tr '\n' ' ')
        # Ask the LLM to verify this isn't a false pass
        local llm_verdict
        llm_verdict=$(llm_verify_smoke "$repo" "$smoke_cmd" "$smoke_output" "0")
        if [ "$llm_verdict" = "fail" ]; then
            log "  [${env_label}] ${repo}: SMOKE FAILED (LLM detected false pass) — ${detail}"
            ENV_RESULTS+=("{\"name\":\"$(json_escape "$repo")\",\"status\":\"smoke_failed\",\"detail\":\"LLM: $(json_escape "$detail")\"}")
        else
            log "  [${env_label}] ${repo}: PASS — ${detail}"
            ENV_RESULTS+=("{\"name\":\"$(json_escape "$repo")\",\"status\":\"pass\",\"detail\":\"$(json_escape "$detail")\"}")
        fi
    else
        local detail
        detail=$(echo "$smoke_output" | tail -2 | tr '\n' ' ')
        log "  [${env_label}] ${repo}: SMOKE FAILED"
        ENV_RESULTS+=("{\"name\":\"$(json_escape "$repo")\",\"status\":\"smoke_failed\",\"detail\":\"$(json_escape "$detail")\"}")
    fi
}

# --- Boot a NetLinux Server VM from the live ISO ---
# Returns 0 on success (SSH ready)

boot_netlinux_vm() {
    qemu-system-x86_64 \
        -cdrom "$NETLINUX_ISO" \
        -m 8192 \
        -enable-kvm \
        -cpu host \
        -smp 2 \
        -net nic \
        -net user,hostfwd=tcp::${NETLINUX_SSH_PORT}-:22 \
        -display none \
        -daemonize \
        -pidfile /tmp/smoke-test-netlinux.pid

    QEMU_PID_NETLINUX=$(cat /tmp/smoke-test-netlinux.pid)
    wait_for_ssh "$NETLINUX_SSH_PORT" "$NETLINUX_USER" "$NETLINUX_PASS" "netlinux-server"
}

# --- Kill the running NetLinux VM ---

kill_netlinux_vm() {
    if [[ -n "$QEMU_PID_NETLINUX" ]] && kill -0 "$QEMU_PID_NETLINUX" 2>/dev/null; then
        kill "$QEMU_PID_NETLINUX" 2>/dev/null || true
        local count=0
        while kill -0 "$QEMU_PID_NETLINUX" 2>/dev/null && [ $count -lt 15 ]; do
            sleep 1
            count=$((count + 1))
        done
        if kill -0 "$QEMU_PID_NETLINUX" 2>/dev/null; then
            kill -9 "$QEMU_PID_NETLINUX" 2>/dev/null || true
            sleep 1
        fi
    fi
    QEMU_PID_NETLINUX=""
    rm -f /tmp/smoke-test-netlinux.pid
}

# --- Provision a fresh NetLinux Server VM with the apt repo ---

provision_netlinux_vm() {
    ssh_cmd "$NETLINUX_SSH_PORT" "$NETLINUX_USER" "$NETLINUX_PASS" \
        "cd /tmp && wget -q -r -np -nd -A 'netlinux-server_*_all.deb' http://packages.netlinux.co.uk/debian/pool/main/n/netlinux-server/ 2>/dev/null; \
         DEB=\$(ls -1 /tmp/netlinux-server_*_all.deb 2>/dev/null | head -1); \
         if [ -n \"\$DEB\" ]; then sudo dpkg -i \"\$DEB\" 2>&1 | tail -3; sudo apt-get install -f -y 2>&1 | tail -3; rm -f /tmp/netlinux-server_*.deb; fi; \
         sudo apt-get update -qq >/dev/null 2>&1" || return 1
}

# --- Test all packages on NetLinux Server, each in a fresh VM ---
# Writes JSON environment block to stdout

test_all_netlinux_isolated() {
    local env_label="netlinux-server"

    ENV_RESULTS=()
    for repo in "${PACKAGES[@]}"; do
        local smoke_cmd="${SMOKE_CMDS[$repo]:-}"
        if [ -z "$smoke_cmd" ]; then
            log "  [${env_label}] ${repo}: no smoke test defined, skipping"
            ENV_RESULTS+=("{\"name\":\"$(json_escape "$repo")\",\"status\":\"skipped\",\"detail\":\"No smoke test defined\"}")
            continue
        fi

        log "  [${env_label}] ${repo}: booting fresh VM..."
        if boot_netlinux_vm; then
            # Provision: install meta-package + apt-get update
            provision_netlinux_vm || log "  [${env_label}] WARNING: provisioning failed"
            test_package "$repo" "$NETLINUX_SSH_PORT" "$NETLINUX_USER" "$NETLINUX_PASS" "$env_label"
        else
            log "  [${env_label}] ${repo}: VM failed to boot"
            ENV_RESULTS+=("{\"name\":\"$(json_escape "$repo")\",\"status\":\"install_failed\",\"detail\":\"VM failed to boot for this package\"}")
        fi

        kill_netlinux_vm
    done

    # Compute counts
    local total=${#ENV_RESULTS[@]}
    local pass=0 install_failed=0 smoke_failed=0 skipped=0
    for r in "${ENV_RESULTS[@]}"; do
        case "$r" in
            *'"status":"pass"'*)           pass=$((pass + 1)) ;;
            *'"status":"install_failed"'*) install_failed=$((install_failed + 1)) ;;
            *'"status":"smoke_failed"'*)   smoke_failed=$((smoke_failed + 1)) ;;
            *'"status":"skipped"'*)        skipped=$((skipped + 1)) ;;
        esac
    done

    log "[$env_label] Results: ${pass}/${total} pass, ${install_failed} install_failed, ${smoke_failed} smoke_failed, ${skipped} skipped"

    # Build JSON
    printf '{"name":"%s","boot_ok":true,"total":%d,"pass":%d,"install_failed":%d,"smoke_failed":%d,"skipped":%d,"packages":[' \
        "$(json_escape "$env_label")" "$total" "$pass" "$install_failed" "$smoke_failed" "$skipped"
    local first=true
    for r in "${ENV_RESULTS[@]}"; do
        [ "$first" = true ] && first=false || printf ','
        printf '%s' "$r"
    done
    printf ']}'
}

# --- Boot a Bookworm VM from an overlay ---
# Args: overlay_path
# Sets QEMU_PID_BOOKWORM, returns 0 on success (SSH ready)

boot_bookworm_vm() {
    local overlay="$1"

    qemu-system-x86_64 \
        -drive file="$overlay",format=qcow2 \
        -cdrom "$BOOKWORM_SEED" \
        -m 2048 \
        -enable-kvm \
        -cpu host \
        -smp 2 \
        -net nic \
        -net user,hostfwd=tcp::${BOOKWORM_SSH_PORT}-:22 \
        -display none \
        -daemonize \
        -pidfile /tmp/smoke-test-bookworm.pid

    QEMU_PID_BOOKWORM=$(cat /tmp/smoke-test-bookworm.pid)
    wait_for_ssh "$BOOKWORM_SSH_PORT" "$BOOKWORM_USER" "$BOOKWORM_PASS" "debian-bookworm"
}

# --- Kill the running Bookworm VM ---

kill_bookworm_vm() {
    if [[ -n "$QEMU_PID_BOOKWORM" ]] && kill -0 "$QEMU_PID_BOOKWORM" 2>/dev/null; then
        kill "$QEMU_PID_BOOKWORM" 2>/dev/null || true
        # Poll until process actually exits (can't use wait — daemonized, not a child)
        local count=0
        while kill -0 "$QEMU_PID_BOOKWORM" 2>/dev/null && [ $count -lt 30 ]; do
            sleep 1
            count=$((count + 1))
        done
        # Force kill if still alive
        if kill -0 "$QEMU_PID_BOOKWORM" 2>/dev/null; then
            kill -9 "$QEMU_PID_BOOKWORM" 2>/dev/null || true
            sleep 1
        fi
    fi
    QEMU_PID_BOOKWORM=""
    rm -f /tmp/smoke-test-bookworm.pid
}

# --- Test all packages, each in a fresh Bookworm VM ---
# Args: provisioned_overlay env_label
# Writes JSON environment block to stdout
#
# For each package: create COW overlay on top of provisioned image,
# boot VM, install + smoke test, destroy VM. This ensures packages
# cannot corrupt each other's environment.

test_all_packages_isolated() {
    local provisioned_base="$1" env_label="$2"

    ENV_RESULTS=()
    for repo in "${PACKAGES[@]}"; do
        local smoke_cmd="${SMOKE_CMDS[$repo]:-}"
        if [ -z "$smoke_cmd" ]; then
            log "  [${env_label}] ${repo}: no smoke test defined, skipping"
            ENV_RESULTS+=("{\"name\":\"$(json_escape "$repo")\",\"status\":\"skipped\",\"detail\":\"No smoke test defined\"}")
            continue
        fi

        # Create per-package COW overlay on top of provisioned base
        local pkg_overlay="${VM_IMAGES_DIR}/bookworm-pkg-${repo}.qcow2"
        qemu-img create -f qcow2 -b "$provisioned_base" -F qcow2 "$pkg_overlay" >/dev/null 2>&1

        log "  [${env_label}] ${repo}: booting fresh VM..."
        if boot_bookworm_vm "$pkg_overlay"; then
            test_package "$repo" "$BOOKWORM_SSH_PORT" "$BOOKWORM_USER" "$BOOKWORM_PASS" "$env_label"
        else
            log "  [${env_label}] ${repo}: VM failed to boot"
            ENV_RESULTS+=("{\"name\":\"$(json_escape "$repo")\",\"status\":\"install_failed\",\"detail\":\"VM failed to boot for this package\"}")
        fi

        # Tear down VM + overlay
        kill_bookworm_vm
        rm -f "$pkg_overlay"
    done

    # Compute counts
    local total=${#ENV_RESULTS[@]}
    local pass=0 install_failed=0 smoke_failed=0 skipped=0
    for r in "${ENV_RESULTS[@]}"; do
        case "$r" in
            *'"status":"pass"'*)           pass=$((pass + 1)) ;;
            *'"status":"install_failed"'*) install_failed=$((install_failed + 1)) ;;
            *'"status":"smoke_failed"'*)   smoke_failed=$((smoke_failed + 1)) ;;
            *'"status":"skipped"'*)        skipped=$((skipped + 1)) ;;
        esac
    done

    log "[$env_label] Results: ${pass}/${total} pass, ${install_failed} install_failed, ${smoke_failed} smoke_failed, ${skipped} skipped"

    # Build JSON
    printf '{"name":"%s","boot_ok":true,"total":%d,"pass":%d,"install_failed":%d,"smoke_failed":%d,"skipped":%d,"packages":[' \
        "$(json_escape "$env_label")" "$total" "$pass" "$install_failed" "$smoke_failed" "$skipped"
    local first=true
    for r in "${ENV_RESULTS[@]}"; do
        [ "$first" = true ] && first=false || printf ','
        printf '%s' "$r"
    done
    printf ']}'
}

# --- Test all packages on a single already-booted VM ---
# Args: port user pass env_label
# Writes JSON environment block to stdout (used by NetLinux Server)

test_all_packages() {
    local port="$1" user="$2" pass="$3" env_label="$4"

    ENV_RESULTS=()
    for repo in "${PACKAGES[@]}"; do
        test_package "$repo" "$port" "$user" "$pass" "$env_label"
    done

    # Compute counts
    local total=${#ENV_RESULTS[@]}
    local pass_count=0 install_failed=0 smoke_failed=0 skipped=0
    for r in "${ENV_RESULTS[@]}"; do
        case "$r" in
            *'"status":"pass"'*)           pass_count=$((pass_count + 1)) ;;
            *'"status":"install_failed"'*) install_failed=$((install_failed + 1)) ;;
            *'"status":"smoke_failed"'*)   smoke_failed=$((smoke_failed + 1)) ;;
            *'"status":"skipped"'*)        skipped=$((skipped + 1)) ;;
        esac
    done

    log "[$env_label] Results: ${pass_count}/${total} pass, ${install_failed} install_failed, ${smoke_failed} smoke_failed, ${skipped} skipped"

    # Build JSON
    printf '{"name":"%s","boot_ok":true,"total":%d,"pass":%d,"install_failed":%d,"smoke_failed":%d,"skipped":%d,"packages":[' \
        "$(json_escape "$env_label")" "$total" "$pass_count" "$install_failed" "$smoke_failed" "$skipped"
    local first=true
    for r in "${ENV_RESULTS[@]}"; do
        [ "$first" = true ] && first=false || printf ','
        printf '%s' "$r"
    done
    printf ']}'
}

# --- Build JSON for a failed-to-boot environment ---

boot_failed_json() {
    local env_label="$1"
    local total=${#PACKAGES[@]}
    printf '{"name":"%s","boot_ok":false,"total":%d,"pass":0,"install_failed":0,"smoke_failed":0,"skipped":%d,"packages":[' \
        "$(json_escape "$env_label")" "$total" "$total"
    local first=true
    for repo in "${PACKAGES[@]}"; do
        [ "$first" = true ] && first=false || printf ','
        printf '{"name":"%s","status":"skipped","detail":"VM failed to boot"}' "$(json_escape "$repo")"
    done
    printf ']}'
}

# ============================================================
# MAIN
# ============================================================

TEST_START=$(date +%s)
log "=== Package smoke tests starting (build #${BUILD_NUM}) ==="

declare -a ENV_JSON_BLOCKS=()

# --- Environment 1: NetLinux Server ISO ---

log "--- Environment: NetLinux Server ---"

if [ ! -f "$NETLINUX_ISO" ]; then
    log "ERROR: NetLinux ISO not found: $NETLINUX_ISO"
    ENV_JSON_BLOCKS+=("$(boot_failed_json "netlinux-server")")
else
    # Check port is free
    if ss -tln | grep -q ":${NETLINUX_SSH_PORT} "; then
        log "ERROR: Port ${NETLINUX_SSH_PORT} already in use"
        ENV_JSON_BLOCKS+=("$(boot_failed_json "netlinux-server")")
    else
        log "[netlinux-server] Testing packages with per-package VM isolation..."
        NETLINUX_JSON=$(test_all_netlinux_isolated)
        ENV_JSON_BLOCKS+=("$NETLINUX_JSON")
        # Ensure any leftover VM is killed
        kill_netlinux_vm
        log "NetLinux Server testing complete"
    fi
fi

# --- Environment 2: Debian Bookworm ---

log "--- Environment: Debian Bookworm ---"

# Auto-refresh base image if needed
if [ ! -f "$BOOKWORM_BASE" ]; then
    log "Bookworm base image not found, running prepare script..."
    if "${NIGHTLY_DIR}/prepare-bookworm-vm.sh" --force; then
        log "Base image prepared"
    else
        log "ERROR: Failed to prepare bookworm base image"
        ENV_JSON_BLOCKS+=("$(boot_failed_json "debian-bookworm")")
    fi
elif [ -f "$BOOKWORM_BASE" ]; then
    local_age=$(( ( $(date +%s) - $(stat -c %Y "$BOOKWORM_BASE") ) / 86400 ))
    if [ "$local_age" -gt 30 ]; then
        log "Base image is ${local_age} days old, refreshing..."
        "${NIGHTLY_DIR}/prepare-bookworm-vm.sh" --force || true
    fi
fi

if [ -f "$BOOKWORM_BASE" ]; then
    # Check port is free
    if ss -tln | grep -q ":${BOOKWORM_SSH_PORT} "; then
        log "ERROR: Port ${BOOKWORM_SSH_PORT} already in use"
        ENV_JSON_BLOCKS+=("$(boot_failed_json "debian-bookworm")")
    else
        # Step 1: Create a provisioned snapshot (apt repo + update baked in)
        BOOKWORM_OVERLAY="${VM_IMAGES_DIR}/bookworm-provisioned-${BUILD_NUM}.qcow2"
        log "Creating provisioned overlay: $BOOKWORM_OVERLAY"
        qemu-img create -f qcow2 -b "$BOOKWORM_BASE" -F qcow2 "$BOOKWORM_OVERLAY"

        log "Booting Bookworm VM for provisioning..."
        if boot_bookworm_vm "$BOOKWORM_OVERLAY"; then
            log "[debian-bookworm] Provisioning: configuring NetLinux apt repository..."
            ssh_cmd "$BOOKWORM_SSH_PORT" "$BOOKWORM_USER" "$BOOKWORM_PASS" \
                "echo 'deb [trusted=yes] https://packages.netlinux.co.uk/debian stable main' | sudo tee /etc/apt/sources.list.d/netlinux.list > /dev/null" || \
                log "  WARNING: Failed to configure NetLinux apt repository"

            log "[debian-bookworm] Running apt-get update..."
            ssh_cmd "$BOOKWORM_SSH_PORT" "$BOOKWORM_USER" "$BOOKWORM_PASS" \
                "sudo apt-get update -qq" >/dev/null 2>&1 || true

            # Flush disk and shut down cleanly so overlay captures the provisioned state
            log "[debian-bookworm] Syncing and shutting down provisioning VM..."
            ssh_cmd "$BOOKWORM_SSH_PORT" "$BOOKWORM_USER" "$BOOKWORM_PASS" \
                "sudo sync && sudo shutdown -h now" >/dev/null 2>&1 || true
            sleep 5
            kill_bookworm_vm
            log "[debian-bookworm] Provisioning VM stopped, overlay saved"

            # Step 2: Test each package in its own fresh VM (COW on top of provisioned overlay)
            log "[debian-bookworm] Testing packages with per-package VM isolation..."
            BOOKWORM_JSON=$(test_all_packages_isolated "$BOOKWORM_OVERLAY" "debian-bookworm")
            ENV_JSON_BLOCKS+=("$BOOKWORM_JSON")
        else
            ENV_JSON_BLOCKS+=("$(boot_failed_json "debian-bookworm")")
        fi

        # Clean up provisioned overlay
        kill_bookworm_vm
        rm -f "$BOOKWORM_OVERLAY"
        BOOKWORM_OVERLAY=""
        log "Bookworm testing complete, overlays removed"
    fi
fi

# --- Write JSON results ---

TEST_DURATION=$(( $(date +%s) - TEST_START ))
log "=== Package smoke tests complete (${TEST_DURATION}s) ==="

{
    printf '{"duration":%d,"environments":[' "$TEST_DURATION"
    first=true
    for block in "${ENV_JSON_BLOCKS[@]}"; do
        [ "$first" = true ] && first=false || printf ','
        printf '%s' "$block"
    done
    printf ']}'
} > "$OUTPUT_FILE"

log "Results written to ${OUTPUT_FILE}"

# Upload test log to packages server
LOG_REMOTE_DIR="${PACKAGES_LOG_DIR}/${BUILD_NUM}"
if ssh -qn "$PACKAGES_HOST" "mkdir -p ${LOG_REMOTE_DIR}" && \
   scp -q "$TEST_LOG" "${PACKAGES_HOST}:${LOG_REMOTE_DIR}/package-tests.log" < /dev/null; then
    log "Test log uploaded to /ci/logs/${BUILD_NUM}/package-tests.log"
else
    log "WARNING: Failed to upload test log"
fi
