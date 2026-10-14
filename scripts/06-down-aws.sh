#!/usr/bin/env bash
# =============================================================================
# 06-down-aws.sh
#
# Tears down the AWS half. Run BEFORE 07-down-azure.sh — mirrors the
# GCP project's teardown ordering logic: tear down the side that
# references/depends on the other side's resource first.
#
# Checks Terraform's OWN state (terraform state list), not
# state/aws.json, to decide whether there's anything to destroy — a
# real bug fix from the GCP project: if 02-aws-up.sh dies partway
# through, state/aws.json may never get written even though real AWS
# resources exist.
#
# Includes an automatic retry for terraform destroy (up to 3 attempts).
# The GCP project hit a confirmed AWS-side backend flakiness
# (HandlerInternalFailureException on awscc_interconnect_connection,
# referencing a missing "SharedId" field) specifically during teardown,
# shortly after the OTHER side's resources were deleted. Whether the
# same or a similar flakiness applies here is UNCONFIRMED, but the
# retry is cheap defensive practice given the precedent.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_cmd aws terraform jq
load_config
check_no_tfvars_conflict "${TF_AWS_DIR}"

pushd "${TF_AWS_DIR}" >/dev/null
terraform init -input=false >/dev/null
RESOURCE_COUNT="$(terraform state list 2>/dev/null | wc -l | tr -d ' ')"
popd >/dev/null

if [[ "${RESOURCE_COUNT}" == "0" ]]; then
  log_warn "No resources tracked in terraform/aws state — nothing to tear down. Skipping."
  state_clear "${AWS_STATE_FILE}"
  exit 0
fi

log_info "Found ${RESOURCE_COUNT} resource(s) tracked in terraform/aws state."

CONNECTION_ID="$(jq -r '.connection_id // empty' "${AWS_STATE_FILE}" 2>/dev/null || true)"

log_info "=== Step 1/3: terraform destroy (terraform/aws) ==="
export TF_VAR_aws_region="${AWS_REGION}"
export TF_VAR_vpc_cidr="${AWS_VPC_CIDR}"
export TF_VAR_subnet_cidr="${AWS_SUBNET_CIDR}"
export TF_VAR_instance_type="${AWS_INSTANCE_TYPE}"
export TF_VAR_ssh_public_key_path="${KEYS_DIR}/${SSH_KEY_NAME_AWS}.pub"
export TF_VAR_peer_cidr="${AZURE_VNET_CIDR}"
# activation_key is sensitive/write-only in intent, but terraform still
# needs *a* value to evaluate the config for destroy. Re-read from state
# if available; destroy doesn't depend on this being the "correct" live
# key, only on a value being present so the plan can be computed.
export TF_VAR_activation_key="$(jq -r '.activation_key // "unused-for-destroy"' "${AZURE_STATE_FILE}" 2>/dev/null || echo "unused-for-destroy")"

DESTROY_ATTEMPT=1
DESTROY_MAX_ATTEMPTS=3
DESTROY_OK=false
while (( DESTROY_ATTEMPT <= DESTROY_MAX_ATTEMPTS )); do
  pushd "${TF_AWS_DIR}" >/dev/null
  if terraform destroy -auto-approve -input=false; then
    popd >/dev/null
    DESTROY_OK=true
    break
  fi
  popd >/dev/null
  if (( DESTROY_ATTEMPT < DESTROY_MAX_ATTEMPTS )); then
    log_warn "terraform destroy failed (attempt ${DESTROY_ATTEMPT}/${DESTROY_MAX_ATTEMPTS}) — possibly similar AWS-side Interconnect Connection flakiness seen in the GCP project. Waiting 30s and retrying..."
    sleep 30
  fi
  DESTROY_ATTEMPT=$(( DESTROY_ATTEMPT + 1 ))
done

if [[ "${DESTROY_OK}" != true ]]; then
  die "terraform destroy failed after ${DESTROY_MAX_ATTEMPTS} attempts. If the error mentions AWS::Interconnect::Connection, wait a minute and retry manually: cd terraform/aws && terraform destroy"
fi

log_info "=== Step 2/3: Safety check — confirm connection is actually gone ==="
if [[ -n "${CONNECTION_ID}" ]]; then
  if aws interconnect get-connection --identifier "${CONNECTION_ID}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    log_warn "Connection ${CONNECTION_ID} still exists after terraform destroy — deleting explicitly."
    aws interconnect delete-connection --identifier "${CONNECTION_ID}" --region "${AWS_REGION}"
  else
    log_ok "Connection ${CONNECTION_ID} confirmed gone."
  fi
else
  log_warn "No connection_id known — skipping the explicit safety check. Verify manually: aws interconnect list-connections --region ${AWS_REGION}"
fi

log_info "=== Step 3/3: Clear state/aws.json ==="
state_clear "${AWS_STATE_FILE}"

log_ok "AWS half torn down."