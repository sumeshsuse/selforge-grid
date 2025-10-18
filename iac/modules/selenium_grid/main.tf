terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# -------- Variables (multi-line, no commas) --------
variable "name_prefix" {
  type    = string
  default = "selenium-grid"
}

variable "instance_type" {
  type    = string
  default = "t3.large"
}

variable "volume_size_gb" {
  type    = number
  default = 30
}

variable "grid_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

# -------- Network (default VPC) --------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# -------- Security Group --------
resource "aws_security_group" "grid" {
  name        = "${var.name_prefix}-sg"
  description = "Allow Selenium Grid (4444) and noVNC (7900)"
  vpc_id      = data.aws_vpc.default.id

  dynamic "ingress" {
    for_each = var.grid_cidrs
    content {
      description = "Grid 4444"
      from_port   = 4444
      to_port     = 4444
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  dynamic "ingress" {
    for_each = var.grid_cidrs
    content {
      description = "noVNC 7900"
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

# -------- AMI --------
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-kernel-6.1-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# -------- EC2 with single Selenium container --------
resource "aws_instance" "grid" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.grid.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size = var.volume_size_gb
    volume_type = "gp3"
  }

  user_data_replace_on_change = true
  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    exec > >(tee -a /var/log/user-data.log) 2>&1
    echo "[user-data] start $(date -Iseconds)"

    dnf -y makecache
    dnf -y install docker curl jq
    systemctl enable --now docker
    sleep 2

    docker pull selenium/standalone-chrome:4.25.0
    docker rm -f selenium-grid || true
    docker run -d --name selenium-grid \
      -p 4444:4444 -p 7900:7900 \
      -e SE_NODE_MAX_SESSIONS=1 \
      -e SE_SCREEN_WIDTH=1920 \
      -e SE_SCREEN_HEIGHT=1080 \
      --restart unless-stopped \
      selenium/standalone-chrome:4.25.0

    echo "[user-data] waiting for /status..."
    for i in $(seq 1 120); do
      if curl -fsS http://localhost:4444/status | jq -e '.value.ready == true' >/dev/null 2>&1; then
        echo "[user-data] grid ready"
        exit 0
      fi
      sleep 5
    done

    echo "[user-data] grid NOT ready; last status:"
    curl -v http://localhost:4444/status || true
    docker ps -a || true
    exit 1
  EOF

  tags = { Name = "${var.name_prefix}-ec2" }
}

# -------- Outputs --------
output "grid_url" {
  value = "http://${aws_instance.grid.public_ip}:4444"
}
