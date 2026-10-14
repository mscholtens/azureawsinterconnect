#!/usr/bin/env bash
# =============================================================================
# 05-test-aws-to-azure.sh
#
# SSHes into the EC2 instance and runs the same three checks against the
# Azure VM's PRIVATE IP as 04-test-azure-to-aws.sh runs in the other
# direction — see that script's header comment for tool choices.
#
# Output is captured to screenshots/ for use in the article.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_cmd ssh
load_config

EC2_PUBLIC_IP="$(state_get "${AWS_STATE_FILE}" "ec2_public_ip")"
VM_PRIVATE_IP="$(state_get "${AZURE_STATE_FILE}" "vm_private_ip")"
KEY_PATH="${KEYS_DIR}/${SSH_KEY_NAME_AWS}"

# Amazon Linux 2023 default SSH user — kept in sync with
# terraform/aws/compute.tf's chosen AMI.
SSH_USER="ec2-user"

[[ -f "${KEY_PATH}" ]] || die "SSH key not found at ${KEY_PATH}. Run ./scripts/02-aws-up.sh first."

log_info "SSH into EC2 (${EC2_PUBLIC_IP}) and test connectivity to Azure VM private IP (${VM_PRIVATE_IP})..."

OUTPUT_FILE="${SCREENSHOTS_DIR}/test-from-aws-$(date +%Y%m%d-%H%M%S).txt"

ssh -i "${KEY_PATH}" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=15 \
    "${SSH_USER}@${EC2_PUBLIC_IP}" bash -s -- "${VM_PRIVATE_IP}" << 'REMOTE_SCRIPT' | tee "${OUTPUT_FILE}"
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