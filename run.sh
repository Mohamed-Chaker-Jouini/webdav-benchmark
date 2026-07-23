#!/bin/bash
# run-bench.sh
export ANSIBLE_FORCE_COLOR=1
export PY_COLORS=1
ansible-playbook -i inventory.ini playbook.yml \
  -e numa_node_client="${1:-0}" \
  -e file_size_mb="${2:-2000}" \
  -e parallel_file_mb="${3:-200}" \
  -e repeats="${4:-3}"