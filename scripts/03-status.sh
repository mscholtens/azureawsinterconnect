#!/usr/bin/env bash
# =============================================================================
# 03-status.sh
#
# Prints the current state of the Azure ExpressRoute circuit, the Azure
# Gateway Connection, and the AWS Interconnect Connection.
#
# HONEST CAVEAT, carried over from the GCP project's hard-won lesson:
# state-string values for brand-new preview services have repeatedly
# turned out to be an unreliable proxy for "is data actually flowing."
# In the GCP project, AWS's connection state cycled between "requested"
# and "pending" while working fine the whole time, and GCP's transport
# state showed "PENDING_CONFIG" during a run that was simultaneously
# passing pings. This script reports raw states for diagnostic purposes
# and does NOT claim to definitively judge readiness — use
# scripts/04 and 05 (actual ping/trace/TCP tests) as the real signal.
#
# Usage:
#   ./scripts/03-status.sh          # check once and exit
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_cmd aws az jq
load_config

for f in "${AZURE_STATE_FILE}" "${AWS_STATE_FILE}"; do
  if [[ ! -f "${f}" ]] || [[ "$(jq -r 'length' "${f}" 2>/dev/null || echo 0)" == "0" ]]; then
    side="Azure"; script="01-azure-up.sh"
    [[ "${f}" == "${AWS_STATE_FILE}" ]] && { side="AWS"; script="02-aws-up.sh"; }
    die "${f} is empty or missing — the ${side} side isn't up yet. Run ./scripts/${script} first."
  fi
done

azure_login >/dev/null 2>&1 || log_warn "az login failed — Azure checks below may be unreliable."

CIRCUIT_NAME="$(state_get "${AZURE_STATE_FILE}" "circuit_name")"
RESOURCE_GROUP="$(state_get "${AZURE_STATE_FILE}" "resource_group")"
AWS_CONNECTION_ID="$(state_get "${AWS_STATE_FILE}" "connection_id")"

check_circuit_state() {
  local raw state
  raw="$(az network express-route show --name "${CIRCUIT_NAME}" --resource-group "${RESOURCE_GROUP}" --output json 2>&1)"
  state="$(echo "${raw}" | jq -r '.circuitProvisioningState // .provisioningState // empty' 2>/dev/null)"
  if [[ -z "${state}" ]]; then
    echo "[DEBUG] az network express-route show raw output:" >&2
    echo "${raw}" >&2
    state="UNKNOWN"
  fi
  echo "${state}"
}

check_gateway_connection_state() {
  # UNCONFIRMED command — `az network vpn-connection show` is documented
  # for VPN gateway connections; whether it also covers ExpressRoute-type
  # connections (same underlying ARM resource type,
  # Microsoft.Network/connections) hasn't been directly verified. If
  # this errors, check `az network express-route gateway connection
  # show` or the Azure portal instead.
  local gw_conn_id raw state
  gw_conn_id="$(state_get "${AZURE_STATE_FILE}" "gateway_connection_id")"

  if [[ "${gw_conn_id}" == "pending-aws-acceptance" ]]; then
    echo "not yet created (waiting on AWS acceptance — see 01-azure-up.sh)"
    return
  fi

  # `az rest` instead of `az resource show`: the latter crashes on some CLI
  # installs (missing azure.mgmt.resource module). Same ARM resource.
  raw="$(az rest --method get --url "https://management.azure.com${gw_conn_id}?api-version=2024-07-01" --output json 2>&1)"
  state="$(echo "${raw}" | jq -r '.properties.connectionStatus // .properties.provisioningState // empty' 2>/dev/null)"
  if [[ -z "${state}" ]]; then
    echo "[DEBUG] az rest (gateway connection) raw output:" >&2
    echo "${raw}" >&2
    state="UNKNOWN"
  fi
  echo "${state}"
}

check_aws_state() {
  # --identifier confirmed correct (not --connection-id) in the GCP
  # project via a real CLI error message.
  local raw state
  raw="$(aws interconnect get-connection --identifier "${AWS_CONNECTION_ID}" \
    --region "${AWS_REGION}" --output json 2>&1)"
  state="$(echo "${raw}" | jq -r '[.. | objects | .state? // empty] | first // empty' 2>/dev/null)"
  if [[ -z "${state}" ]]; then
    echo "[DEBUG] aws interconnect get-connection raw output:" >&2
    echo "${raw}" >&2
    state="UNKNOWN"
  fi
  echo "${state}"
}

echo ""
echo "  Azure ExpressRoute Circuit   (${CIRCUIT_NAME}): $(check_circuit_state)"
echo "  Azure Gateway Connection     : $(check_gateway_connection_state)"
echo "  AWS Interconnect Connection  (${AWS_CONNECTION_ID}): $(check_aws_state)"
echo ""
log_warn "These states are informational only — do not treat any particular value as a definitive readiness signal (see this script's header comment). Run 04/05 for a real connectivity test."