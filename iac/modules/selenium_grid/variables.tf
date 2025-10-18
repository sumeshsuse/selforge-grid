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
