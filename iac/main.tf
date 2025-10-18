terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {}

# -------- Variables (multi-line, no commas) --------
variable "name_prefix" {
  type    = string
  default = "selenium-grid"
}

variable "instance_type" {
  type    = string
  default = "t3.large"
}

variable "volume_size_gb" {
  type    = number
  default = 30
}

variable "grid_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

# -------- Module --------
module "selenium_grid" {
  source         = "./modules/selenium_grid"
  name_prefix    = var.name_prefix
  instance_type  = var.instance_type
  volume_size_gb = var.volume_size_gb
  grid_cidrs     = var.grid_cidrs
}

# -------- Outputs --------
output "grid_url" {
  description = "Selenium Grid URL"
  value       = module.selenium_grid.grid_url
}
