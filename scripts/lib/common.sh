#!/usr/bin/env bash
# =============================================================================
# common.sh — shared helpers sourced by every script in scripts/
# =============================================================================

set -euo pipefail

COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${COMMON_SH_DIR}/../.." && pwd)"

CONFIG_FILE="${REPO_ROOT}/config/credentials.env"
STATE_DIR="${REPO_ROOT}/state"
KEYS_DIR="${REPO_ROOT}/keys"
TF_AZURE_DIR="${REPO_ROOT}/terraform/azure"
TF_AWS_DIR="${REPO_ROOT}/terraform/aws"
SCREENSHOTS_DIR="${REPO_ROOT}/screenshots"

AZURE_STATE_FILE="${STATE_DIR}/azure.json"
AWS_STATE_FILE="${STATE_DIR}/aws.json"

COLOR_RESET='\033[0m'
COLOR_BLUE='\033[0;34m'
COLOR_YELLOW='\033[0;33m'
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'

log_info()  { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET}  $*"; }
log_warn()  { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*"; }
log_error() { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2; }
log_ok()    { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }

die() {
  log_error "$*"
  exit 1
}

require_cmd() {
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || die "Required command not found: ${cmd}"
  done
}

# --- Config loading ---
load_config() {
  [[ -f "${CONFIG_FILE}" ]] || die "Missing ${CONFIG_FILE}. See README.md."
  set -a
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
  set +a

  for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION AWS_ACCOUNT_ID \
             AZURE_SUBSCRIPTION_ID AZURE_TENANT_ID AZURE_CLIENT_ID AZURE_CLIENT_SECRET \
             AZURE_REGION AZURE_PEERING_LOCATION; do
    if [[ "${!var:-REPLACE_ME}" == "REPLACE_ME" ]]; then
      die "config/credentials.env: ${var} is still set to REPLACE_ME. Fill it in first."
    fi
  done

  export AWS_DEFAULT_REGION="${AWS_REGION}"
  # Never open a pager (less) for AWS CLI output: it blocks scripts in small terminals.
  export AWS_PAGER=""

  # Standard azurerm provider / az CLI env-based auth.
  export ARM_CLIENT_ID="${AZURE_CLIENT_ID}"
  export ARM_CLIENT_SECRET="${AZURE_CLIENT_SECRET}"
  export ARM_TENANT_ID="${AZURE_TENANT_ID}"
  export ARM_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID}"
}

# --- Azure CLI login (service principal) ---
azure_login() {
  az login --service-principal \
    -u "${AZURE_CLIENT_ID}" \
    -p "${AZURE_CLIENT_SECRET}" \
    --tenant "${AZURE_TENANT_ID}" \
    --output none
  az account set --subscription "${AZURE_SUBSCRIPTION_ID}"
}

# --- Azure resource-group helpers (via `az rest`) ---
# Why not `az group exists` / `az group delete`: on some installs the `az group`
# command family crashes with "No module named
# 'azure.mgmt.resource.resources.v2024_11_01'" (partially upgraded CLI). A
# crash prints nothing, which callers misread as "does not exist". `az rest`
# does not use that module, and these helpers return an explicit "unknown"
# instead of guessing when the answer can't be determined.
_azure_rg_url() {
  local sub
  sub="$(az account show --query id -o tsv 2>/dev/null)" || return 1
  [[ -n "${sub}" ]] || return 1
  echo "https://management.azure.com/subscriptions/${sub}/resourcegroups/$1?api-version=2021-04-01"
}

# Prints: present | absent | unknown
azure_rg_state() {
  local url out
  url="$(_azure_rg_url "$1")" || { echo unknown; return; }
  if out="$(az rest --method get --url "${url}" --query name -o tsv 2>&1)"; then
    echo present
  elif grep -qiE 'ResourceGroupNotFound|could not be found' <<<"${out}"; then
    echo absent
  else
    echo unknown
  fi
}

# Starts an asynchronous delete of the resource group and everything in it.
azure_rg_delete() {
  local url
  url="$(_azure_rg_url "$1")" || return 1
  az rest --method delete --url "${url}" --output none
}

# --- State file helpers ---
state_init() {
  local file="$1"
  [[ -f "${file}" ]] || echo '{}' > "${file}"
}

state_set() {
  local file="$1" key="$2" value="$3"
  state_init "${file}"
  local tmp
  tmp="$(mktemp)"
  jq --arg k "${key}" --arg v "${value}" '.[$k] = $v' "${file}" > "${tmp}" && mv "${tmp}" "${file}"
}

state_get() {
  local file="$1" key="$2"
  [[ -f "${file}" ]] || die "State file not found: ${file}. Did you run the 'up' scripts first?"
  local value
  value="$(jq -r --arg k "${key}" '.[$k] // empty' "${file}")"
  [[ -n "${value}" ]] || die "Key '${key}' not found in ${file}."
  echo "${value}"
}

state_clear() {
  local file="$1"
  echo '{}' > "${file}"
}

# --- SSH key helpers ---
ensure_ssh_key() {
  # ensure_ssh_key <name>  (e.g. ec2-key, azure-vm-key)
  #
  # Treats an existing-but-EMPTY key file the same as missing (checks -s,
  # not -f) — a real bug found and fixed in the sibling GCP project,
  # applied here from the start. Explicitly removes any existing files
  # before regenerating, since ssh-keygen refuses to overwrite an
  # existing file without an interactive prompt that would hang this
  # script.
  local name="$1"
  local priv="${KEYS_DIR}/${name}"
  local pub="${KEYS_DIR}/${name}.pub"

  if [[ -s "${priv}" && -s "${pub}" ]]; then
    log_info "SSH key ${name} already exists, reusing."
  else
    log_info "Generating SSH key ${name}..."
    rm -f "${priv}" "${pub}"
    ssh-keygen -t ed25519 -N "" -f "${priv}" -C "${name}-interconnect-experiment" >/dev/null
    chmod 600 "${priv}"
  fi

  if [[ ! -s "${pub}" ]]; then
    die "${pub} is still empty after attempting to generate it. Check that ssh-keygen is installed and working: ssh-keygen -t ed25519 -f /tmp/test-key"
  fi
}

# --- Generic poll-until-condition loop ---
wait_until() {
  local description="$1" timeout="$2" interval="$3"
  shift 3
  local elapsed=0
  log_info "Waiting for: ${description} (timeout ${timeout}s)"
  until "$@"; do
    if (( elapsed >= timeout )); then
      die "Timed out after ${timeout}s waiting for: ${description}"
    fi
    sleep "${interval}"
    elapsed=$(( elapsed + interval ))
    log_info "  ...still waiting (${elapsed}s elapsed)"
  done
  log_ok "${description} — done."
}

# --- tfvars conflict guard ---
# terraform.tfvars, if present, silently overrides TF_VAR_* environment
# variables — a real bug hit in the GCP project (a stale terraform.tfvars
# caused a placeholder value to silently override the real looked-up
# value). Applied here proactively.
check_no_tfvars_conflict() {
  local dir="$1"
  local found=()
  [[ -f "${dir}/terraform.tfvars" ]] && found+=("terraform.tfvars")
  [[ -f "${dir}/terraform.tfvars.json" ]] && found+=("terraform.tfvars.json")
  while IFS= read -r -d '' f; do
    found+=("$(basename "${f}")")
  done < <(find "${dir}" -maxdepth 1 -name '*.auto.tfvars' -print0 2>/dev/null)

  if [[ ${#found[@]} -gt 0 ]]; then
    die "Found $(IFS=,; echo "${found[*]}") in ${dir} — these SILENTLY OVERRIDE the TF_VAR_* values this script computes. Remove or rename them first, e.g.: mv ${dir}/terraform.tfvars ${dir}/terraform.tfvars.bak"
  fi
}

mkdir -p "${STATE_DIR}" "${KEYS_DIR}" "${SCREENSHOTS_DIR}"