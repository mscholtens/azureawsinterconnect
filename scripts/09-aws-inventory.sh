#!/usr/bin/env bash
# =============================================================================
# 09-aws-inventory.sh
#
# Comprehensive, read-only inventory of every AWS resource type this
# project creates, for troubleshooting. Direct adaptation of the sibling
# GCP project's confirmed-working 08-aws-inventory.sh — same fixes
# already applied here from the start (the --identifier flag, not
# --connection-id; robust jq-based state parsing instead of guessed
# --query paths).
#
# Checks EVERY region passed as an argument, defaulting to just the
# currently configured AWS_REGION if none given. Also checks Direct
# Connect Gateways and DX Gateway Associations, which are GLOBAL (not
# region-scoped).
#
# Usage:
#   ./scripts/09-aws-inventory.sh
#   ./scripts/09-aws-inventory.sh us-east-1
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_cmd aws jq
load_config

REGIONS=("$@")
if [[ ${#REGIONS[@]} -eq 0 ]]; then
  REGIONS=("${AWS_REGION}")
fi

TAG_FILTER="Name=tag:Project,Values=aws-azure-interconnect-experiment"
KEY_PAIR_NAME="interconnect-experiment-ec2"
DXGW_NAME="interconnect-experiment-dxgw"

print_row() {
  printf "  %-24s %s\n" "$1:" "${2:-<none>}"
}

echo "==================================================================="
echo " AWS resource inventory — aws-azure-interconnect-experiment"
echo " Regions checked: ${REGIONS[*]}"
echo "==================================================================="

for REGION in "${REGIONS[@]}"; do
  echo ""
  echo "--- Region: ${REGION} ---"

  INSTANCES="$(aws ec2 describe-instances --region "${REGION}" --filters "${TAG_FILTER}" \
    --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text 2>/dev/null)"
  print_row "EC2 instances" "${INSTANCES:-<none>}"

  VPCS="$(aws ec2 describe-vpcs --region "${REGION}" --filters "${TAG_FILTER}" \
    --query 'Vpcs[].VpcId' --output text 2>/dev/null)"
  print_row "VPCs" "${VPCS:-<none>}"

  SUBNETS="$(aws ec2 describe-subnets --region "${REGION}" --filters "${TAG_FILTER}" \
    --query 'Subnets[].SubnetId' --output text 2>/dev/null)"
  print_row "Subnets" "${SUBNETS:-<none>}"

  IGWS="$(aws ec2 describe-internet-gateways --region "${REGION}" --filters "${TAG_FILTER}" \
    --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null)"
  print_row "Internet Gateways" "${IGWS:-<none>}"

  RTBS="$(aws ec2 describe-route-tables --region "${REGION}" --filters "${TAG_FILTER}" \
    --query 'RouteTables[].RouteTableId' --output text 2>/dev/null)"
  print_row "Route Tables" "${RTBS:-<none>}"

  SGS="$(aws ec2 describe-security-groups --region "${REGION}" --filters "${TAG_FILTER}" \
    --query 'SecurityGroups[].GroupId' --output text 2>/dev/null)"
  print_row "Security Groups" "${SGS:-<none>}"

  VGWS="$(aws ec2 describe-vpn-gateways --region "${REGION}" --filters "${TAG_FILTER}" \
    --query 'VpnGateways[?State!=`deleted`].VpnGatewayId' --output text 2>/dev/null)"
  print_row "VPN Gateways" "${VGWS:-<none>}"

  KEYPAIR="$(aws ec2 describe-key-pairs --region "${REGION}" --key-names "${KEY_PAIR_NAME}" \
    --query 'KeyPairs[].KeyName' --output text 2>/dev/null)"
  print_row "Key Pair (${KEY_PAIR_NAME})" "${KEYPAIR:-<none>}"

  CONNS_JSON="$(aws interconnect list-connections --region "${REGION}" --output json 2>/dev/null)"
  CONN_IDS="$(echo "${CONNS_JSON}" | jq -r '[.. | strings | select(test("^mcc-"))] | unique | .[]' 2>/dev/null | tr '\n' ' ')"
  # Fallback: the list call's JSON shape is not documented; also check the ID we recorded.
  if [[ -z "${CONN_IDS}" && -f "${AWS_STATE_FILE}" ]]; then
    _sid="$(state_get "${AWS_STATE_FILE}" "connection_id")"
    if [[ -n "${_sid}" && "${_sid}" != "null" ]] && aws interconnect get-connection --identifier "${_sid}" --region "${REGION}" >/dev/null 2>&1; then
      CONN_IDS="${_sid}"
    fi
  fi
  if [[ -n "${CONN_IDS}" ]]; then
    print_row "Interconnect Connections" "${CONN_IDS}"
    for CID in ${CONN_IDS}; do
      CSTATE="$(aws interconnect get-connection --identifier "${CID}" --region "${REGION}" --output json 2>/dev/null \
        | jq -r '[.. | objects | .state? // empty] | first // "UNKNOWN"')"
      print_row "  └─ ${CID} state" "${CSTATE:-UNKNOWN}"
    done
  else
    print_row "Interconnect Connections" "<none>"
  fi
done

echo ""
echo "--- Global (not region-scoped) ---"

DXGWS="$(aws directconnect describe-direct-connect-gateways \
  --query "directConnectGateways[?directConnectGatewayName=='${DXGW_NAME}'].directConnectGatewayId" \
  --output text 2>/dev/null)"
print_row "Direct Connect Gateways" "${DXGWS:-<none>}"

DXGW_ASSOCS="$(aws directconnect describe-direct-connect-gateway-associations \
  --query 'directConnectGatewayAssociations[].associationId' --output text 2>/dev/null)"
print_row "DX Gateway Associations" "${DXGW_ASSOCS:-<none>}"

echo ""
echo "--- Local Terraform state (terraform/aws), for comparison ---"
if [[ -d "${TF_AWS_DIR}/.terraform" ]]; then
  pushd "${TF_AWS_DIR}" >/dev/null
  TF_RESOURCES="$(terraform state list 2>/dev/null)"
  popd >/dev/null
  if [[ -n "${TF_RESOURCES}" ]]; then
    echo "${TF_RESOURCES}" | sed 's/^/  /'
  else
    echo "  <empty — no resources tracked>"
  fi
else
  echo "  <not initialized — run terraform init in terraform/aws first>"
fi

echo ""
echo "==================================================================="
echo " If AWS shows resources but Terraform state is empty (or vice"
echo " versa), that's drift — see the sibling GCP project's"
echo " ARCHITECTURE.md for a real incident of this kind."
echo "==================================================================="