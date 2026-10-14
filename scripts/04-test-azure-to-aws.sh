#!/usr/bin/env bash
# =============================================================================
# 04-test-azure-to-aws.sh
#
# SSHes into the Azure VM and runs three checks against the EC2
# instance's PRIVATE IP: TCP port 22 check first (bash /dev/tcp, no
# extra tools needed), then ping, then path trace (tracepath preferred,
# traceroute fallback) — same tool choices and ordering confirmed to
# work well in the sibling GCP project (traceroute/nc were found missing
# by default on both AWS and GCP images; tracepath/dev-tcp need no
# installation at all).
#
# Output is captured to screenshots/ for use in the article.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_cmd ssh
load_config

VM_PUBLIC_IP="$(state_get "${AZURE_STATE_FILE}" "vm_public_ip")"
EC2_PRIVATE_IP="$(state_get "${AWS_STATE_FILE}" "ec2_private_ip")"
KEY_PATH="${KEYS_DIR}/${SSH_KEY_NAME_AZURE}"

# Must match terraform/azure/variables.tf's admin_username default.
SSH_USER="azureuser"

[[ -f "${KEY_PATH}" ]] || die "SSH key not found at ${KEY_PATH}. Run ./scripts/01-azure-up.sh first."

log_info "SSH into Azure VM (${VM_PUBLIC_IP}) and test connectivity to EC2 private IP (${EC2_PRIVATE_IP})..."

OUTPUT_FILE="${SCREENSHOTS_DIR}/test-from-azure-$(date +%Y%m%d-%H%M%S).txt"

ssh -i "${KEY_PATH}" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=15 \
    "${SSH_USER}@${VM_PUBLIC_IP}" bash -s -- "${EC2_PRIVATE_IP}" << 'REMOTE_SCRIPT' | tee "${OUTPUT_FILE}"
TARGET="$1"

echo "=== TCP port 22 check (bash /dev/tcp — no extra tools needed) ==="
if timeout 3 bash -c "echo > /dev/tcp/${TARGET}/22" 2>/dev/null; then
  echo "TCP port 22: OPEN (connection succeeded)"
else
  echo "TCP port 22: could not connect (timeout, refused, or filtered)"
fi

echo ""
echo "=== ping ==="
ping -c 4 -W 3 "${TARGET}"

echo ""
echo "=== path trace ==="
if command -v tracepath >/dev/null 2>&1; then
  tracepath -n "${TARGET}" 2>&1
elif command -v traceroute >/dev/null 2>&1; then
  traceroute -n -w 2 -q 1 -m 15 "${TARGET}" 2>&1
else
  echo "Neither tracepath nor traceroute installed on this instance — skipping."
fi
REMOTE_SCRIPT

log_ok "Output saved to ${OUTPUT_FILE}"