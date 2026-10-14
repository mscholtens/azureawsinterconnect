#!/usr/bin/env bash
# =============================================================================
# 01-azure-up.sh
#
# 1. Logs into Azure via service principal.
# 2. Applies terraform/azure/ EXCLUDING the Gateway Connection resource
#    (azurerm_virtual_network_gateway_connection.this) — see the "CONFIRMED
#    sequencing dependency" note below for why. Everything else (VNet,
#    both subnets, NSG, VM, ExpressRoute Gateway, and the MultiCloud
#    ExpressRoute Circuit) is created here.
# 3. Extracts the activation key from the circuit.
# 4. Writes state/azure.json. gateway_connection_id is left as a
#    placeholder — scripts/02-aws-up.sh creates that resource at the end,
#    once AWS has actually accepted the connection.
#
# CONFIRMED sequencing dependency (found via a real deployment error, not
# theorized in advance): the Gateway Connection cannot be created until
# AWS has redeemed the circuit's activation key. Attempting it too early
# fails with:
#   ServiceProviderNotProvisioned: The current cross connection
#   provisioning state 'NotProvisioned' of this service key ... prevents
#   this operation.
# This is a real architectural constraint, not a bug — the circuit's
# "cross connection provisioning state" only flips once the remote party
# (AWS) accepts. Splitting the apply here, rather than adding new
# numbered scripts, keeps the script count/names the same as originally
# planned — 01 then 02, with 02 finishing the job at the end.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_cmd az terraform jq ssh-keygen
load_config

log_info "=== Step 1/5: Ensure SSH key for Azure VM ==="
ensure_ssh_key "${SSH_KEY_NAME_AZURE}"

log_info "=== Step 2/5: Azure login + VM size preflight ==="
azure_login

# PREFLIGHT (added after repeated SkuNotAvailable failures): a VM size can be
# blocked for this subscription even when quota looks fine. `az vm list-skus`
# reports that as a non-empty `restrictions` list (e.g.
# NotAvailableForSubscription). Catch it now, in seconds, instead of after
# the ~30 min gateway build. Does NOT detect live capacity shortages — only
# static restrictions.
_restrictions="$(az vm list-skus --location "${AZURE_REGION}" --size "${AZURE_VM_SIZE}" \
  --resource-type virtualMachines --all --query "[0].restrictions" -o json 2>/dev/null || echo "null")"
if [[ "${_restrictions}" == "null" || -z "${_restrictions}" ]]; then
  log_error "VM size ${AZURE_VM_SIZE} not found in ${AZURE_REGION}. Pick another AZURE_VM_SIZE in config/credentials.env."
  exit 1
elif [[ "${_restrictions}" != "[]" ]]; then
  log_error "VM size ${AZURE_VM_SIZE} is RESTRICTED for this subscription in ${AZURE_REGION}:"
  echo "${_restrictions}" | jq -r '.[] | "  - \(.reasonCode) (\(.type))"' >&2
  log_error "Unrestricted 2-vCPU sizes in ${AZURE_REGION} (still check quota: az vm list-usage --location ${AZURE_REGION}):"
  az vm list-skus --location "${AZURE_REGION}" --resource-type virtualMachines --all \
    --query "[?length(restrictions)==\`0\` && (starts_with(name,'Standard_D2') || starts_with(name,'Standard_B2') || starts_with(name,'Standard_F2') || starts_with(name,'Standard_A2'))].name" \
    -o tsv >&2 || true
  exit 1
fi
log_ok "VM size ${AZURE_VM_SIZE} has no static restrictions in ${AZURE_REGION}."

log_info "=== Step 3/5: terraform apply (terraform/azure), excluding the Gateway Connection ==="
check_no_tfvars_conflict "${TF_AZURE_DIR}"

export TF_VAR_azure_region="${AZURE_REGION}"
export TF_VAR_vnet_cidr="${AZURE_VNET_CIDR}"
export TF_VAR_subnet_cidr="${AZURE_SUBNET_CIDR}"
export TF_VAR_gateway_subnet_cidr="${AZURE_GATEWAY_SUBNET_CIDR}"
export TF_VAR_vm_size="${AZURE_VM_SIZE}"
export TF_VAR_ssh_public_key_path="${KEYS_DIR}/${SSH_KEY_NAME_AZURE}.pub"
export TF_VAR_peer_cidr="${AWS_VPC_CIDR}"
export TF_VAR_aws_account_id="${AWS_ACCOUNT_ID}"
export TF_VAR_peering_location="${AZURE_PEERING_LOCATION}"
export TF_VAR_circuit_bandwidth_mbps="${AZURE_CIRCUIT_BANDWIDTH_MBPS}"

pushd "${TF_AZURE_DIR}" >/dev/null
terraform init -input=false
terraform apply -auto-approve -input=false \
  -target=azurerm_resource_group.this \
  -target=azurerm_virtual_network.this \
  -target=azurerm_subnet.this \
  -target=azurerm_subnet.gateway \
  -target=azurerm_network_security_group.this \
  -target=azurerm_subnet_network_security_group_association.this \
  -target=azurerm_public_ip.vm \
  -target=azurerm_network_interface.vm \
  -target=azurerm_linux_virtual_machine.this \
  -target=azurerm_virtual_network_gateway.this \
  -target=azurerm_resource_group_template_deployment.circuit
TF_OUT="$(terraform output -json)"
popd >/dev/null

CIRCUIT_ID="$(echo "${TF_OUT}" | jq -r '.circuit_id.value')"
RESOURCE_GROUP="$(echo "${TF_OUT}" | jq -r '.resource_group_name.value')"
VNET_NAME="$(echo "${TF_OUT}" | jq -r '.vnet_name.value')"
SUBNET_NAME="$(echo "${TF_OUT}" | jq -r '.subnet_name.value')"
VM_ID="$(echo "${TF_OUT}" | jq -r '.vm_id.value')"
VM_PRIVATE_IP="$(echo "${TF_OUT}" | jq -r '.vm_private_ip.value')"
VM_PUBLIC_IP="$(echo "${TF_OUT}" | jq -r '.vm_public_ip.value')"
GATEWAY_ID="$(echo "${TF_OUT}" | jq -r '.gateway_id.value')"

log_info "=== Step 4/5: Fetch the activation key from the circuit ==="
CIRCUIT_NAME="interconnect-experiment-circuit"

# CONFIRMED (found via the portal's JSON View): the Multicloud activation key
# is exposed as properties.activationKey, but ONLY in ARM api-version
# 2026-05-01 (and presumably newer). Every api-version up to 2025-07-01 —
# including whatever `az network express-route show` uses — omits it, and the
# classic `serviceKey` is just a GUID. Hence a raw `az rest` call.
KEY_API_VERSION="2026-05-01"
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
CIRCUIT_URL="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Network/expressRouteCircuits/${CIRCUIT_NAME}?api-version=${KEY_API_VERSION}"

ACTIVATION_KEY="${AZURE_ACTIVATION_KEY:-}"   # manual override, if set
if [[ -z "${ACTIVATION_KEY}" ]]; then
  for attempt in 1 2 3 4 5 6; do
    ACTIVATION_KEY="$(az rest --method get --url "${CIRCUIT_URL}" \
      --query "properties.activationKey" -o tsv 2>/dev/null || true)"
    [[ -n "${ACTIVATION_KEY}" && "${ACTIVATION_KEY}" != "None" ]] && break
    ACTIVATION_KEY=""
    log_warn "activationKey not available yet (attempt ${attempt}/6) — waiting 15s..."
    sleep 15
  done
fi

# Last resort: ask for it (portal > circuit > Overview > Activation key).
if [[ -z "${ACTIVATION_KEY}" && -t 0 ]]; then
  log_warn "Could not fetch the key via api-version ${KEY_API_VERSION}."
  log_warn "Open the Azure portal > ${RESOURCE_GROUP} > ${CIRCUIT_NAME} > Overview and copy the Activation key."
  read -r -p "Paste the activation key (Enter to skip and set it later in state/azure.json): " ACTIVATION_KEY
fi
ACTIVATION_KEY="$(printf '%s' "${ACTIVATION_KEY}" | tr -d '[:space:]')"

if [[ -z "${ACTIVATION_KEY}" ]]; then
  log_warn "No activation key available. Before running 02-aws-up.sh, set it with:"
  log_warn "  jq --arg k '<KEY>' '.activation_key = \$k' state/azure.json > state/azure.json.tmp && mv state/azure.json.tmp state/azure.json"
elif ! printf '%s' "${ACTIVATION_KEY}" | base64 -d >/dev/null 2>&1; then
  log_warn "Key does not look like valid base64 — not saving it. Set it manually later (see above)."
  ACTIVATION_KEY=""
else
  log_ok "Activation key retrieved (length: ${#ACTIVATION_KEY} chars)."
fi

log_info "=== Step 5/5: Write state/azure.json ==="
state_clear "${AZURE_STATE_FILE}"
state_set "${AZURE_STATE_FILE}" "region" "${AZURE_REGION}"
state_set "${AZURE_STATE_FILE}" "resource_group" "${RESOURCE_GROUP}"
state_set "${AZURE_STATE_FILE}" "circuit_id" "${CIRCUIT_ID}"
state_set "${AZURE_STATE_FILE}" "circuit_name" "${CIRCUIT_NAME}"
state_set "${AZURE_STATE_FILE}" "activation_key" "${ACTIVATION_KEY}"
state_set "${AZURE_STATE_FILE}" "vnet_name" "${VNET_NAME}"
state_set "${AZURE_STATE_FILE}" "subnet_name" "${SUBNET_NAME}"
state_set "${AZURE_STATE_FILE}" "vm_id" "${VM_ID}"
state_set "${AZURE_STATE_FILE}" "vm_private_ip" "${VM_PRIVATE_IP}"
state_set "${AZURE_STATE_FILE}" "vm_public_ip" "${VM_PUBLIC_IP}"
state_set "${AZURE_STATE_FILE}" "gateway_id" "${GATEWAY_ID}"
state_set "${AZURE_STATE_FILE}" "gateway_connection_id" "pending-aws-acceptance"
state_set "${AZURE_STATE_FILE}" "circuit_state" "unknown"

log_ok "Azure half is up (Gateway Connection intentionally deferred)."
log_info "  Circuit ID:      ${CIRCUIT_ID}"
log_info "  VM private IP:   ${VM_PRIVATE_IP}"
log_info "  VM public IP:    ${VM_PUBLIC_IP}"
log_warn "Next: run ./scripts/02-aws-up.sh — it will accept the connection AND finish creating the Azure Gateway Connection afterward."