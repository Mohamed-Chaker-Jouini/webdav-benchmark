#!/bin/bash
#
# WebDAV Throughput Benchmark Script
# Run from the Ubuntu client against a RHEL WebDAV server (nginx dav_module)
#
# Usage:
#   ./webdav_benchmark.sh <server-ip> [port] [single_stream_file_MB] [parallel_stream_file_MB]
#
# Example:
#   ./webdav_benchmark.sh 10.202.148.159 8080 1000 200
#
# NOTE ON MEMORY SAFETY:
#   Parallel rounds use a SEPARATE, SMALLER file (parallel_stream_file_MB, default 200MB)
#   so that N parallel streams don't multiply a huge file N times and blow out RAM/dirty
#   page cache on the server. A `sync` + pause happens between rounds to let writes flush
#   to disk before the next round starts. If you still see memory pressure on the SERVER
#   side, lower PARALLEL_FILE_MB further and/or reduce PARALLEL_LEVELS below.

set -uo pipefail

# ---------- Config ----------
SERVER_IP="${1:-}"
PORT="${2:-8080}"
FILE_SIZE_MB="${3:-1000}"     # SINGLE-STREAM test file size in MB (default 1GB)
PARALLEL_FILE_MB="${4:-200}"  # PER-STREAM file size for parallel rounds (default 200MB - keeps total data bounded)
DAV_PATH="dav"
TEST_DIR="/tmp/webdav_bench"
PARALLEL_LEVELS=(2 4 8 16)   # stream counts to sweep through - kept modest on purpose
SETTLE_SECONDS=5              # pause between rounds to let server flush dirty pages

# ---------- Colors ----------
BOLD="\033[1m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
RED="\033[1;31m"
RESET="\033[0m"

# ---------- Helpers ----------
die() { echo -e "${RED}ERROR:${RESET} $1"; exit 1; }

if [[ -z "$SERVER_IP" ]]; then
    die "Usage: $0 <server-ip> [port] [file_size_MB]"
fi

BASE_URL="http://${SERVER_IP}:${PORT}/${DAV_PATH}"

command -v curl >/dev/null || die "curl not found"
command -v bc >/dev/null || die "bc not found (sudo apt install -y bc)"
command -v dd >/dev/null || die "dd not found"

mkdir -p "$TEST_DIR"
TEST_FILE="${TEST_DIR}/testfile_${FILE_SIZE_MB}MB"
PAR_FILE="${TEST_DIR}/parfile_${PARALLEL_FILE_MB}MB"

settle() {
    # Let dirty pages flush both locally and give the server breathing room
    sync
    sleep "$SETTLE_SECONDS"
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

print_header() {
    echo -e "\n${BOLD}${CYAN}============================================================${RESET}"
    echo -e "${BOLD}${CYAN} $1${RESET}"
    echo -e "${BOLD}${CYAN}============================================================${RESET}"
}

bytes_to_gbit() {
    # $1 = bytes, $2 = seconds -> prints Gbit/s
    local bytes=$1
    local secs=$2
    if (( $(echo "$secs <= 0" | bc -l) )); then
        echo "0.00"
        return
    fi
    echo "scale=3; ($bytes * 8) / $secs / 1000000000" | bc -l
}

bytes_to_mb() {
    echo "scale=1; $1 / 1000000" | bc -l
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

# ---------- Connectivity check ----------
print_header "CHECKING SERVER CONNECTIVITY"
if ! curl -s -o /dev/null -w "" --connect-timeout 5 "http://${SERVER_IP}:${PORT}/"; then
    die "Cannot reach ${SERVER_IP}:${PORT} - check server is up and firewall allows it"
fi
echo -e "${GREEN}Server reachable at ${BASE_URL}${RESET}"

# ---------- Results storage ----------
declare -A UPLOAD_RESULTS
declare -A DOWNLOAD_RESULTS

# ---------- Single stream test (baseline, using curl's own timing) ----------
print_header "SINGLE STREAM TEST (curl native timing)"

UP_SPEED=$(curl -T "$TEST_FILE" "${BASE_URL}/single_up" -w "%{speed_upload}" -o /dev/null -s)
UP_GBIT=$(bytes_to_gbit "$UP_SPEED" 1)
printf "${BOLD}Upload  (1 stream):${RESET}   %10.2f MB/s   =>   ${GREEN}%s Gbit/s${RESET}\n" \
    "$(echo "scale=2; $UP_SPEED/1000000" | bc -l)" "$UP_GBIT"

DOWN_SPEED=$(curl -o /dev/null "${BASE_URL}/single_up" -w "%{speed_download}" -s)
DOWN_GBIT=$(bytes_to_gbit "$DOWN_SPEED" 1)
printf "${BOLD}Download(1 stream):${RESET}   %10.2f MB/s   =>   ${GREEN}%s Gbit/s${RESET}\n" \
    "$(echo "scale=2; $DOWN_SPEED/1000000" | bc -l)" "$DOWN_GBIT"

UPLOAD_RESULTS[1]=$UP_GBIT
DOWNLOAD_RESULTS[1]=$DOWN_GBIT

# ---------- Parallel sweep: UPLOAD ----------
print_header "PARALLEL UPLOAD SWEEP (finding max throughput)"

for N in "${PARALLEL_LEVELS[@]}"; do
    if ! check_local_mem; then
        break
    fi
    echo -ne "${YELLOW}Testing ${N} parallel upload streams (per-stream file: ${PARALLEL_FILE_MB}MB)...${RESET}\r"

    START=$(date +%s.%N)
    for ((i=1; i<=N; i++)); do
        curl -T "$PAR_FILE" "${BASE_URL}/par_up_${N}_${i}" -o /dev/null -s &
    done
    wait
    END=$(date +%s.%N)

    ELAPSED=$(echo "$END - $START" | bc -l)
    TOTAL_BYTES=$((PAR_SIZE * N))
    GBIT=$(bytes_to_gbit "$TOTAL_BYTES" "$ELAPSED")
    MBPS=$(echo "scale=1; $TOTAL_BYTES / $ELAPSED / 1000000" | bc -l)

    UPLOAD_RESULTS[$N]=$GBIT
    printf "%-30s %10s MB/s   =>   ${GREEN}%s Gbit/s${RESET}   (%.2fs)   [total data: %s MB]\n" \
        "Upload  (${N} streams):" "$MBPS" "$GBIT" "$ELAPSED" "$(bytes_to_mb $TOTAL_BYTES)"

    # cleanup remote files for this round
    for ((i=1; i<=N; i++)); do
        curl -X DELETE "${BASE_URL}/par_up_${N}_${i}" -s -o /dev/null &
    done
    wait

    echo -e "${CYAN}Settling (sync + ${SETTLE_SECONDS}s pause) before next round...${RESET}"
    settle
done

# ---------- Parallel sweep: DOWNLOAD ----------
print_header "PARALLEL DOWNLOAD SWEEP (finding max throughput)"

# upload the small parallel-round file once, use it as the shared download source
curl -T "$PAR_FILE" "${BASE_URL}/par_download_source" -o /dev/null -s

for N in "${PARALLEL_LEVELS[@]}"; do
    if ! check_local_mem; then
        break
    fi
    echo -ne "${YELLOW}Testing ${N} parallel download streams (per-stream file: ${PARALLEL_FILE_MB}MB)...${RESET}\r"

    START=$(date +%s.%N)
    for ((i=1; i<=N; i++)); do
        curl -o /dev/null "${BASE_URL}/par_download_source" -s &
    done
    wait
    END=$(date +%s.%N)

    ELAPSED=$(echo "$END - $START" | bc -l)
    TOTAL_BYTES=$((PAR_SIZE * N))
    GBIT=$(bytes_to_gbit "$TOTAL_BYTES" "$ELAPSED")
    MBPS=$(echo "scale=1; $TOTAL_BYTES / $ELAPSED / 1000000" | bc -l)

    DOWNLOAD_RESULTS[$N]=$GBIT
    printf "%-30s %10s MB/s   =>   ${GREEN}%s Gbit/s${RESET}   (%.2fs)   [total data: %s MB]\n" \
        "Download(${N} streams):" "$MBPS" "$GBIT" "$ELAPSED" "$(bytes_to_mb $TOTAL_BYTES)"

    echo -e "${CYAN}Settling (sync + ${SETTLE_SECONDS}s pause) before next round...${RESET}"
    settle
done

curl -X DELETE "${BASE_URL}/par_download_source" -s -o /dev/null

# ---------- Cleanup remote test files ----------
curl -X DELETE "${BASE_URL}/single_up" -s -o /dev/null

# ---------- Final summary ----------
print_header "SUMMARY - WebDAV THROUGHPUT (Gbit/s)"

printf "${BOLD}%-12s %15s %15s${RESET}\n" "Streams" "Upload" "Download"
echo "------------------------------------------------"

BEST_UP=0
BEST_UP_N=1
BEST_DOWN=0
BEST_DOWN_N=1

for N in 1 "${PARALLEL_LEVELS[@]}"; do
    [[ -z "${UPLOAD_RESULTS[$N]:-}" ]] && continue
    UP="${UPLOAD_RESULTS[$N]}"
    DOWN="${DOWNLOAD_RESULTS[$N]:-N/A}"
    printf "%-12s %15s %15s\n" "$N" "$UP" "$DOWN"

    if (( $(echo "$UP > $BEST_UP" | bc -l) )); then
        BEST_UP=$UP
        BEST_UP_N=$N
    fi
    if [[ "$DOWN" != "N/A" ]] && (( $(echo "$DOWN > $BEST_DOWN" | bc -l) )); then
        BEST_DOWN=$DOWN
        BEST_DOWN_N=$N
    fi
done

echo "------------------------------------------------"
echo -e "${BOLD}${GREEN}Max Upload:   ${BEST_UP} Gbit/s   (at ${BEST_UP_N} parallel streams)${RESET}"
echo -e "${BOLD}${GREEN}Max Download: ${BEST_DOWN} Gbit/s   (at ${BEST_DOWN_N} parallel streams)${RESET}"
echo ""
echo -e "${CYAN}Tip: if throughput keeps climbing at your highest stream count,${RESET}"
echo -e "${CYAN}     add more values to PARALLEL_LEVELS in the script and re-run.${RESET}"
echo -e "${CYAN}     If it plateaus or drops, you've found the real ceiling${RESET}"
echo -e "${CYAN}     (disk, network, or CPU on server, not WebDAV itself).${RESET}"

# ---------- Cleanup local test files ----------
echo ""
read -p "Delete local test files (${TEST_FILE}, ${PAR_FILE})? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -f "$TEST_FILE" "$PAR_FILE"
    echo "Deleted."
fi