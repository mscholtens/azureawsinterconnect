#!/usr/bin/env bash
# =============================================================================
# 02-aws-up.sh
#
# 1. Reads state/azure.json for the activation key.
# 2. Applies terraform/aws/ — VPC, subnet, EC2, security group, DX
#    Gateway, VGW + route propagation, and the AWS Interconnect
#    Connection, accepted via activation_key (NOT environment_id —
#    Azure initiated this time, the reverse of the sibling GCP project).
# 3. Writes state/aws.json.
# 4. Finishes the Azure side: creates the Gateway Connection that
#    01-azure-up.sh deliberately deferred, since it's confirmed blocked
#    until AWS accepts (see that script's header comment). Retries with
#    a delay to absorb any brief propagation lag. This keeps the overall
#    flow at two scripts (01, 02) rather than adding new numbered
#    scripts for what is otherwise a 3-phase dependency.
#
# Notably simpler than the GCP project's AWS-initiated equivalent: no
# `aws interconnect list-environments` lookup needed here, since AWS is
# only accepting a connection, not creating one from scratch.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_cmd aws terraform jq ssh-keygen
load_config

log_info "=== Step 1/4: Ensure SSH key for EC2 ==="
ensure_ssh_key "${SSH_KEY_NAME_AWS}"

log_info "=== Step 2/4: Read Azure state ==="
ACTIVATION_KEY="$(state_get "${AZURE_STATE_FILE}" "activation_key")"
CIRCUIT_ID="$(state_get "${AZURE_STATE_FILE}" "circuit_id")"

if [[ -z "${ACTIVATION_KEY}" || "${ACTIVATION_KEY}" == "null" ]]; then
  die "state/azure.json has no usable activation_key. Check 01-azure-up.sh's output/warnings and populate it manually if needed before retrying."
fi
log_ok "Loaded activation key for circuit ${CIRCUIT_ID}"

# Sanity check (added after AWS rejected the key with "not valid base64"):
# a classic ExpressRoute serviceKey is a GUID (hyphens -> not base64), and
# an all-zero GUID means Azure has not issued a real key. Fail here, before
# creating any AWS resources.
if [[ "${ACTIVATION_KEY}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  die "state/azure.json activation_key is a GUID (${ACTIVATION_KEY:0:8}...), i.e. the classic ExpressRoute serviceKey, not the Multicloud activation key (a long base64 string). Copy the real key from the circuit's Overview page in the Azure portal into state/azure.json (\"activation_key\") and re-run."
fi
if ! printf '%s' "${ACTIVATION_KEY}" | base64 -d >/dev/null 2>&1; then
  die "state/azure.json activation_key is not valid base64 (length ${#ACTIVATION_KEY}). Fix it in state/azure.json and re-run."
fi

log_info "=== Step 3/4: terraform apply (terraform/aws) ==="
check_no_tfvars_conflict "${TF_AWS_DIR}"

export TF_VAR_aws_region="${AWS_REGION}"
export TF_VAR_vpc_cidr="${AWS_VPC_CIDR}"
export TF_VAR_subnet_cidr="${AWS_SUBNET_CIDR}"
export TF_VAR_instance_type="${AWS_INSTANCE_TYPE}"
export TF_VAR_ssh_public_key_path="${KEYS_DIR}/${SSH_KEY_NAME_AWS}.pub"
export TF_VAR_peer_cidr="${AZURE_VNET_CIDR}"
export TF_VAR_activation_key="${ACTIVATION_KEY}"

pushd "${TF_AWS_DIR}" >/dev/null
terraform init -input=false
terraform apply -auto-approve -input=false
TF_OUT="$(terraform output -json)"
popd >/dev/null

CONNECTION_ID="$(echo "${TF_OUT}" | jq -r '.connection_id.value')"
DXGW_ID="$(echo "${TF_OUT}" | jq -r '.dxgw_id.value')"
VPC_ID="$(echo "${TF_OUT}" | jq -r '.vpc_id.value')"
EC2_INSTANCE_ID="$(echo "${TF_OUT}" | jq -r '.ec2_instance_id.value')"
EC2_PRIVATE_IP="$(echo "${TF_OUT}" | jq -r '.ec2_private_ip.value')"
EC2_PUBLIC_IP="$(echo "${TF_OUT}" | jq -r '.ec2_public_ip.value')"

log_info "=== Step 4/4: Write state/aws.json ==="
state_clear "${AWS_STATE_FILE}"
state_set "${AWS_STATE_FILE}" "region" "${AWS_REGION}"
state_set "${AWS_STATE_FILE}" "connection_id" "${CONNECTION_ID}"
state_set "${AWS_STATE_FILE}" "dxgw_id" "${DXGW_ID}"
state_set "${AWS_STATE_FILE}" "vpc_id" "${VPC_ID}"
state_set "${AWS_STATE_FILE}" "ec2_instance_id" "${EC2_INSTANCE_ID}"
state_set "${AWS_STATE_FILE}" "ec2_private_ip" "${EC2_PRIVATE_IP}"
state_set "${AWS_STATE_FILE}" "ec2_public_ip" "${EC2_PUBLIC_IP}"
state_set "${AWS_STATE_FILE}" "connection_state" "unknown"

log_ok "AWS half is up."
log_info "  Connection ID:   ${CONNECTION_ID}"
log_info "  EC2 private IP:  ${EC2_PRIVATE_IP}"
log_info "  EC2 public IP:   ${EC2_PUBLIC_IP}"

log_info "=== Step 5/5: Finish Azure Gateway Connection (deferred by 01-azure-up.sh) ==="
# CONFIRMED sequencing dependency (see 01-azure-up.sh's header comment):
# the Gateway Connection can only be created once AWS has actually
# accepted the circuit's activation key. That just happened above. There
# may be a short propagation delay before Azure's circuit reflects the
# accepted state, so this retries rather than failing on the first
# attempt.
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

# --- Wait for Azure to see AWS's acceptance, then create the connection ---
# CONFIRMED (real runs): creating the Gateway Connection while the circuit's
# cross-connection state is still "Provisioning" fails with
# ServiceProviderNotProvisioned — AND leaves a Failed stub connection in Azure
# that Terraform does not track, so every later attempt fails with "a resource
# with the ID ... already exists". Therefore: (1) wait until the circuit
# reports serviceProviderProvisioningState=Provisioned before trying, and
# (2) remove any untracked stub before each attempt.
CIRCUIT_NAME_STATE="$(state_get "${AZURE_STATE_FILE}" "circuit_name")"
RG_STATE_NAME="$(state_get "${AZURE_STATE_FILE}" "resource_group")"
CIRCUIT_NAME_STATE="${CIRCUIT_NAME_STATE:-interconnect-experiment-circuit}"
RG_STATE_NAME="${RG_STATE_NAME:-interconnect-experiment-rg}"
CONN_NAME="interconnect-experiment-ergw-connection"
SUB_ID="$(az account show --query id -o tsv)"
CONN_URL="https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${RG_STATE_NAME}/providers/Microsoft.Network/connections/${CONN_NAME}?api-version=2024-07-01"

circuit_sp_state() {
  az network express-route show --name "${CIRCUIT_NAME_STATE}" --resource-group "${RG_STATE_NAME}" \
    --query serviceProviderProvisioningState -o tsv 2>/dev/null || echo "unknown"
}

remove_stale_gateway_connection() {
  # Only remove it if Terraform does NOT track it (a tracked one is Terraform's to manage).
  if (cd "${TF_AZURE_DIR}" && terraform state list 2>/dev/null | grep -q '^azurerm_virtual_network_gateway_connection.this$'); then
    return 0
  fi
  if az rest --method get --url "${CONN_URL}" --query name -o tsv >/dev/null 2>&1; then
    log_warn "Found an untracked (failed) gateway connection stub in Azure — deleting it so Terraform can create it properly."
    az rest --method delete --url "${CONN_URL}" --output none || true
    local i
    for i in $(seq 1 30); do
      az rest --method get --url "${CONN_URL}" --query name -o tsv >/dev/null 2>&1 || return 0
      sleep 10
    done
    log_warn "Stub still present after 5 minutes — the next attempt may fail with 'already exists'."
  fi
}

log_info "Waiting for the Azure circuit to reach serviceProviderProvisioningState=Provisioned (up to 30 min)..."
for _i in $(seq 1 90); do
  _sp="$(circuit_sp_state)"
  log_info "  circuit provider state: ${_sp}"
  [[ "${_sp}" == "Provisioned" ]] && break
  sleep 20
done
if [[ "${_sp}" != "Provisioned" ]]; then
  log_warn "Circuit never reported Provisioned (last: ${_sp}). Status strings from this preview can lag — trying anyway."
fi

CONN_ATTEMPT=1
CONN_MAX_ATTEMPTS=20
CONN_OK=false
while (( CONN_ATTEMPT <= CONN_MAX_ATTEMPTS )); do
  remove_stale_gateway_connection
  pushd "${TF_AZURE_DIR}" >/dev/null
  if terraform apply -auto-approve -input=false; then
    TF_AZURE_OUT="$(terraform output -json)"
    popd >/dev/null
    CONN_OK=true
    break
  fi
  popd >/dev/null
  if (( CONN_ATTEMPT < CONN_MAX_ATTEMPTS )); then
    log_warn "Gateway Connection creation failed (attempt ${CONN_ATTEMPT}/${CONN_MAX_ATTEMPTS}) — likely still propagating AWS's acceptance. Waiting 30s and retrying..."
    sleep 30
  fi
  CONN_ATTEMPT=$(( CONN_ATTEMPT + 1 ))
done

if [[ "${CONN_OK}" == true ]]; then
  GATEWAY_CONNECTION_ID="$(echo "${TF_AZURE_OUT}" | jq -r '.gateway_connection_id.value')"
  state_set "${AZURE_STATE_FILE}" "gateway_connection_id" "${GATEWAY_CONNECTION_ID}"
  log_ok "Azure Gateway Connection created: ${GATEWAY_CONNECTION_ID}"
else
  log_warn "Gateway Connection still not created after ${CONN_MAX_ATTEMPTS} attempts over $(( CONN_MAX_ATTEMPTS * 30 ))s."
  log_warn "AWS's half succeeded and is NOT affected by this — retry manually later once propagation completes:"
  log_warn "  cd terraform/azure && terraform apply"
fi

log_warn "Run ./scripts/03-status.sh to check all sides before pinging."