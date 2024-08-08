terraform {
  required_providers {
    azapi = {
      source  = "azure/azapi"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
    }
    random = {
      source  = "hashicorp/random"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }
}

provider "azapi" {
}

data "azurerm_client_config" "current" {}

resource "random_string" "random_suffix" {
  length  = 4
  special = false
  upper   = false
  keepers = {
    resource_group_name = var.resource_group_name
  }
}

resource "azurerm_resource_group" "rg" {
  name     = "${var.resource_group_name}-${random_string.random_suffix.result}"
  location = var.region
}

resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-demo-${random_string.random_suffix.result}"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "subnet1" {
  name                 = "default-snet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "subnet2" {
  name                 = "privatelink-snet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]
}

# Creates user assigned identity for Key Vault access
resource "azurerm_user_assigned_identity" "cosmosuseridentity" {
  location            = azurerm_resource_group.rg.location
  name                = "cosmos-identity-${random_string.random_suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_key_vault" "kv" {
  name                        = "kv-security-demo-${random_string.random_suffix.result}"
  location                    = azurerm_resource_group.rg.location
  resource_group_name         = azurerm_resource_group.rg.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days  = 7
  purge_protection_enabled    = true
  enable_rbac_authorization   = true
  sku_name = "standard"

  network_acls {
    bypass = "None" # "AzureServices" option could be used to grant access to Trusted Azure Services
    default_action = "Deny"
    ip_rules = [ "0.0.0.0/0" ] # Add Cosmos Public IP ranges of provisioned regions (https://www.microsoft.com/en-us/download/details.aspx?id=56519)
  }
}

resource "azurerm_role_assignment" "cosmoskvpermission" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_user_assigned_identity.cosmosuseridentity.principal_id
}

resource "azurerm_role_assignment" "deploykvpermission" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Crypto Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Creates a key in Key Vault (CMK)
resource "azurerm_key_vault_key" "key" {
  name         = "cosmos-cmk"
  key_vault_id = azurerm_key_vault.kv.id
  key_type     = "RSA"
  key_size     = 2048

  key_opts = [
    "decrypt",
    "encrypt",
    "sign",
    "unwrapKey",
    "verify",
    "wrapKey",
  ]

  rotation_policy {
    automatic {
      time_before_expiry = "P30D"
    }

    expire_after         = "P90D"
    notify_before_expiry = "P29D"
  }

  depends_on = [ azurerm_role_assignment.deploykvpermission ]
}

resource "azurerm_log_analytics_workspace" "log" {
  name                = "la-cosmos-audit-${random_string.random_suffix.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
}

resource "azurerm_cosmosdb_account" "db" {
  name                = "cosmos-security-demo-${random_string.random_suffix.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"
  key_vault_key_id = azurerm_key_vault_key.key.versionless_id
  local_authentication_disabled = true # Disabling local key authentication
  public_network_access_enabled = false # Disabling public network access
  access_key_metadata_writes_enabled = false # Disabling access key metadata writes
  default_identity_type = join("=", ["UserAssignedIdentity", azurerm_user_assigned_identity.cosmosuseridentity.id])
  minimal_tls_version = "Tls12"

  consistency_policy {
    consistency_level       = "BoundedStaleness"
    max_interval_in_seconds = 300
    max_staleness_prefix    = 100000
  }

  identity {
    type = "UserAssigned"
    identity_ids = [ azurerm_user_assigned_identity.cosmosuseridentity.id ]
  }

  backup {
    type = "Continuous"
  }

  geo_location {
    location          = azurerm_resource_group.rg.location
    failover_priority = 0
  }

  depends_on = [ azurerm_role_assignment.cosmoskvpermission ]
}

# Optional to be able to see full text queries in the logs
resource "azapi_update_resource" "cosmosextra" {
  type        = "Microsoft.DocumentDB/databaseAccounts@2024-05-15-preview"
  resource_id = azurerm_cosmosdb_account.db.id

  body = jsonencode({
    properties = {
      diagnosticLogSettings = {
        enableFullTextQuery = "True"
      }
    }
  })
}

# Required for auditing and monitoring
resource "azurerm_monitor_diagnostic_setting" "cosmosdb_diagnostic" {
  name               = "cosmosdb-diagnostic"
  target_resource_id = azurerm_cosmosdb_account.db.id

  log_analytics_workspace_id = azurerm_log_analytics_workspace.log.id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category = "DataPlaneRequests"
  }

  enabled_log {
    category = "ControlPlaneRequests"
  }

  enabled_log {
    category = "QueryRuntimeStatistics"
  }

  metric {
    category = "AllMetrics"
    enabled = false
  }
}

resource "azurerm_cosmosdb_sql_database" "sampledb" {
  name                = "sample"
  resource_group_name = azurerm_cosmosdb_account.db.resource_group_name
  account_name        = azurerm_cosmosdb_account.db.name
}

resource "azurerm_cosmosdb_sql_container" "samplecontainer" {
  name                  = "sample-container"
  resource_group_name   = azurerm_cosmosdb_account.db.resource_group_name
  account_name          = azurerm_cosmosdb_account.db.name
  database_name         = azurerm_cosmosdb_sql_database.sampledb.name
  partition_key_paths   = [ "/id" ]
  partition_key_version = 1
  throughput            = 400

  indexing_policy {
    indexing_mode = "consistent"

    included_path {
      path = "/*"
    }
  }
}

resource "random_uuid" "uuid" {
}

data "azurerm_cosmosdb_sql_role_definition" "contributor" {
  resource_group_name = azurerm_resource_group.rg.name
  account_name        = azurerm_cosmosdb_account.db.name
  role_definition_id  = "00000000-0000-0000-0000-000000000002" # Data contributor role
}

# Grant RBAC access to a user or service principal
resource "azurerm_cosmosdb_sql_role_assignment" "cosmosrbac" {
  name                = random_uuid.uuid.result
  resource_group_name = azurerm_resource_group.rg.name
  account_name        = azurerm_cosmosdb_account.db.name
  role_definition_id  = data.azurerm_cosmosdb_sql_role_definition.contributor.id
  principal_id        = azurerm_windows_virtual_machine.vm.identity[0].principal_id # Change this to your Enterprise Application object_id or your account principal_id
  scope               = azurerm_cosmosdb_account.db.id
}

# Create a private DNS zone and enable private link resolution
resource "azurerm_private_dns_zone" "cosmosdb" {
  name                = "privatelink.documents.azure.com"
  resource_group_name = azurerm_resource_group.rg.name
}

# Links the private DNS zone to the virtual network
resource "azurerm_private_dns_zone_virtual_network_link" "dnslink" {
  name                  = "privatedns-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.cosmosdb.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

# Create a private endpoint for Cosmos DB
resource "azurerm_private_endpoint" "cosmosdb" {
  name                = "cosmosdb-private-endpoint"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.subnet2.id

  private_service_connection {
    name                           = "cosmosdb-private-service-connection"
    private_connection_resource_id = azurerm_cosmosdb_account.db.id
    is_manual_connection           = false
    subresource_names              = ["SQL"]
  }

  private_dns_zone_group {
    name                = "cosmosdb-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.cosmosdb.id]
  }
}

# This public IP address is used to connect to the VM as a simulation only.
# For security reasons, you should not use a public IP address to connect to the VM and use a bastion host or a VPN instead.
resource "azurerm_public_ip" "vmpublicip" {
  name                = "vm-public-ip-${random_string.random_suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Dynamic"
}

resource "azurerm_network_interface" "vm_nic" {
  name                = "vm-nic-${random_string.random_suffix.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "vm-ip-config"
    subnet_id                     = azurerm_subnet.subnet1.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id = azurerm_public_ip.vmpublicip.id
  }
}

resource "azurerm_windows_virtual_machine" "vm" {
  name                  = "windows11-vm-${random_string.random_suffix.result}"
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  network_interface_ids = [azurerm_network_interface.vm_nic.id]

  size                 = "Standard_DS1_v2"
  admin_username       = "adminuser"
  admin_password       = "Password1234!"
  computer_name        = "mycomputer"
  enable_automatic_updates = true
  
  identity {
    type = "SystemAssigned"
  }

  os_disk {
    name              = "osdisk-${random_string.random_suffix.result}"
    caching           = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "microsoftwindowsdesktop"
    offer     = "windows-11"
    sku       = "win11-22h2-pro"
    version   = "latest"
  }

  license_type = "Windows_Client"
}

