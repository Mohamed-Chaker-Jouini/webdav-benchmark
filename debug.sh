#!/bin/bash
# debug.sh - run from the Ubuntu client (webdav-benchmark dir)
# Kicks off a 64-stream-only benchmark round in the background, then samples
# client + proxy + backend simultaneously while it runs. Paste the full output.

set -uo pipefail

PROXY_IP="${1:-192.168.95.1}"
BACKEND_IP="${2:-192.168.95.2}"
SSH_USER="${SSH_USER:-root}"
SSH="ssh -o StrictHostKeyChecking=no ${SSH_USER}"

echo "=============================================="
echo "STATIC INFO (before load)"
echo "=============================================="

echo "--- client: ulimit / port range ---"
ulimit -n
cat /proc/sys/net/ipv4/ip_local_port_range

echo "--- client: nginx? (should be none, client has no nginx) ---"
which nginx 2>/dev/null || echo "n/a (expected)"

echo "--- backend ($BACKEND_IP): tmpfs usage ---"
$SSH "$BACKEND_IP" "df -h /mnt/webdav_ram" 2>&1

echo "--- backend ($BACKEND_IP): nginx worker_processes / thread_pool config ---"
$SSH "$BACKEND_IP" "grep -E 'worker_processes|thread_pool|worker_connections|worker_rlimit' /etc/nginx/nginx.conf" 2>&1

echo "--- backend ($BACKEND_IP): nginx worker count actually running ---"
$SSH "$BACKEND_IP" "ps -C nginx -o pid,psr,pcpu,cmd --no-headers | wc -l" 2>&1

echo "--- proxy ($PROXY_IP): nginx worker_processes config ---"
$SSH "$PROXY_IP" "grep -E 'worker_processes|worker_connections|worker_rlimit' /etc/nginx/nginx.conf" 2>&1

echo ""
echo "=============================================="
echo "LAUNCHING 64-STREAM BURST IN BACKGROUND"
echo "=============================================="

cd "$(dirname "$0")" || exit 1
PARALLEL_LEVELS_OVERRIDE="64" REPEATS="${REPEATS:-2}" MAX_TIME_SECONDS="${MAX_TIME_SECONDS:-15}" \
    ./benchmark.sh "$PROXY_IP" 8080 "${FILE_SIZE_MB:-1000}" "${PARALLEL_FILE_MB:-50}" "${REPEATS:-2}" \
    > /tmp/debug_bench_run.log 2>&1 &
BENCH_PID=$!

echo "Benchmark PID: $BENCH_PID - sampling for ~12s while it runs..."
sleep 4

echo ""
echo "=============================================="
echo "LIVE SAMPLES (taken ~4s into the burst)"
echo "=============================================="

echo "--- client: ss -s ---"
ss -s

echo "--- client: open FDs held by benchmark/curl processes ---"
for p in $(pgrep -f 'curl|benchmark.sh'); do
    n=$(ls /proc/$p/fd 2>/dev/null | wc -l)
    echo "pid $p: $n fds"
done | sort -t: -k2 -n | tail -5

echo "--- backend ($BACKEND_IP): mpstat all cores (1s sample) ---"
$SSH "$BACKEND_IP" "mpstat -P ALL 1 1 2>/dev/null || (echo 'mpstat not installed, using /proc/stat snapshot'; cat /proc/loadavg)" 2>&1

echo "--- backend ($BACKEND_IP): ss -s ---"
$SSH "$BACKEND_IP" "ss -s" 2>&1

echo "--- backend ($BACKEND_IP): tmpfs usage mid-run ---"
$SSH "$BACKEND_IP" "df -h /mnt/webdav_ram" 2>&1

echo "--- backend ($BACKEND_IP): thread pool / queue errors in nginx log ---"
$SSH "$BACKEND_IP" "grep -iE 'thread pool|queue overflow|worker_connections|accept4|EMFILE|ENFILE|no space' /var/log/nginx/error.log | tail -20" 2>&1

echo "--- backend ($BACKEND_IP): recent nginx errors (any) ---"
$SSH "$BACKEND_IP" "tail -20 /var/log/nginx/error.log" 2>&1

echo "--- proxy ($PROXY_IP): ss -s ---"
$SSH "$PROXY_IP" "ss -s" 2>&1

echo "--- proxy ($PROXY_IP): recent nginx errors ---"
$SSH "$PROXY_IP" "tail -20 /var/log/nginx/error.log" 2>&1

echo ""
echo "Waiting for benchmark to finish (up to 60s more)..."
wait "$BENCH_PID" 2>/dev/null
sleep 1

echo ""
echo "=============================================="
echo "BENCHMARK RESULT (64-stream round)"
echo "=============================================="
tail -40 /tmp/debug_bench_run.log

echo ""
echo "=============================================="
echo "DONE - paste everything above"
echo "=============================================="