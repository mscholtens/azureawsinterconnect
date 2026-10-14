output "circuit_id" {
  value = local.express_route_circuit_id
}

# NOTE: there is intentionally no activation-key output. CONFIRMED: the
# Multicloud activation key is NOT returned by any ARM/CLI API version tried
# (2024-07-01 .. 2025-07-01); `serviceKey` is only the classic ExpressRoute
# GUID. The key is shown in the Azure portal (circuit > Overview) and must
# be pasted by hand — scripts/01-azure-up.sh prompts for it.

output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "vnet_name" {
  value = azurerm_virtual_network.this.name
}

output "subnet_name" {
  value = azurerm_subnet.this.name
}

output "vm_id" {
  value = azurerm_linux_virtual_machine.this.id
}

output "vm_private_ip" {
  value = azurerm_network_interface.vm.private_ip_address
}

output "vm_public_ip" {
  value = azurerm_public_ip.vm.ip_address
}

output "gateway_id" {
  value = azurerm_virtual_network_gateway.this.id
}

output "gateway_connection_id" {
  value = azurerm_virtual_network_gateway_connection.this.id
}
