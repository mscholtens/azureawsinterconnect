terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

# NOTE: version constraint is a starting point, not confirmed against
# actual MultiCloud SKU support. If circuit.tf's typed-resource attempt
# fails, check whether a newer azurerm version has caught up before
# falling back to the ARM template deployment escape hatch — this is a
# fast-moving feature (announced 2026-08-31).
