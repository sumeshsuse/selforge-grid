terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ---------------- Root-level variables ----------------
variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name_prefix" {
  type    = string
  default = "selenium-grid"
}

# If you are NOT letting Terraform create the key pair, set this to an existing key pair name.
variable "key_name" {
  type    = string
  default = null
}

# Allowlists (use CLI/tfvars to pass values per environment)
variable "ssh_cidrs" {
  type    = list(string)
  default = []
}

variable "grid_cidrs" {
  type    = list(string)
  default = []
}

# Optional VPC/Subnet (omit to auto-discover default VPC/subnet)
variable "vpc_id" {
  type    = string
  default = null
}

variable "subnet_id" {
  type    = string
  default = null
}

# Toggles
variable "create_iam_role" {
  type    = bool
  default = true
}

variable "create_eip" {
  type    = bool
  default = true
}

# Optional Route53
variable "create_route53" {
  type    = bool
  default = false
}

variable "hosted_zone_id" {
  type    = string
  default = null
}

variable "dns_name" {
  type    = string
  default = null
}

variable "create_key_pair" {
  type    = bool
  default = false
}

variable "ssh_public_key_path" {
  type    = string
  default = null
}

resource "aws_key_pair" "generated" {
  count      = var.create_key_pair && var.ssh_public_key_path != null ? 1 : 0
  key_name   = "${var.name_prefix}-key"
  public_key = file(var.ssh_public_key_path)
}

# ---------------- Provider ----------------
provider "aws" {
  region = var.region
}

# ---------------- Module call ----------------
module "selenium_grid" {
  source = "./modules/selenium_grid"

  name_prefix = var.name_prefix

  # Use Terraform-created key pair if enabled; otherwise require var.key_name
  key_name = length(aws_key_pair.generated) > 0 ? aws_key_pair.generated[0].key_name : var.key_name

  # Networking allowlists (lists)
  ssh_cidrs  = var.ssh_cidrs
  grid_cidrs = var.grid_cidrs

  # Optional VPC/Subnet (omit to auto-discover)
  vpc_id    = var.vpc_id
  subnet_id = var.subnet_id

  # Toggles
  create_iam_role = var.create_iam_role
  create_eip      = var.create_eip

  # Optional DNS
  create_route53 = var.create_route53
  hosted_zone_id = var.hosted_zone_id
  dns_name       = var.dns_name
}

# ---------------- Useful outputs ----------------
output "public_ip" {
  value = module.selenium_grid.public_ip
}

output "grid_url" {
  value = module.selenium_grid.grid_url
}

output "novnc_url" {
  value = module.selenium_grid.novnc_url_chrome
}

output "route53_fqdn" {
  value = module.selenium_grid.route53_fqdn
}
