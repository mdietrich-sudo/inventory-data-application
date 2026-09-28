terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Store state in an Azure Storage blob container (encrypted, access-controlled, with locking) —
  # NOT locally — because the DB password, Jira token and the BigQuery SA key flow through state.
  # Create the storage account + container once, then uncomment + `terraform init -migrate-state`.
  # backend "azurerm" {
  #   resource_group_name  = "wonder-dq-tfstate"
  #   storage_account_name = "wonderdqtfstate"
  #   container_name       = "tfstate"
  #   key                  = "app-service.tfstate"
  #   use_azuread_auth     = true
  # }
}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    key_vault {
      # This may be a *temporary* home (see GO-LIVE-AZURE.md §9.3), so make teardown clean:
      # purge soft-deleted vaults/secrets on destroy instead of leaving name squatters behind.
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }
}

provider "random" {}
