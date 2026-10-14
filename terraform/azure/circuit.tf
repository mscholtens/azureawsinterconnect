# -----------------------------------------------------------------------
# ExpressRoute Circuit, sku.tier = "MultiCloud" — the actual cross-cloud
# link.
#
# CONFIRMED (real terraform apply error, not a guess): the typed
# azurerm_express_route_circuit resource does NOT support
# partner_account_id —
#   "Error: Unsupported argument ... An argument named
#   "partner_account_id" is not expected here."
# This settles failure mode #1 predicted in the original version of this
# file. Using the ARM template deployment fallback instead, which
# mirrors the confirmed-working Bicep shape from ARCHITECTURE.md exactly
# — this bypasses the typed resource's schema entirely, so the
# sku.tier="MultiCloud" enum-validation question (failure mode #2) is
# moot; ARM template deployments aren't subject to the provider's
# client-side attribute validation.
# -----------------------------------------------------------------------

resource "azurerm_resource_group_template_deployment" "circuit" {
  name                = "interconnect-experiment-circuit-deployment"
  resource_group_name = azurerm_resource_group.this.name
  deployment_mode     = "Incremental"

  template_content = jsonencode({
    "$schema"      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
    contentVersion = "1.0.0.0"
    resources = [
      {
        type       = "Microsoft.Network/expressRouteCircuits"
        apiVersion = "2024-07-01"
        name       = "interconnect-experiment-circuit"
        location   = azurerm_resource_group.this.location
        sku = {
          name   = "MultiCloud_MeteredData"
          tier   = "MultiCloud"
          family = "MeteredData"
        }
        properties = {
          serviceProviderProperties = {
            serviceProviderName = "AWS"
            peeringLocation     = var.peering_location
            bandwidthInMbps     = var.circuit_bandwidth_mbps
          }
          partnerAccountId = var.aws_account_id
        }
      }
    ]
  })

  # The template is deliberately NOT re-applied after the first create.
  # Why: (1) Azure normalizes template output types, so any template with
  # an `outputs` block shows a perpetual diff; (2) every re-apply re-PUTs
  # the circuit, and the deployment's outputs come back EMPTY ("{}") on
  # re-runs, which broke everything reading output_content. Edit the
  # template => destroy and recreate the circuit instead.
  lifecycle {
    ignore_changes = [template_content]
  }
}

locals {
  # Deterministic circuit ID, derived from the deployment's own ID so
  # Terraform still sees the dependency (gateway connection waits for the
  # circuit). Deliberately NOT read from the deployment's outputs: they are
  # empty on any re-apply (see lifecycle note above).
  express_route_circuit_id = replace(
    azurerm_resource_group_template_deployment.circuit.id,
    "/providers/Microsoft.Resources/deployments/interconnect-experiment-circuit-deployment",
    "/providers/Microsoft.Network/expressRouteCircuits/interconnect-experiment-circuit"
  )
}

# -----------------------------------------------------------------------
# ORIGINAL ATTEMPT — kept for the record, confirmed non-working.
# Do not re-enable without also re-verifying partner_account_id has been
# added to the provider in a newer azurerm version.
# -----------------------------------------------------------------------

# resource "azurerm_express_route_circuit" "this" {
#   name                = "interconnect-experiment-circuit"
#   location            = azurerm_resource_group.this.location
#   resource_group_name = azurerm_resource_group.this.name
#
#   service_provider_name = "AWS"
#   peering_location       = var.peering_location
#   bandwidth_in_mbps      = var.circuit_bandwidth_mbps
#
#   sku {
#     tier   = "MultiCloud"
#     family = "MeteredData"
#   }
#
#   partner_account_id = var.aws_account_id  # CONFIRMED: unsupported argument
#
#   tags = {
#     Project = "aws-azure-interconnect-experiment"
#   }
# }
