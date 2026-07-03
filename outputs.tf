# outputs.tf -- handy values printed after apply
output "vnet_name" {
  value = azurerm_virtual_network.vnet.name
}

output "storage_account_name" {
  value = azurerm_storage_account.sa.name
}

output "private_endpoint_id" {
  value = azurerm_private_endpoint.pe.id
}
