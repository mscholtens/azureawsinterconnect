resource "azurerm_public_ip" "vm" {
  name                = "interconnect-experiment-vm-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "vm" {
  name                = "interconnect-experiment-vm-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.this.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
}

resource "azurerm_linux_virtual_machine" "this" {
  name                = "interconnect-experiment-vm"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  size                = var.vm_size
  admin_username      = var.admin_username
  network_interface_ids = [
    azurerm_network_interface.vm.id,
  ]

  # NOTE: Spot pricing (priority/eviction_policy/max_bid_price) was
  # tried here as a workaround for Germany West Central's capacity
  # crunch — it draws from a separate spare-capacity pool. It didn't
  # help there, and it's unnecessary in East US, so it's been removed:
  # regular on-demand avoids any eviction risk mid-experiment. If you
  # ever hit widespread SkuNotAvailable errors again, re-adding Spot is
  # a reasonable thing to try.

  admin_ssh_key {
    username   = var.admin_username
    public_key = trimspace(file(var.ssh_public_key_path))
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  # NOTE: back to the Generation 2 SKU ("22_04-lts-gen2"). The Gen1
  # image ("22_04-lts") was only needed while trying Standard_A2_v2, a
  # legacy A-series size that can't boot Gen2. F-series (and the D/B
  # families) all support Generation 2, so the Gen2 image is correct
  # again here. If you ever switch back to an A-series size, this must
  # switch back to "22_04-lts" too — see this file's history.
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}
