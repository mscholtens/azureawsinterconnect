variable "azure_region" {
  description = "Azure region. Must pair with the AWS region (preview list: australiaeast, eastus, germanywestcentral, westus). Default pairing: eastus <-> AWS us-east-1."
  type        = string
}

variable "resource_group_name" {
  type    = string
  default = "interconnect-experiment-rg"
}

variable "vnet_cidr" {
  type    = string
  default = "10.2.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR for the VM's subnet (NOT the GatewaySubnet — see gateway_subnet_cidr)."
  type        = string
  default     = "10.2.1.0/24"
}

variable "gateway_subnet_cidr" {
  description = "CIDR for the dedicated GatewaySubnet. Azure requires this subnet to be literally named 'GatewaySubnet' — enforced in network.tf, not just a naming convention."
  type        = string
  default     = "10.2.255.0/27"
}

variable "vm_size" {
  description = "VM size. Standard_D2s_v4 chosen because it is UNRESTRICTED for this subscription in eastus (Standard_D2s_v3 shows NotAvailableForSubscription there) and its DSv4 family has quota 10. Before changing, check ALL THREE gates: (1) restrictions: az vm list-skus --location eastus --size <SIZE> --all (restrictions must be empty), (2) quota: az vm list-usage --location eastus, (3) live capacity, which neither shows. scripts/01-azure-up.sh preflight checks gate 1."
  type        = string
  default     = "Standard_D2s_v4"
}

variable "ssh_public_key_path" {
  description = "Path to the public key (keys/azure-vm-key.pub) to install on the VM."
  type        = string
}

variable "admin_username" {
  type    = string
  default = "azureuser"
}

variable "peer_cidr" {
  description = "CIDR block of the peer (AWS) VPC, allowed for ICMP in the NSG."
  type        = string
  default     = "10.0.0.0/16"
}

variable "allowed_ssh_cidr" {
  type    = string
  default = "0.0.0.0/0"
}

variable "aws_account_id" {
  description = "AWS account ID that is authorized to redeem this circuit's activation key — becomes the circuit's partner_account_id/partnerAccountId. CONFIRMED required per the working Bicep example (ARCHITECTURE.md)."
  type        = string
}

variable "peering_location" {
  description = "ExpressRoute peering location for the MultiCloud circuit. NOT the same as azure_region. UNCONFIRMED exact accepted value/format for this SKU — see ARCHITECTURE.md's open questions. The one working example used 'useast', an unusual-looking value compared to classic ExpressRoute peering location names."
  type        = string
}

variable "circuit_bandwidth_mbps" {
  description = "Preview cap is 1000 (1 Gbps), matching the AWS side."
  type        = number
  default     = 1000
}
