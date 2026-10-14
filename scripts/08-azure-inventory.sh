#!/usr/bin/env bash
# =============================================================================
# 08-azure-inventory.sh
#
# Comprehensive, read-only inventory of every Azure resource type this
# project creates, for troubleshooting. Does NOT rely on state/azure.json
# or terraform state — queries Azure directly, for the same reasons
# documented in the sibling GCP project (state files reflect what a
# script *thinks* happened, not necessarily ground truth).
#
# Usage:
#   ./scripts/08-azure-inventory.sh                # uses configured AZURE_REGION
#   ./scripts/08-azure-inventory.sh eastus westus   # check specific regions explicitly
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_cmd az jq
load_config
azure_login

REGIONS=("$@")
if [[ ${#REGIONS[@]} -eq 0 ]]; then
  REGIONS=("${AZURE_REGION}")
fi

RESOURCE_GROUP="interconnect-experiment-rg"
VNET_NAME="interconnect-experiment-vnet"
CIRCUIT_NAME="interconnect-experiment-circuit"
VM_NAME="interconnect-experiment-vm"
GATEWAY_NAME="interconnect-experiment-ergw"

print_row() {
  printf "  %-28s %s\n" "$1:" "${2:-<none>}"
}

echo "==================================================================="
echo " Azure resource inventory — aws-azure-interconnect-experiment"
echo " Regions checked: ${REGIONS[*]}"
echo "==================================================================="

RG_STATE="$(azure_rg_state "${RESOURCE_GROUP}")"
case "${RG_STATE}" in
  present) RG_EXISTS="true" ;;
  absent)  RG_EXISTS="false" ;;
  *)
    print_row "Resource group exists" "UNKNOWN (az/auth problem — check the portal)"
    echo "Cannot determine the resource group state; not reporting it as clean." >&2
    exit 1
    ;;
esac
print_row "Resource group exists" "${RG_EXISTS}"

if [[ "${RG_EXISTS}" != "true" ]]; then
  echo ""
  echo "Resource group ${RESOURCE_GROUP} does not exist — nothing else to check."
else
  VNET="$(az network vnet show --name "${VNET_NAME}" --resource-group "${RESOURCE_GROUP}" \
    --query "name" -o tsv 2>/dev/null)"
  print_row "VNet" "${VNET:-<none>}"

  SUBNETS="$(az network vnet subnet list --vnet-name "${VNET_NAME}" --resource-group "${RESOURCE_GROUP}" \
    --query "[].name" -o tsv 2>/dev/null | tr '\n' ' ')"
  print_row "Subnets" "${SUBNETS:-<none>}"

  NSG="$(az network nsg show --name "interconnect-experiment-nsg" --resource-group "${RESOURCE_GROUP}" \
    --query "name" -o tsv 2>/dev/null)"
  print_row "NSG" "${NSG:-<none>}"

  VM_STATE="$(az vm show --name "${VM_NAME}" --resource-group "${RESOURCE_GROUP}" -d \
    --query "powerState" -o tsv 2>/dev/null)"
  print_row "VM" "${VM_NAME} (${VM_STATE:-<none>})"

  PIPS="$(az network public-ip list --resource-group "${RESOURCE_GROUP}" \
    --query "[].{name:name,ip:ipAddress}" -o tsv 2>/dev/null | tr '\n' '; ')"
  print_row "Public IPs" "${PIPS:-<none>}"

  GATEWAY_STATE="$(az network vnet-gateway show --name "${GATEWAY_NAME}" --resource-group "${RESOURCE_GROUP}" \
    --query "provisioningState" -o tsv 2>/dev/null)"
  print_row "ExpressRoute Gateway" "${GATEWAY_NAME} (${GATEWAY_STATE:-<none>})"

  GW_CONNECTIONS="$(az network vpn-connection list --resource-group "${RESOURCE_GROUP}" \
    --query "[].join(' ', [name, provisioningState])" -o tsv 2>/dev/null | tr '\n' ' ')"
  print_row "Gateway Connections" "${GW_CONNECTIONS:-<none>}"

  CIRCUIT_JSON="$(az network express-route show --name "${CIRCUIT_NAME}" --resource-group "${RESOURCE_GROUP}" \
    --output json 2>/dev/null)"
  if [[ -n "${CIRCUIT_JSON}" ]]; then
    CIRCUIT_STATE="$(echo "${CIRCUIT_JSON}" | jq -r '.circuitProvisioningState // .provisioningState // "unknown"')"
    print_row "ExpressRoute Circuit" "${CIRCUIT_NAME} (${CIRCUIT_STATE})"
  else
    print_row "ExpressRoute Circuit" "<none>"
  fi
fi

echo ""
echo "--- Local Terraform state (terraform/azure), for comparison ---"
if [[ -d "${TF_AZURE_DIR}/.terraform" ]]; then
  pushd "${TF_AZURE_DIR}" >/dev/null
  TF_RESOURCES="$(terraform state list 2>/dev/null)"
  popd >/dev/null
  if [[ -n "${TF_RESOURCES}" ]]; then
    echo "${TF_RESOURCES}" | sed 's/^/  /'
  else
    echo "  <empty — no resources tracked>"
  fi
else
  echo "  <not initialized — run terraform init in terraform/azure first>"
fi

echo ""
echo "==================================================================="
echo " If Azure shows resources but Terraform state is empty (or vice"
echo " versa), that's drift — see the sibling GCP project's"
echo " ARCHITECTURE.md for a real incident of this kind (region"
echo " mismatch silently orphaning resources)."
echo "==================================================================="