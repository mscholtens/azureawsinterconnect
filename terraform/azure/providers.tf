# Credentials picked up from the environment (ARM_CLIENT_ID,
# ARM_CLIENT_SECRET, ARM_TENANT_ID, ARM_SUBSCRIPTION_ID), exported by
# scripts/lib/common.sh from config/credentials.env's AZURE_* fields. No
# credentials hardcoded here.

provider "azurerm" {
  features {}
}
