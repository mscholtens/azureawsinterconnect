# -----------------------------------------------------------------------
# ExpressRoute Gateway + Gateway Connection.
#
# CONFIRMED required per Microsoft's own FAQ: "Traffic entering Azure
# over the interconnect uses an ExpressRoute virtual network gateway."
# This is the Azure-side equivalent of the GCP project's mandatory VPC
# Network Peering step, or AWS's DX Gateway Association — the circuit
# alone does not connect to the VNet without this.
#
# CONFIRMED via real terraform apply error: an ExpressRoute-type gateway
# does NOT take a public IP —
#   "Error: `ip_configuration.0.public_ip_address_id` cannot be set when
#   `type` is set to `ExpressRoute`"
# This makes architectural sense too: ExpressRoute gateways connect via
# the Microsoft backbone through the circuit, not over the public
# internet, unlike VPN-type gateways which do need a public IP. The
# azurerm_public_ip resource that originally existed here has been
# removed entirely — it's not needed for this gateway type.
#
# express_route_circuit_id references circuit.tf's output.
# -----------------------------------------------------------------------

resource "azurerm_virtual_network_gateway" "this" {
  name                = "interconnect-experiment-ergw"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  type     = "ExpressRoute"
  vpn_type = "PolicyBased" # ignored for ExpressRoute type, required by schema

  # UNCONFIRMED: SKU options for an ExpressRoute gateway pairing with a
  # MultiCloud circuit specifically. "Standard" is the smallest classic
  # ExpressRoute gateway SKU — verify this is sufficient/valid once
  # testing begins; may need "ErGw1AZ" or similar if Standard is
  # rejected or deprecated for new deployments.
  sku = "Standard"

  ip_configuration {
    name                          = "default"
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.gateway.id
  }

  # CONFIRMED ordering fix, found the hard way across many failed runs:
  # Azure SERIALIZES changes to a VNet while a gateway is being
  # provisioned into it, so anything else touching the VNet — the VM's
  # NIC, the subnet/NSG association — queues behind the ~28-30 minute
  # gateway operation. Two consequences without this depends_on:
  #   1. The NIC can hit Terraform's ~30 minute default create timeout
  #      ("polling after CreateOrUpdate: context deadline exceeded") if
  #      the gateway runs long — this actually happened.
  #   2. Worse, the VM can't even be ATTEMPTED until its NIC exists, so
  #      every VM failure (capacity, quota, hypervisor generation) only
  #      surfaced AFTER the full gateway wait, even though Azure could
  #      have rejected it in seconds. Six VM-size failures each cost a
  #      ~28 minute wait for this reason alone.
  # Making the gateway depend on the VM inverts that: the cheap,
  # failure-prone resource goes first, so any VM problem surfaces in
  # under a minute — and because Terraform won't start a resource whose
  # dependency failed, the 28-minute gateway never starts on a failed
  # attempt. depends_on is pure graph ordering; adding it to an
  # already-created gateway does NOT force it to be recreated.
  depends_on = [azurerm_linux_virtual_machine.this]
}

resource "azurerm_virtual_network_gateway_connection" "this" {
  name                = "interconnect-experiment-ergw-connection"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  type                       = "ExpressRoute"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.this.id
  express_route_circuit_id   = local.express_route_circuit_id
}
