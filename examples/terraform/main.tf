# Primed Hardened Runner (Ubuntu) - one runner VM, registered at first boot by cloud-init.
# Same VM settings as docs/QUICKSTART.md Step 2 and the same registration as Steps R1 to R4(a).
# The registration credential never passes through Terraform or its state: you put it in the
# vault yourself between the two applies (see ../README.md).

terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.81"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
}

variable "subscription_id" {
  type        = string
  description = "Subscription to deploy the runner into."
}

variable "image_id" {
  type        = string
  description = "Resource ID of the image version: <IMAGE_ID>"
}

variable "location" {
  type        = string
  default     = "southcentralus"
  description = "Must be a region the image version is replicated to."
}

variable "resource_group_name" {
  type    = string
  default = "rg-my-runners"
}

variable "vm_name" {
  type    = string
  default = "runner-01"
}

variable "vm_size" {
  type        = string
  default     = "Standard_D4ads_v7"
  description = "The size the image is built and tested on."
}

variable "admin_ssh_public_key" {
  type        = string
  description = "An SSH public key. Azure requires one. The image's firewall allows SSH (Ubuntu 1.0.3 and earlier: it does not); your network decides who can reach it."
}

variable "key_vault_name" {
  type        = string
  description = "Globally unique, 3-24 characters, a-z 0-9 -. Holds only this runner's registration credential."
}

variable "secret_name" {
  type    = string
  default = "runner-01-reg"
}

variable "platform" {
  type        = string
  description = "github or azdo"
  validation {
    condition     = contains(["github", "azdo"], var.platform)
    error_message = "platform must be github or azdo."
  }
}

variable "url" {
  type        = string
  description = "https://github.com/<owner>[/<repo>] or https://dev.azure.com/<org>"
}

variable "labels" {
  type        = list(string)
  default     = ["self-hosted", "linux", "x64", "primed-hardened"]
  description = "GitHub only."
}

variable "pool" {
  type        = string
  default     = "Default"
  description = "Azure DevOps only."
}

variable "deploy_vm" {
  type        = bool
  default     = false
  description = "Leave false for the first apply; set true once the credential is in the vault."
}

variable "attach_identity" {
  type        = bool
  default     = true
  description = "Set false and apply again once the runner is online (QUICKSTART Step R6)."
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "runner" {
  name     = var.resource_group_name
  location = var.location
}

# --- Identity and vault (QUICKSTART Step R1) ---

resource "azurerm_user_assigned_identity" "runner" {
  name                = "mi-${var.vm_name}"
  resource_group_name = azurerm_resource_group.runner.name
  location            = azurerm_resource_group.runner.location
}

resource "azurerm_key_vault" "runner" {
  name                       = var.key_vault_name
  resource_group_name        = azurerm_resource_group.runner.name
  location                   = azurerm_resource_group.runner.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
}

# The VM's identity may read secrets in this one vault and nothing else.
resource "azurerm_role_assignment" "runner_reads_secret" {
  scope                = azurerm_key_vault.runner.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.runner.principal_id
  principal_type       = "ServicePrincipal"
}

# You (whoever runs Terraform) may write the credential into the vault.
resource "azurerm_role_assignment" "operator_writes_secret" {
  scope                = azurerm_key_vault.runner.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# --- Network: no public IP, no inbound rule (QUICKSTART Step 2) ---

resource "azurerm_virtual_network" "runner" {
  name                = "vnet-${var.vm_name}"
  resource_group_name = azurerm_resource_group.runner.name
  location            = azurerm_resource_group.runner.location
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "runner" {
  name                 = "default"
  resource_group_name  = azurerm_resource_group.runner.name
  virtual_network_name = azurerm_virtual_network.runner.name
  address_prefixes     = ["10.0.0.0/24"]
}

resource "azurerm_network_security_group" "runner" {
  name                = "nsg-${var.vm_name}"
  resource_group_name = azurerm_resource_group.runner.name
  location            = azurerm_resource_group.runner.location
}

resource "azurerm_network_interface" "runner" {
  name                = "nic-${var.vm_name}"
  resource_group_name = azurerm_resource_group.runner.name
  location            = azurerm_resource_group.runner.location

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.runner.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_security_group_association" "runner" {
  network_interface_id      = azurerm_network_interface.runner.id
  network_security_group_id = azurerm_network_security_group.runner.id
}

# --- Registration config: facts only, no credential (QUICKSTART Steps R3 and R4a) ---

locals {
  runner_config = {
    for k, v in {
      platform           = var.platform
      url                = var.url
      agent_name         = var.vm_name
      token_source       = "vault"
      token_secret_id    = "${azurerm_key_vault.runner.vault_uri}secrets/${var.secret_name}"
      identity_client_id = azurerm_user_assigned_identity.runner.client_id
      labels             = var.platform == "github" ? var.labels : null
      pool               = var.platform == "azdo" ? var.pool : null
    } : k => v if v != null
  }

  cloud_init = join("\n", [
    "#cloud-config",
    yamlencode({
      write_files = [{
        path        = "/etc/primed/runner-config.json"
        permissions = "0600"
        owner       = "root:root"
        encoding    = "b64"
        content     = base64encode(jsonencode(local.runner_config))
      }]
    }),
  ])
}

# --- The VM (QUICKSTART Step 2) ---

resource "azurerm_linux_virtual_machine" "runner" {
  count = var.deploy_vm ? 1 : 0

  name                  = var.vm_name
  resource_group_name   = azurerm_resource_group.runner.name
  location              = azurerm_resource_group.runner.location
  size                  = var.vm_size
  network_interface_ids = [azurerm_network_interface.runner.id]
  source_image_id       = var.image_id

  # Trusted Launch: the boot configuration the image is built, scanned and tested under.
  secure_boot_enabled = true
  vtpm_enabled        = true

  admin_username                  = "azureuser"
  disable_password_authentication = true
  admin_ssh_key {
    username   = "azureuser"
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  custom_data = base64encode(local.cloud_init)

  dynamic "identity" {
    for_each = var.attach_identity ? [1] : []
    content {
      type         = "UserAssigned"
      identity_ids = [azurerm_user_assigned_identity.runner.id]
    }
  }

  depends_on = [
    azurerm_role_assignment.runner_reads_secret,
    azurerm_network_interface_security_group_association.runner,
  ]
}

output "secret_id" {
  value       = "${azurerm_key_vault.runner.vault_uri}secrets/${var.secret_name}"
  description = "A URL, not a credential."
}

output "key_vault_name" {
  value = azurerm_key_vault.runner.name
}
