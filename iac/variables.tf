variable "name_prefix" {
  type    = string
  default = "selenium-fargate"
}

variable "desired_count" {
  type    = number
  default = 1
}

variable "cpu" {
  type    = number
  default = 1024
}

variable "memory" {
  type    = number
  default = 2048
}

variable "grid_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}