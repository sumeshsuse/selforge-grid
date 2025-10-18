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
  # Region comes from AWS_REGION env (set by GitHub Actions OIDC)
}

########################
# Networking (default) #
########################
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

#################
# Key pair (opt)#
#################
resource "aws_key_pair" "gha" {
  count      = var.create_key_pair ? 1 : 0
  key_name   = "gha-ephemeral"
  public_key = file(var.ssh_public_key_path)
}

########################
# Security group rules #
########################
resource "aws_security_group" "grid_sg" {
  name        = "selenium-grid-sg"
  description = "Allow Selenium Grid and optional SSH"
  vpc_id      = data.aws_vpc.default.id

  # SSH (22) — controlled by ssh_cidrs
  dynamic "ingress" {
    for_each = var.ssh_cidrs
    content {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  # Grid (4444) — controlled by grid_cidrs
  dynamic "ingress" {
    for_each = var.grid_cidrs
    content {
      description = "Selenium Grid"
      from_port   = 4444
      to_port     = 4444
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  # noVNC (7900)
  dynamic "ingress" {
    for_each = var.grid_cidrs
    content {
      description = "noVNC"
      from_port   = 7900
      to_port     = 7900
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "selenium-grid-sg"
  }
}

###########################
# AMI (Amazon Linux 2023) #
###########################
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

#####################
# EC2 for the grid  #
#####################
resource "aws_instance" "grid" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.grid_sg.id]
  associate_public_ip_address = true

  key_name = var.create_key_pair ? aws_key_pair.gha[0].key_name : null

  user_data_replace_on_change = true
  user_data = <<'BASH'
#!/bin/bash
set -euxo pipefail
exec > >(tee -a /var/log/user-data.log) 2>&1

echo "[user-data] bootstrap $(date -Iseconds)"

# Amazon Linux 2023 → avoid curl vs curl-minimal conflict
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

# Wait until Grid is ready
for i in $(seq 1 60); do
if curl -fsS http://localhost:4444/status | jq -e '.value.ready == true' >/dev/null 2>&1; then
echo "[user-data] Selenium Grid is ready."
exit 0
fi
echo "[user-data] Waiting for Selenium Grid... ($i/60)"
sleep 5
done

echo "[user-data] Grid did not become ready in time." >&2
exit 1
BASH

tags = {
Name = "selenium-grid"
}

root_block_device {
volume_size = 16
volume_type = "gp3"
encrypted   = true
}
}

##################
# Elastic IP (opt)
##################
resource "aws_eip" "grid" {
count = 0 # set to 1 later if you want static IP
instance = aws_instance.grid.id
vpc      = true
depends_on = [aws_instance.grid]
}

##################
# Route 53 (opt) #
##################
resource "aws_route53_record" "grid" {
count   = 0 # set to 1 if DNS desired
zone_id = var.route53_zone_id
name    = var.route53_record_name
type    = "A"
ttl     = 300
records = [coalesce(try(aws_eip.grid[0].public_ip, null), aws_instance.grid.public_ip)]
}

