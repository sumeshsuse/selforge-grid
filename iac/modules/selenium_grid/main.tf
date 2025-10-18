terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

# ── Default VPC/Subnet discovery (if not provided) ─────────────────────────────
data "aws_vpc" "default" {
  count   = var.vpc_id == null ? 1 : 0
  default = true
}

data "aws_subnets" "default" {
  count = var.subnet_id == null ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [var.vpc_id != null ? var.vpc_id : data.aws_vpc.default[0].id]
  }
}

# ── Locals ─────────────────────────────────────────────────────────────────────
locals {
  effective_vpc_id    = var.vpc_id != null ? var.vpc_id : data.aws_vpc.default[0].id
  effective_subnet_id = var.subnet_id != null ? var.subnet_id : data.aws_subnets.default[0].ids[0]

  computed_ssh_cidrs  = var.ssh_cidrs
  computed_grid_cidrs = var.grid_cidrs
}

# ── AMI: Amazon Linux 2023 (x86_64) ────────────────────────────────────────────
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter { name = "name",         values = ["al2023-ami-*-x86_64"] }
  filter { name = "architecture", values = ["x86_64"] }
}

# ── Key pair (optional) ────────────────────────────────────────────────────────
resource "aws_key_pair" "gha" {
  count      = var.create_key_pair ? 1 : 0
  key_name   = "gha-ephemeral"
  public_key = file(var.ssh_public_key_path)
}

# ── Security Group (dynamic allowlists) ────────────────────────────────────────
resource "aws_security_group" "grid_sg" {
  name        = "${var.name_prefix}-sg"
  description = "Access for Selenium Grid and SSH"
  vpc_id      = local.effective_vpc_id

  dynamic "ingress" {
    for_each = local.computed_ssh_cidrs
    content {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  dynamic "ingress" {
    for_each = local.computed_grid_cidrs
    content {
      description = "Selenium Grid UI"
      from_port   = 4444
      to_port     = 4444
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  dynamic "ingress" {
    for_each = local.computed_grid_cidrs
    content {
      description = "noVNC (Chrome)"
      from_port   = 7900
      to_port     = 7900
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    description      = "All outbound"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = { Name = "${var.name_prefix}-sg" }
}

# ── EC2 Instance (standalone-chrome, no curl install) ──────────────────────────
resource "aws_instance" "grid" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = local.effective_subnet_id
  vpc_security_group_ids      = [aws_security_group.grid_sg.id]
  associate_public_ip_address = true
  key_name                    = var.create_key_pair ? aws_key_pair.gha[0].key_name : null

  root_block_device {
    volume_size = var.volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  user_data_replace_on_change = true
  user_data = <<'BASH'
#!/bin/bash
set -euxo pipefail
exec > >(tee -a /var/log/user-data.log) 2>&1

echo "[user-data] bootstrap $(date -Iseconds)"

# Avoid curl vs curl-minimal conflicts on AL2023: do NOT install curl
dnf -y makecache
dnf -y install jq docker

systemctl enable docker
systemctl start docker
usermod -aG docker ec2-user || true

# Pull and run Selenium Standalone Chrome
SEL_VER="4.25.0"
docker pull selenium/standalone-chrome:${SEL_VER}

docker rm -f selenium || true
docker run -d --name selenium --restart unless-stopped --net host \
-e SE_NODE_MAX_SESSIONS=1 \
-e SE_NODE_OVERRIDE_MAX_SESSIONS=true \
selenium/standalone-chrome:${SEL_VER}

# Wait until Grid is ready (use wget instead of curl)
for i in $(seq 1 60); do
if wget -qO- http://localhost:4444/status | jq -e '.value.ready == true' >/dev/null 2>&1; then
echo "[user-data] Selenium Grid is ready."
exit 0
fi
echo "[user-data] Waiting for Selenium Grid... ($i/60)"
sleep 5
done

echo "[user-data] Grid did not become ready in time." >&2
exit 1
BASH

tags = { Name = "${var.name_prefix}-ec2" }
}

# ── Elastic IP (optional; default off) ─────────────────────────────────────────
resource "aws_eip" "grid" {
count  = var.create_eip ? 1 : 0
domain = "vpc"
tags   = { Name = "${var.name_prefix}-eip" }
}

resource "aws_eip_association" "grid" {
count         = var.create_eip ? 1 : 0
instance_id   = aws_instance.grid.id
allocation_id = aws_eip.grid[0].id
}

# ── Route53 record (optional; requires EIP) ────────────────────────────────────
resource "aws_route53_record" "grid" {
count   = (var.create_route53 && var.create_eip) ? 1 : 0
zone_id = var.route53_zone_id
name    = var.route53_record_name
type    = "A"
ttl     = 300
records = [aws_eip.grid[0].public_ip]
}

# ── Outputs ────────────────────────────────────────────────────────────────────
output "instance_id"       { value = aws_instance.grid.id }
output "public_ip"         { value = coalesce(try(aws_eip.grid[0].public_ip, null), aws_instance.grid.public_ip) }
output "public_dns"        { value = aws_instance.grid.public_dns }
output "security_group_id" { value = aws_security_group.grid_sg.id }

output "grid_url" {
value = "http://${coalesce(try(aws_eip.grid[0].public_ip, null), aws_instance.grid.public_ip)}:4444"
}

output "novnc_url_chrome" {
value = "http://${coalesce(try(aws_eip.grid[0].public_ip, null), aws_instance.grid.public_ip)}:7900"
}

output "route53_fqdn" {
value       = try(aws_route53_record.grid[0].fqdn, null)
description = "DNS name if Route53 record created"
}

# ── Variables (module scope) ───────────────────────────────────────────────────
variable "name_prefix"         { type = string, default = "selenium-grid" }
variable "instance_type"       { type = string, default = "t3.large" }
variable "volume_size_gb"      { type = number, default = 16 }

variable "vpc_id"              { type = string, default = null }
variable "subnet_id"           { type = string, default = null }

variable "create_key_pair"     { type = bool, default = true }
variable "ssh_public_key_path" { type = string, default = "~/.ssh/id_rsa.pub" }

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

variable "create_eip"          { type = bool, default = false }

variable "create_route53"      { type = bool, default = false }
variable "route53_zone_id"     { type = string, default = null }
variable "route53_record_name" { type = string, default = null }
