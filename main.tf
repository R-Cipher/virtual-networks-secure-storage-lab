# main.tf -- providers first, then the resources
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.100" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
}
provider "azurerm" {
  features {} # required empty features block
}

# Resource group: container for the whole network + storage topology
resource "azurerm_resource_group" "rg" {
  name     = "rg-${var.prefix}"
  location = var.location
}

# Virtual network: the private 10.0.0.0/16 space we split into subnets
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-${var.prefix}"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

# Workload subnet: where app/test VMs run
resource "azurerm_subnet" "workload" {
  name                 = "workload"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Endpoints subnet: dedicated to private endpoints (best practice)
resource "azurerm_subnet" "endpoints" {
  name                 = "private-endpoints"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]
}

# NSG: stateful firewall; here it allows only SSH from your IP
resource "azurerm_network_security_group" "nsg" {
  name                = "nsg-${var.prefix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  security_rule {
    name                       = "Allow-SSH"
    priority                   = 100 # lower number = evaluated first
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"           # SSH
    source_address_prefix      = var.my_ip_cidr # your IP, set in tfvars
    destination_address_prefix = "*"
  }
}

# Bind the NSG to the workload subnet so its rules take effect there
resource "azurerm_subnet_network_security_group_association" "assoc" {
  subnet_id                 = azurerm_subnet.workload.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# Random suffix keeps the globally-unique storage name from colliding
resource "random_string" "s" {
  length  = 6
  special = false
  upper   = false
}

# Storage account with its PUBLIC door shut -- the key hardening step
resource "azurerm_storage_account" "sa" {
  name                          = "sta${var.prefix}${random_string.s.result}"
  resource_group_name           = azurerm_resource_group.rg.name
  location                      = azurerm_resource_group.rg.location
  account_tier                  = "Standard"
  account_replication_type      = "LRS"
  public_network_access_enabled = false # no public internet access
}

# Private DNS zone: makes the storage hostname resolve to a private IP
resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
}

# Link the zone to the VNet so in-network lookups use it
resource "azurerm_private_dns_zone_virtual_network_link" "link" {
  name                  = "blob-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

# Private endpoint: a private IP in the endpoints subnet for the storage
resource "azurerm_private_endpoint" "pe" {
  name                = "pe-storage"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.endpoints.id
  private_service_connection {
    name                           = "psc-blob"
    private_connection_resource_id = azurerm_storage_account.sa.id
    subresource_names              = ["blob"] # which storage service
    is_manual_connection           = false
  }
  private_dns_zone_group {
    name                 = "blob-zone"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
  }
}

# Network interface: connects the VM to the subnet with a private IP
resource "azurerm_network_interface" "nic" {
  name                = "nic-${var.prefix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.workload.id
    private_ip_address_allocation = "Dynamic" # Azure assigns the IP
    public_ip_address_id          = azurerm_public_ip.vm_pip.id
  }
}

# VM inside the network in order to test connectivity to storage account
resource "azurerm_linux_virtual_machine" "vm" {
  name                  = "vm-${var.prefix}"
  resource_group_name   = azurerm_resource_group.rg.name
  location              = azurerm_resource_group.rg.location
  size                  = "Standard_E2s_v3" # smallest burstable size; cheap ***edit*** switched to E as subscription didn't allow B,D
  admin_username        = "azureuser"
  network_interface_ids = [azurerm_network_interface.nic.id]
  admin_ssh_key {
    username   = "azureuser"
    public_key = file(pathexpand("~/.ssh/id_rsa.pub")) # your local public key
  }
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS" # locally redundant managed disk
  }
  source_image_reference { # which OS image to boot
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}

# public ip to ssh into VM
resource "azurerm_public_ip" "vm_pip" {
  name                = "pip-${var.prefix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}