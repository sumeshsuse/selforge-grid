variable "name_prefix"   { type = string }
variable "cpu"           { type = number }
variable "memory"        { type = number }
variable "desired_count" { type = number }

variable "region"      { type = string }
variable "subnet_ids"  { type = list(string) }
variable "svc_sg_id"   { type = string }

variable "grid_tg_arn"  { type = string }
variable "novnc_tg_arn" { type = string }

# Optional overrides
variable "image" {
  type    = string
  default = "selenium/standalone-chrome:4.25.0"
}

