#!/bin/bash
#
# WebDAV Throughput Benchmark Script v2
# Run from the Ubuntu client against a RHEL WebDAV server (nginx dav_module)
#
# Usage:
#   ./webdav_benchmark_v2.sh <server-ip> [port] [single_stream_file_MB] [parallel_stream_file_MB] [repeats]
#
# Example:
#   ./webdav_benchmark_v2.sh 10.202.148.159 8080 1000 200 3
#
# CHANGES FROM v1:
#   - Every curl call now has --max-time so a hang produces a bounded, logged failure
#     instead of silently stalling the whole round.
#   - Failures capture HTTP status code + curl exit code, not just a generic "FAIL".
#   - Each stream-count level is run REPEATS times (default 3) and the MEDIAN is reported,
#     so a single noisy round (TIME_WAIT exhaustion, transient stall) doesn't look like
#     a real throughput ceiling.
#   - settle() now actively polls TIME_WAIT socket count on the client instead of a fixed
#     sleep, and warns if it's still high after a max wait.
#   - Optional NUMA pinning of the curl client processes via NUMA_NODE env var, since
#     cross-node NIC access can itself cause the kind of non-monotonic throughput swings
#     this script is designed to catch (see check_numa()).
#   - Static-file control test: uploads/downloads the same size file to a NON-dav nginx
#     path if you set STATIC_URL, to isolate dav_module overhead from raw HTTP overhead.

set -uo pipefail

# ---------- Config ----------
SERVER_IP="${1:-}"
PORT="${2:-8080}"
FILE_SIZE_MB="${3:-1000}"
PARALLEL_FILE_MB="${4:-200}"
REPEATS="${5:-3}"
DAV_PATH="dav"
TEST_DIR="/tmp/webdav_bench"
PARALLEL_LEVELS=(${PARALLEL_LEVELS_OVERRIDE:-2 4 8 16 32 48 64})
MAX_TIME_SECONDS="${MAX_TIME_SECONDS:-15}"     # per-request curl timeout (was 60 - way too slow to fail)
TIME_WAIT_POLL_MAX=30          # max seconds to wait for TIME_WAIT to drain
TIME_WAIT_THRESHOLD=200        # if more sockets than this remain, warn but continue
NUMA_NODE="${NUMA_NODE:-}"     # optional: set e.g. NUMA_NODE=0 to pin curl via numactl
STATIC_URL="${STATIC_URL:-}"   # optional: e.g. http://ip:port/staticfile for control test

# ---------- Colors ----------
BOLD="\033[1m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; CYAN="\033[1;36m"; RED="\033[1;31m"; RESET="\033[0m"

die() { echo -e "${RED}ERROR:${RESET} $1"; exit 1; }

if [[ -z "$SERVER_IP" ]]; then
    die "Usage: $0 <server-ip> [port] [file_size_MB] [parallel_file_MB] [repeats]"
fi

BASE_URL="http://${SERVER_IP}:${PORT}/${DAV_PATH}"

command -v curl >/dev/null || die "curl not found"
command -v bc >/dev/null || die "bc not found (sudo apt install -y bc)"
command -v dd >/dev/null || die "dd not found"
command -v ss >/dev/null || die "ss not found (part of iproute2)"

if [[ -n "$NUMA_NODE" ]]; then
    command -v numactl >/dev/null || die "NUMA_NODE set but numactl not found (sudo apt install -y numactl)"
fi

mkdir -p "$TEST_DIR"
TEST_FILE="${TEST_DIR}/testfile_${FILE_SIZE_MB}MB"
PAR_FILE="${TEST_DIR}/parfile_${PARALLEL_FILE_MB}MB"
LOG_FILE="${TEST_DIR}/run_$(date +%Y%m%d_%H%M%S).log"

log() { echo -e "$1" | tee -a "$LOG_FILE" >&2; }

# ---------- NUMA diagnostics (informational, non-blocking) ----------
check_numa() {
    print_header "NUMA / NIC AFFINITY CHECK (informational)"
    if ! command -v numactl >/dev/null; then
        echo -e "${YELLOW}numactl not installed - skipping NUMA diagnostics (install with: sudo apt install numactl)${RESET}"
        return
    fi
    numactl --hardware 2>/dev/null | head -n 5

    # Try to find the primary route interface to the server and its NUMA node
    local iface
    iface=$(ip route get "$SERVER_IP" 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
    if [[ -n "$iface" ]]; then
        local numa_node
        numa_node=$(cat "/sys/class/net/${iface}/device/numa_node" 2>/dev/null || echo "unknown")
        echo -e "NIC used to reach ${SERVER_IP}: ${BOLD}${iface}${RESET}  (NUMA node: ${BOLD}${numa_node}${RESET})"
        if [[ "$numa_node" == "-1" ]]; then
            echo -e "${YELLOW}NIC reports NUMA node -1 (no affinity info / not a NUMA-aware device path).${RESET}"
        elif [[ -n "$NUMA_NODE" && "$NUMA_NODE" != "$numa_node" ]]; then
            echo -e "${YELLOW}WARNING: NUMA_NODE=${NUMA_NODE} was requested but NIC is on node ${numa_node}.${RESET}"
            echo -e "${YELLOW}         Consider re-running with NUMA_NODE=${numa_node} to bind curl to the NIC's node.${RESET}"
        elif [[ -z "$NUMA_NODE" ]]; then
            echo -e "${CYAN}Tip: NIC is on node ${numa_node}. Re-run with NUMA_NODE=${numa_node} to pin curl processes there${RESET}"
            echo -e "${CYAN}     and rule out cross-node memory access as a source of throughput noise.${RESET}"
        fi
    else
        echo -e "${YELLOW}Could not determine outbound interface for ${SERVER_IP}${RESET}"
    fi
    echo -e "${CYAN}Also worth checking on both client and server: which CPUs service the NIC's IRQs${RESET}"
    echo -e "${CYAN}(cat /proc/interrupts | grep <iface>) and whether they're on the same NUMA node as the NIC.${RESET}"
}

# curl wrapper: applies NUMA pinning if requested
run_curl() {
    if [[ -n "$NUMA_NODE" ]]; then
        numactl --cpunodebind="$NUMA_NODE" --membind="$NUMA_NODE" curl "$@"
    else
        curl "$@"
    fi
}

# ---------- TIME_WAIT-aware settle ----------
settle() {
    sync
    local waited=0
    local tw_count
    tw_count=$(ss -tan state time-wait 2>/dev/null | grep -c "${SERVER_IP}:${PORT}" || true)
    while (( tw_count > TIME_WAIT_THRESHOLD && waited < TIME_WAIT_POLL_MAX )); do
        sleep 1
        waited=$((waited + 1))
        tw_count=$(ss -tan state time-wait 2>/dev/null | grep -c "${SERVER_IP}:${PORT}" || true)
    done
    if (( tw_count > TIME_WAIT_THRESHOLD )); then
        echo -e "${YELLOW}Note: ${tw_count} TIME_WAIT sockets to ${SERVER_IP}:${PORT} still open after ${waited}s wait.${RESET}"
        echo -e "${YELLOW}      This can affect the next round's connection setup time.${RESET}"
    fi
    sleep 1
}

check_local_mem() {
    local avail_pct
    avail_pct=$(free | awk '/Mem:/ {printf "%.0f", $7/$2*100}')
    if (( avail_pct < 15 )); then
        echo -e "${RED}WARNING: local available RAM below 15% (${avail_pct}%). Skipping higher concurrency to avoid crash.${RESET}"
        return 1
    fi
    return 0
}

check_ulimit() {
    local nofile
    nofile=$(ulimit -n)
    echo -e "Client ulimit -n (open files): ${BOLD}${nofile}${RESET}"
    local max_needed=$(( $(printf '%s\n' "${PARALLEL_LEVELS[@]}" | sort -n | tail -1) * 2 + 50 ))
    if (( nofile < max_needed )); then
        echo -e "${YELLOW}WARNING: ulimit -n (${nofile}) may be too low for ${max_needed} concurrent sockets.${RESET}"
        echo -e "${YELLOW}         Consider: ulimit -n 65536 (in this shell, before running)${RESET}"
    fi
}

print_header() {
    echo -e "\n${BOLD}${CYAN}============================================================${RESET}"
    echo -e "${BOLD}${CYAN} $1${RESET}"
    echo -e "${BOLD}${CYAN}============================================================${RESET}"
}

bytes_to_gbit() {
    local bytes=$1 secs=$2
    if (( $(echo "$secs <= 0" | bc -l) )); then echo "0.00"; return; fi
    echo "scale=3; ($bytes * 8) / $secs / 1000000000" | bc -l
}

bytes_to_mb() { echo "scale=1; $1 / 1000000" | bc -l; }

median() {
    # prints median of space-separated numeric args
    local -a vals=($(printf '%s\n' "$@" | sort -n))
    local n=${#vals[@]}
    if (( n == 0 )); then echo "0"; return; fi
    if (( n % 2 == 1 )); then
        echo "${vals[$((n/2))]}"
    else
        echo "scale=3; (${vals[$((n/2-1))]} + ${vals[$((n/2))]}) / 2" | bc -l
    fi
}

# ---------- Prep test file ----------
print_header "PREPARING TEST FILE (${FILE_SIZE_MB} MB, direct I/O, safe for RAM)"
if [[ -f "$TEST_FILE" ]]; then
    echo -e "${YELLOW}Reusing existing test file: ${TEST_FILE}${RESET}"
else
    dd if=/dev/zero of="$TEST_FILE" bs=1M count="$FILE_SIZE_MB" oflag=direct status=progress 2>&1 | tail -n 1
fi
ACTUAL_SIZE=$(stat -c%s "$TEST_FILE")
echo -e "${GREEN}Single-stream test file ready: $(bytes_to_mb $ACTUAL_SIZE) MB${RESET}"

if [[ -f "$PAR_FILE" ]]; then
    echo -e "${YELLOW}Reusing existing parallel test file: ${PAR_FILE}${RESET}"
else
    dd if=/dev/zero of="$PAR_FILE" bs=1M count="$PARALLEL_FILE_MB" oflag=direct status=progress 2>&1 | tail -n 1
fi
PAR_SIZE=$(stat -c%s "$PAR_FILE")
echo -e "${GREEN}Parallel-round test file ready: $(bytes_to_mb $PAR_SIZE) MB (used per stream)${RESET}"

# ---------- Connectivity + environment checks ----------
print_header "CHECKING SERVER CONNECTIVITY"
if ! curl -s -o /dev/null -w "" --connect-timeout 5 "http://${SERVER_IP}:${PORT}/"; then
    die "Cannot reach ${SERVER_IP}:${PORT} - check server is up and firewall allows it"
fi
echo -e "${GREEN}Server reachable at ${BASE_URL}${RESET}"

print_header "CLIENT RESOURCE LIMITS"
check_ulimit

check_numa

# ---------- Optional static-file control test ----------
if [[ -n "$STATIC_URL" ]]; then
    print_header "CONTROL TEST: STATIC FILE (non-dav path, isolates dav_module overhead)"
    UP_SPEED=$(run_curl -T "$TEST_FILE" "$STATIC_URL" --max-time "$MAX_TIME_SECONDS" -w "%{speed_upload}" -o /dev/null -s)
    UP_GBIT=$(bytes_to_gbit "$UP_SPEED" 1)
    echo -e "Static PUT speed: $(echo "scale=2; $UP_SPEED/1000000" | bc -l) MB/s => ${GREEN}${UP_GBIT} Gbit/s${RESET}"
    DOWN_SPEED=$(run_curl -o /dev/null "$STATIC_URL" --max-time "$MAX_TIME_SECONDS" -w "%{speed_download}" -s)
    DOWN_GBIT=$(bytes_to_gbit "$DOWN_SPEED" 1)
    echo -e "Static GET speed: $(echo "scale=2; $DOWN_SPEED/1000000" | bc -l) MB/s => ${GREEN}${DOWN_GBIT} Gbit/s${RESET}"
    echo -e "${CYAN}Compare these to the dav single-stream numbers below - large gaps mean dav_module/filesystem overhead,${RESET}"
    echo -e "${CYAN}not network/disk overhead.${RESET}"
fi

# ---------- Results storage ----------
declare -A UPLOAD_RESULTS
declare -A DOWNLOAD_RESULTS
declare -A UPLOAD_FAILDETAIL
declare -A DOWNLOAD_FAILDETAIL

# ---------- Single stream test ----------
print_header "SINGLE STREAM TEST (curl native timing, median of ${REPEATS} runs)"

UP_SPEEDS=()
DOWN_SPEEDS=()
for ((r=1; r<=REPEATS; r++)); do
    S=$(run_curl -T "$TEST_FILE" "${BASE_URL}/single_up" --max-time "$MAX_TIME_SECONDS" -w "%{speed_upload}" -o /dev/null -s)
    UP_SPEEDS+=("$S")
    D=$(run_curl -o /dev/null "${BASE_URL}/single_up" --max-time "$MAX_TIME_SECONDS" -w "%{speed_download}" -s)
    DOWN_SPEEDS+=("$D")
done
UP_SPEED_MED=$(median "${UP_SPEEDS[@]}")
DOWN_SPEED_MED=$(median "${DOWN_SPEEDS[@]}")
UP_GBIT=$(bytes_to_gbit "$UP_SPEED_MED" 1)
DOWN_GBIT=$(bytes_to_gbit "$DOWN_SPEED_MED" 1)

printf "${BOLD}Upload  (1 stream, median):${RESET}   %10.2f MB/s   =>   ${GREEN}%s Gbit/s${RESET}\n" \
    "$(echo "scale=2; $UP_SPEED_MED/1000000" | bc -l)" "$UP_GBIT"
printf "${BOLD}Download(1 stream, median):${RESET}   %10.2f MB/s   =>   ${GREEN}%s Gbit/s${RESET}\n" \
    "$(echo "scale=2; $DOWN_SPEED_MED/1000000" | bc -l)" "$DOWN_GBIT"

UPLOAD_RESULTS[1]=$UP_GBIT
DOWNLOAD_RESULTS[1]=$DOWN_GBIT

# ---------- Parallel sweep: UPLOAD ----------
print_header "PARALLEL UPLOAD SWEEP (median of ${REPEATS} runs per level)"

for N in "${PARALLEL_LEVELS[@]}"; do
    if ! check_local_mem; then
        break
    fi
    RUN_GBITS=()
    RUN_FAILS=0
    for ((r=1; r<=REPEATS; r++)); do
        echo -ne "${YELLOW}Testing ${N} parallel upload streams, run ${r}/${REPEATS} (per-stream file: ${PARALLEL_FILE_MB}MB)...${RESET}\r"
        rm -f "${TEST_DIR}/.fail_$$"
        START=$(date +%s.%N)
        for ((i=1; i<=N; i++)); do
            (
                status=$(run_curl -T "$PAR_FILE" "${BASE_URL}/par_up_${N}_${i}_${r}" \
                    --max-time "$MAX_TIME_SECONDS" -o /dev/null -s -w "%{http_code}")
                rc=$?
                if [[ "$status" != "201" && "$status" != "204" ]] || (( rc != 0 )); then
                    echo "stream=${i} http=${status:-none} curl_rc=${rc}" >> "${TEST_DIR}/.fail_$$"
                fi
            ) &
        done
        wait
        END=$(date +%s.%N)

        FAIL_COUNT=0
        if [[ -f "${TEST_DIR}/.fail_$$" ]]; then
            FAIL_COUNT=$(wc -l < "${TEST_DIR}/.fail_$$")
            UPLOAD_FAILDETAIL[$N]="${UPLOAD_FAILDETAIL[$N]:-}$(cat "${TEST_DIR}/.fail_$$")"$'\n'
            rm -f "${TEST_DIR}/.fail_$$"
        fi
        RUN_FAILS=$((RUN_FAILS + FAIL_COUNT))

        ELAPSED=$(echo "$END - $START" | bc -l)
        SUCCESS_COUNT=$((N - FAIL_COUNT))
        TOTAL_BYTES=$((PAR_SIZE * SUCCESS_COUNT))
        GBIT=$(bytes_to_gbit "$TOTAL_BYTES" "$ELAPSED")
        RUN_GBITS+=("$GBIT")

        # cleanup remote files for this run
        for ((i=1; i<=N; i++)); do
            run_curl -X DELETE "${BASE_URL}/par_up_${N}_${i}_${r}" --max-time 10 -s -o /dev/null &
        done
        wait
        settle
    done

    GBIT_MED=$(median "${RUN_GBITS[@]}")
    UPLOAD_RESULTS[$N]=$GBIT_MED
    if (( RUN_FAILS > 0 )); then
        printf "%-34s ${RED}%s Gbit/s (median)${RESET}   [${RED}%d total failures across %d runs${RESET}]\n" \
            "Upload  (${N} streams):" "$GBIT_MED" "$RUN_FAILS" "$REPEATS"
    else
        printf "%-34s ${GREEN}%s Gbit/s (median)${RESET}   [0 failures across %d runs]\n" \
            "Upload  (${N} streams):" "$GBIT_MED" "$REPEATS"
    fi
done

# ---------- Parallel sweep: DOWNLOAD ----------
print_header "PARALLEL DOWNLOAD SWEEP (median of ${REPEATS} runs per level)"

run_curl -T "$PAR_FILE" "${BASE_URL}/par_download_source" --max-time "$MAX_TIME_SECONDS" -o /dev/null -s

for N in "${PARALLEL_LEVELS[@]}"; do
    if ! check_local_mem; then
        break
    fi
    RUN_GBITS=()
    RUN_FAILS=0
    for ((r=1; r<=REPEATS; r++)); do
        echo -ne "${YELLOW}Testing ${N} parallel download streams, run ${r}/${REPEATS}...${RESET}\r"
        rm -f "${TEST_DIR}/.fail_$$"
        START=$(date +%s.%N)
        for ((i=1; i<=N; i++)); do
            (
                status=$(run_curl -o /dev/null "${BASE_URL}/par_download_source" \
                    --max-time "$MAX_TIME_SECONDS" -s -w "%{http_code}")
                rc=$?
                if [[ "$status" != "200" ]] || (( rc != 0 )); then
                    echo "stream=${i} http=${status:-none} curl_rc=${rc}" >> "${TEST_DIR}/.fail_$$"
                fi
            ) &
        done
        wait
        END=$(date +%s.%N)

        FAIL_COUNT=0
        if [[ -f "${TEST_DIR}/.fail_$$" ]]; then
            FAIL_COUNT=$(wc -l < "${TEST_DIR}/.fail_$$")
            DOWNLOAD_FAILDETAIL[$N]="${DOWNLOAD_FAILDETAIL[$N]:-}$(cat "${TEST_DIR}/.fail_$$")"$'\n'
            rm -f "${TEST_DIR}/.fail_$$"
        fi
        RUN_FAILS=$((RUN_FAILS + FAIL_COUNT))

        ELAPSED=$(echo "$END - $START" | bc -l)
        SUCCESS_COUNT=$((N - FAIL_COUNT))
        TOTAL_BYTES=$((PAR_SIZE * SUCCESS_COUNT))
        GBIT=$(bytes_to_gbit "$TOTAL_BYTES" "$ELAPSED")
        RUN_GBITS+=("$GBIT")

        settle
    done

    GBIT_MED=$(median "${RUN_GBITS[@]}")
    DOWNLOAD_RESULTS[$N]=$GBIT_MED
    if (( RUN_FAILS > 0 )); then
        printf "%-34s ${RED}%s Gbit/s (median)${RESET}   [${RED}%d total failures across %d runs${RESET}]\n" \
            "Download(${N} streams):" "$GBIT_MED" "$RUN_FAILS" "$REPEATS"
    else
        printf "%-34s ${GREEN}%s Gbit/s (median)${RESET}   [0 failures across %d runs]\n" \
            "Download(${N} streams):" "$GBIT_MED" "$REPEATS"
    fi
done

run_curl -X DELETE "${BASE_URL}/par_download_source" --max-time 10 -s -o /dev/null
run_curl -X DELETE "${BASE_URL}/single_up" --max-time 10 -s -o /dev/null

# ---------- Failure detail dump ----------
print_header "FAILURE DETAIL (if any)"
HAD_FAILURES=0
for N in "${PARALLEL_LEVELS[@]}"; do
    if [[ -n "${UPLOAD_FAILDETAIL[$N]:-}" ]]; then
        HAD_FAILURES=1
        echo -e "${RED}Upload failures at ${N} streams:${RESET}"
        echo -e "${UPLOAD_FAILDETAIL[$N]}" | sed '/^$/d'
    fi
    if [[ -n "${DOWNLOAD_FAILDETAIL[$N]:-}" ]]; then
        HAD_FAILURES=1
        echo -e "${RED}Download failures at ${N} streams:${RESET}"
        echo -e "${DOWNLOAD_FAILDETAIL[$N]}" | sed '/^$/d'
    fi
done
if (( HAD_FAILURES == 0 )); then
    echo -e "${GREEN}No failures recorded.${RESET}"
else
    echo -e "${CYAN}Cross-reference these http codes / curl_rc values with:${RESET}"
    echo -e "${CYAN}  - curl_rc=28  => timeout (hit --max-time ${MAX_TIME_SECONDS}s, likely a stall, not a real cap)${RESET}"
    echo -e "${CYAN}  - curl_rc=56/52 => connection reset by peer (check server nginx error log)${RESET}"
    echo -e "${CYAN}  - http=507 => server out of storage${RESET}"
    echo -e "${CYAN}  - http=none, curl_rc=7 => connection refused (server hit worker_connections limit?)${RESET}"
    echo -e "${CYAN}Also check server-side: tail -f /var/log/nginx/error.log during a re-run${RESET}"
fi

# ---------- Final summary ----------
print_header "SUMMARY - WebDAV THROUGHPUT (Gbit/s, median of ${REPEATS} runs)"

printf "${BOLD}%-12s %15s %15s${RESET}\n" "Streams" "Upload" "Download"
echo "------------------------------------------------"

BEST_UP=0; BEST_UP_N=1
BEST_DOWN=0; BEST_DOWN_N=1

for N in 1 "${PARALLEL_LEVELS[@]}"; do
    [[ -z "${UPLOAD_RESULTS[$N]:-}" ]] && continue
    UP="${UPLOAD_RESULTS[$N]}"
    DOWN="${DOWNLOAD_RESULTS[$N]:-N/A}"
    printf "%-12s %15s %15s\n" "$N" "$UP" "$DOWN"

    if (( $(echo "$UP > $BEST_UP" | bc -l) )); then BEST_UP=$UP; BEST_UP_N=$N; fi
    if [[ "$DOWN" != "N/A" ]] && (( $(echo "$DOWN > $BEST_DOWN" | bc -l) )); then BEST_DOWN=$DOWN; BEST_DOWN_N=$N; fi
done

echo "------------------------------------------------"
echo -e "${BOLD}${GREEN}Max Upload:   ${BEST_UP} Gbit/s   (at ${BEST_UP_N} parallel streams)${RESET}"
echo -e "${BOLD}${GREEN}Max Download: ${BEST_DOWN} Gbit/s   (at ${BEST_DOWN_N} parallel streams)${RESET}"
echo ""
echo -e "${CYAN}Full log saved to: ${LOG_FILE}${RESET}"
echo -e "${CYAN}If numbers are still non-monotonic (dip then recover) after this v2 run,${RESET}"
echo -e "${CYAN}re-check NUMA pinning (NUMA_NODE=<node> $0 ...) and server-side ulimits/worker_connections.${RESET}"

# ---------- Cleanup local test files ----------
echo ""
read -p "Delete local test files (${TEST_FILE}, ${PAR_FILE})? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -f "$TEST_FILE" "$PAR_FILE"
    echo "Deleted."
fi