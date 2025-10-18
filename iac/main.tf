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
  # Region comes from AWS_REGION env (set by GitHub Actions OIDC)
}

# ─────────────────────────────
# Root-level variables (needed by your workflow -var flags)
# ─────────────────────────────
variable "create_key_pair" {
  description = "Whether to create an ephemeral EC2 key pair from provided public key"
  type        = bool
  default     = true
}

variable "ssh_public_key_path" {
  description = "Path to a public key file (used when create_key_pair=true)"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "ssh_cidrs" {
  description = "CIDR blocks allowed to SSH (22)"
  type        = list(string)
  default     = []
}

variable "grid_cidrs" {
  description = "CIDR blocks allowed to reach Selenium Grid (4444) and noVNC (7900)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# Optional — only if you want to override the module’s default
variable "instance_type" {
  description = "EC2 instance type for the grid"
  type        = string
  default     = "t3.large"
}

# Optional Route53 (kept for future use; module defaults to disabled)
variable "route53_zone_id" {
  description = "Optional Route53 hosted zone ID to create a DNS record"
  type        = string
  default     = null
}

variable "route53_record_name" {
  description = "Optional DNS name for Selenium Grid (e.g., grid.example.com)"
  type        = string
  default     = null
}

# ─────────────────────────────
# Ephemeral key pair (root-level)
# ─────────────────────────────
resource "aws_key_pair" "gha" {
  count      = var.create_key_pair ? 1 : 0
  key_name   = "gha-ephemeral"
  public_key = file(var.ssh_public_key_path)
}

# ─────────────────────────────
# Module: selenium_grid
# ─────────────────────────────
module "selenium_grid" {
  source = "./modules/selenium_grid"

  # Naming/size
  name_prefix   = "selenium-grid"
  instance_type = var.instance_type

  # SSH/Grid access
  ssh_cidrs  = var.ssh_cidrs
  grid_cidrs = var.grid_cidrs

  # Key pair: pass the ephemeral one if created, else null
  key_name = var.create_key_pair ? aws_key_pair.gha[0].key_name : null

  # Route53/EIP are optional and off by default in module; if you want DNS later:
  # create_eip      = true
  # create_route53  = true
  # hosted_zone_id  = var.route53_zone_id
  # dns_name        = var.route53_record_name
}

# ─────────────────────────────
# Re-export module outputs for the workflow
# ─────────────────────────────
output "instance_id" {
  value = module.selenium_grid.instance_id
}

output "public_ip" {
  value = module.selenium_grid.public_ip
}

output "public_dns" {
  value = module.selenium_grid.public_dns
}

output "security_group_id" {
  value = module.selenium_grid.security_group_id
}

output "grid_url" {
  value = module.selenium_grid.grid_url
}

# Your workflow expects `novnc_url`, while the module outputs `novnc_url_chrome`.
output "novnc_url" {
  value = module.selenium_grid.novnc_url_chrome
}

output "route53_fqdn" {
  value       = module.selenium_grid.route53_fqdn
  description = "DNS name if Route53 record created"
}
