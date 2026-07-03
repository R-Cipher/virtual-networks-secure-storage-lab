# variables.tf -- input declarations (values live in terraform.tfvars)
variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus"
}

variable "prefix" {
  description = "Short suffix that keeps resource names unique. Lowercase."
  type        = string
}

variable "my_ip_cidr" {
  description = "Your public IP in CIDR form, allowed for SSH in the NSG."
  type        = string
}
