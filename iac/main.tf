terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  # Region is taken from the environment (AWS_REGION), set by GitHub Actions.
}

########################
# Root-level variables #
########################

# CI passes these via -var=
variable "create_key_pair" {
  type        = bool
  description = "Create an ephemeral EC2 key pair from the provided public key"
  default     = false
}

variable "ssh_public_key_path" {
  type        = string
  description = "Path to a public key file to upload as the EC2 key pair (used when create_key_pair=true)"
  default     = null
}

variable "ssh_cidrs" {
  type        = list(string)
  description = "CIDRs allowed for SSH (22). Keep empty in CI to disable SSH."
  default     = []
}

variable "grid_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to access Grid (4444) and noVNC (7900)."
  default     = ["0.0.0.0/0"]
}

# Optional knobs you can set via -var if needed
variable "name_prefix" {
  type        = string
  description = "Name prefix for resources"
  default     = "selenium-grid"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type for the Grid host"
  default     = "t3.large"
}

variable "volume_size_gb" {
  type        = number
  description = "Root volume size (must be >=30GB for AL2023 snapshots)"
  default     = 35
}

###############################
# Optional: ephemeral keypair #
###############################
resource "aws_key_pair" "gha" {
  count      = var.create_key_pair ? 1 : 0
  key_name   = "${var.name_prefix}-gha-ephemeral"
  public_key = file(var.ssh_public_key_path)
}

##############################
# Selenium Grid via module   #
##############################
module "selenium_grid" {
  source = "./modules/selenium_grid"

  name_prefix    = var.name_prefix
  instance_type  = var.instance_type
  volume_size_gb = var.volume_size_gb

  # Pass the key name only if we created one
  key_name = var.create_key_pair ? aws_key_pair.gha[0].key_name : null

  # Network allow-lists
  ssh_cidrs  = var.ssh_cidrs
  grid_cidrs = var.grid_cidrs

  # Leave VPC/subnet null to auto-pick default VPC + first subnet
  vpc_id    = null
  subnet_id = null

  # IAM/EIP/Route53 are off by default; wire these later if you decide to use them
  create_iam_role = false
  create_eip      = false
  create_route53  = false
  hosted_zone_id  = null
  dns_name        = null
}

############
# Outputs  #
############
output "public_ip" {
  description = "Public IP of the Grid EC2"
  value       = module.selenium_grid.public_ip
}

output "public_dns" {
  description = "Public DNS of the Grid EC2"
  value       = module.selenium_grid.public_dns
}

output "instance_id" {
  description = "Instance ID"
  value       = module.selenium_grid.instance_id
}

output "security_group_id" {
  description = "Security Group ID"
  value       = module.selenium_grid.security_group_id
}

output "grid_url" {
  description = "Selenium Grid URL"
  value       = module.selenium_grid.grid_url
}

output "novnc_url" {
  description = "noVNC URL (Chrome node)"
  value       = module.selenium_grid.novnc_url
}
