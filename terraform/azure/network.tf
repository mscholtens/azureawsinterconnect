resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.azure_region
}

resource "azurerm_virtual_network" "this" {
  name                = "interconnect-experiment-vnet"
  address_space       = [var.vnet_cidr]
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_subnet" "this" {
  name                 = "interconnect-experiment-subnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_cidr]
}

# CONFIRMED naming requirement (not a project convention): Azure requires
# this subnet to be named literally "GatewaySubnet" for a Virtual Network
# Gateway to be deployable into it.
resource "azurerm_subnet" "gateway" {
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.gateway_subnet_cidr]
}

# CONFIRMED conceptually required: Azure NSGs default-deny inbound,
# unlike AWS security groups (also explicit, already handled in the
# sibling project) — explicit rules needed here too.
resource "azurerm_network_security_group" "this" {
  name                = "interconnect-experiment-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  security_rule {
    name                       = "AllowSSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.allowed_ssh_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowICMPFromAWS"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Icmp"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.peer_cidr
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "this" {
  subnet_id                 = azurerm_subnet.this.id
  network_security_group_id = azurerm_network_security_group.this.id
}

# NOTE: the GatewaySubnet intentionally has NO NSG association — Azure
# does not support associating an NSG with a GatewaySubnet.
