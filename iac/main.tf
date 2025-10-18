terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.0" }
  }
}

provider "aws" {}  # Region comes from AWS_REGION environment variable (set by GitHub Actions)

module "selenium_grid" {
  source = "./modules/selenium_grid"

  name_prefix   = "selenium-grid"
  instance_type = var.instance_type

  # Key pair is handled by the workflow via create_key_pair + ssh_public_key_path.
  # If you already have a key in AWS, set key_name to use it; otherwise leave null.
  key_name = null

  # Allowlists from workflow inputs (default open for grid; SSH empty in CI)
  ssh_cidrs  = var.ssh_cidrs
  grid_cidrs = var.grid_cidrs

  # Optional extras (left off by default)
  create_eip      = false
  create_route53  = false
  hosted_zone_id  = null
  dns_name        = null
}

# ── Root variables (mapped from the workflow) ──────────────────────────────────
variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.large"
}

variable "ssh_cidrs" {
  description = "CIDRs allowed SSH (22)"
  type        = list(string)
  default     = []
}

variable "grid_cidrs" {
  description = "CIDRs allowed to reach Grid (4444) and noVNC (7900)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ── Re-export outputs for the workflow ─────────────────────────────────────────
output "instance_id"       { value = module.selenium_grid.instance_id }
output "public_ip"         { value = module.selenium_grid.public_ip }
output "public_dns"        { value = module.selenium_grid.public_dns }
output "security_group_id" { value = module.selenium_grid.security_group_id }
output "grid_url"          { value = module.selenium_grid.grid_url }
output "novnc_url"         { value = module.selenium_grid.novnc_url_chrome }
output "route53_fqdn"      { value = module.selenium_grid.route53_fqdn }
