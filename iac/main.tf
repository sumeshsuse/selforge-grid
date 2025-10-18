terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  # Region comes from AWS_REGION env / OIDC in the workflow
}

module "selenium_grid" {
  source = "./modules/selenium_grid"

  # Required / common vars
  instance_type        = var.instance_type
  create_key_pair      = var.create_key_pair
  ssh_public_key_path  = var.ssh_public_key_path
  ssh_cidrs            = var.ssh_cidrs
  grid_cidrs           = var.grid_cidrs

  # Optional DNS (leave null to disable)
  route53_zone_id      = var.route53_zone_id
  route53_record_name  = var.route53_record_name
}

# ——— Re-export handy outputs ———
output "instance_id"      { value = module.selenium_grid.instance_id }
output "public_ip"        { value = module.selenium_grid.public_ip }
output "public_dns"       { value = module.selenium_grid.public_dns }
output "security_group_id"{ value = module.selenium_grid.security_group_id }
output "grid_url"         { value = module.selenium_grid.grid_url }
output "novnc_url_chrome" { value = module.selenium_grid.novnc_url_chrome }
output "route53_fqdn"     { value = module.selenium_grid.route53_fqdn }

# Root-level variables (kept in sync with module)
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

variable "instance_type" {
  description = "EC2 instance type for the grid"
  type        = string
  default     = "t3.large"
}

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
