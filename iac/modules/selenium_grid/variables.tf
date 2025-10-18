variable "name_prefix" {
  type        = string
  default     = "selenium-grid"
  description = "Prefix for resource names"
}

variable "key_name" {
  type        = string
  description = "Existing EC2 key pair"
}

# Back-compat (optional): if set, it will be used when lists are empty
variable "my_ip_cidr" {
  type        = string
  default     = null
  description = "Your public IP in CIDR (e.g., 1.2.3.4/32). Deprecated in favor of ssh_cidrs/grid_cidrs."
}

# New: flexible allowlists
variable "ssh_cidrs" {
  type        = list(string)
  default     = []
  description = "CIDR list allowed to SSH (port 22). Empty list = no SSH rule."
}

variable "grid_cidrs" {
  type        = list(string)
  default     = []
  description = "CIDR list allowed to Grid UI/noVNC (4444/7900). If empty and my_ip_cidr is set, that will be used."
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "volume_size_gb" {
  type    = number
  default = 30
}

variable "vpc_id" {
  type        = string
  default     = null
  description = "VPC to use. If null, use account default VPC"
}

variable "subnet_id" {
  type        = string
  default     = null
  description = "Subnet to use. If null, pick the first default subnet"
}

variable "create_eip" {
  type    = bool
  default = true
}

variable "create_iam_role" {
  type    = bool
  default = true
}

variable "create_route53" {
  type        = bool
  default     = false
  description = "If true, requires hosted_zone_id and dns_name, and assumes create_eip = true."
}

variable "hosted_zone_id" {
  type        = string
  default     = null
  description = "Public Route53 hosted zone ID (required if create_route53 = true)"
}

variable "dns_name" {
  type        = string
  default     = null
  description = "Record name, e.g. grid.example.com (required if create_route53 = true)"
}
