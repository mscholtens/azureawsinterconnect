#!/usr/bin/env bash
# =============================================================================
# 07-down-azure.sh
#
# Tears down the Azure half. Run AFTER 06-down-aws.sh.
#
# DEFAULT STRATEGY (changed after a real run): delete the RESOURCE GROUP
# directly through the ARM API, then wipe Terraform's local state.
#
# Why not `terraform destroy` first: in a real run it spent its full 30 minute
# provider timeout on the gateway connection ("polling after Delete: context
# deadline exceeded"), errored anyway, and the script then had to delete the
# resource group regardless. It also fails on the circuit's ARM template
# deployment ("properties.OutputResources was nil"). Deleting the resource
# group is the one operation that always has to succeed, and Azure orders the
# child deletions itself. Nothing is lost: everything lives in this group.
#
# To use the old behaviour (terraform destroy first, RG delete as fallback):
#   USE_TERRAFORM_DESTROY=1 ./scripts/07-down-azure.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_cmd az terraform jq
load_config
check_no_tfvars_conflict "${TF_AZURE_DIR}"

azure_login

RG_NAME="interconnect-experiment-rg"

pushd "${TF_AZURE_DIR}" >/dev/null
terraform init -input=false >/dev/null
RESOURCE_COUNT="$(terraform state list 2>/dev/null | wc -l | tr -d ' ')"
popd >/dev/null

# NOTE: no early exit on an empty Terraform state any more. Earlier runs left
# the resource group behind in exactly that case (e.g. after `terraform state
# rm`, or when a resource was created in Azure but never recorded in state).
# The resource-group check in step 2 always runs.

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

if [[ "${USE_TERRAFORM_DESTROY:-0}" == "1" && "${RESOURCE_COUNT}" != "0" ]]; then
  log_info "=== Step 1/3: terraform destroy (terraform/azure) — USE_TERRAFORM_DESTROY=1 ==="
  pushd "${TF_AZURE_DIR}" >/dev/null
  terraform destroy -auto-approve -input=false \
    || log_warn "terraform destroy reported errors — falling back to deleting the resource group directly."
  popd >/dev/null
else
  log_info "=== Step 1/3: skipped terraform destroy (default; deleting the resource group directly) ==="
fi

log_info "=== Step 2/3: Delete the resource group and wait until it is gone ==="

# Prints a compact summary of what is still present, e.g.
#   "6 left: connections, expressRouteCircuits, virtualNetworkGateways, ..."
rg_remaining() {
  local sub types
  sub="$(az account show --query id -o tsv 2>/dev/null)" || return 0
  types="$(az rest --method get \
    --url "https://management.azure.com/subscriptions/${sub}/resourceGroups/${RG_NAME}/resources?api-version=2021-04-01" \
    --query "value[].type" -o tsv 2>/dev/null | sed 's|.*/||' | sort -u | paste -sd, - | sed 's/,/, /g')"
  if [[ -z "${types}" ]]; then echo "nothing listed (finalizing)"; else echo "${types}"; fi
}

fmt_elapsed() { printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); }

case "$(azure_rg_state "${RG_NAME}")" in
  absent)
    ;;
  present|unknown)
    if [[ "$(azure_rg_state "${RG_NAME}")" == "unknown" ]]; then
      die "Could not determine whether resource group ${RG_NAME} exists (az / auth problem). NOT assuming it is gone — check the Azure portal."
    fi
    log_info "Requesting deletion of ${RG_NAME} (the gateway and circuit make this slow: 10-40 min is normal)."
    azure_rg_delete "${RG_NAME}" || die "Could not start deletion of ${RG_NAME}. Delete it in the Azure portal."
    _elapsed=0
    _max=3600
    while true; do
      _st="$(azure_rg_state "${RG_NAME}")"
      [[ "${_st}" == "absent" ]] && break
      if (( _elapsed >= _max )); then
        die "${RG_NAME} still exists after $(( _max / 60 )) min (state: ${_st}). The delete request is already submitted; re-run this script to keep waiting, or check the portal. Left: $(rg_remaining)"
      fi
      log_info "  [$(fmt_elapsed "${_elapsed}")] still deleting — left: $(rg_remaining)"
      sleep 30
      _elapsed=$(( _elapsed + 30 ))
    done
    ;;
esac
log_ok "Resource group ${RG_NAME} is gone."

# Terraform's local state may still list resources that no longer exist.
# Clear it so the next 01-azure-up.sh starts truly clean.
pushd "${TF_AZURE_DIR}" >/dev/null
for r in $(terraform state list 2>/dev/null); do terraform state rm "$r" >/dev/null 2>&1 || true; done
popd >/dev/null

log_info "=== Step 3/3: Clear state/azure.json ==="
state_clear "${AZURE_STATE_FILE}"

log_ok "Azure half torn down."
log_info "Run ./scripts/03-status.sh and the inventory scripts once more to confirm nothing is left active."