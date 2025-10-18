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

  # Back-compat: use my_ip_cidr if lists are empty and my_ip_cidr is provided
  computed_ssh_cidrs  = length(var.ssh_cidrs) > 0 ? var.ssh_cidrs : (var.my_ip_cidr != null ? [var.my_ip_cidr] : [])
  computed_grid_cidrs = length(var.grid_cidrs) > 0 ? var.grid_cidrs : (var.my_ip_cidr != null ? [var.my_ip_cidr] : [])
}

# ── AMI: Amazon Linux 2023 (x86_64) ────────────────────────────────────────────
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

# ── Security Group (dynamic allowlists) ────────────────────────────────────────
resource "aws_security_group" "grid_sg" {
  name        = "${var.name_prefix}-sg"
  description = "Access for Selenium Grid and SSH"
  vpc_id      = local.effective_vpc_id

  # SSH (22) — only if at least one CIDR provided
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

  # Grid UI (4444)
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

  # noVNC (7900)
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

# ── IAM (optional) ─────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "grid" {
  count              = var.create_iam_role ? 1 : 0
  name               = "${var.name_prefix}-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ecr_full" {
  count      = var.create_iam_role ? 1 : 0
  role       = aws_iam_role.grid[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"
}

resource "aws_iam_role_policy_attachment" "s3_full" {
  count      = var.create_iam_role ? 1 : 0
  role       = aws_iam_role.grid[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_instance_profile" "grid" {
  count = var.create_iam_role ? 1 : 0
  name  = "${var.name_prefix}-instance-profile"
  role  = aws_iam_role.grid[0].name
}

# ── EC2 Instance ───────────────────────────────────────────────────────────────
resource "aws_instance" "grid" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = local.effective_subnet_id
  vpc_security_group_ids      = [aws_security_group.grid_sg.id]
  associate_public_ip_address = true

  iam_instance_profile = var.create_iam_role ? aws_iam_instance_profile.grid[0].name : null

  root_block_device {
    volume_size = var.volume_size_gb
    volume_type = "gp3"
  }

  user_data_replace_on_change = true
  user_data                   = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    dnf -y update
    dnf -y install docker curl wget
    systemctl enable --now docker

    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -L "https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-x86_64" \
      -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

    mkdir -p /opt/grid/logs/hub /opt/grid/logs/chrome /opt/grid/logs/firefox
    mkdir -p /opt/grid/downloads/chrome /opt/grid/downloads/firefox
    cd /opt/grid

    cat > /opt/grid/docker-compose.yml <<'YAML'
    version: "3.9"
    services:
      selenium-hub:
        image: selenium/hub:4.25.0
        platform: linux/amd64
        container_name: selenium-hub
        ports:
          - "4444:4444"
        environment:
          - OTEL_TRACES_EXPORTER=none
          - OTEL_METRICS_EXPORTER=none
          - OTEL_LOGS_EXPORTER=none
        volumes:
          - "./logs/hub:/opt/selenium/logs"
        healthcheck:
          test: ["CMD", "bash", "-lc", "wget -q --spider http://localhost:4444/status"]
          interval: 5s
          timeout: 3s
          retries: 30
          start_period: 10s
        restart: unless-stopped
        logging:
          driver: local
          options:
            max-size: "10m"
            max-file: "3"

      chrome:
        image: selenium/node-chrome:4.25.0
        platform: linux/amd64
        shm_size: 2gb
        depends_on:
          selenium-hub:
            condition: service_healthy
        environment:
          - SE_EVENT_BUS_HOST=selenium-hub
          - SE_EVENT_BUS_PUBLISH_PORT=4442
          - SE_EVENT_BUS_SUBSCRIBE_PORT=4443
          - SE_NODE_MAX_SESSIONS=1
          - SE_SCREEN_WIDTH=1920
          - SE_SCREEN_HEIGHT=1080
          - SE_SCREEN_DEPTH=24
          - OTEL_TRACES_EXPORTER=none
          - OTEL_METRICS_EXPORTER=none
          - OTEL_LOGS_EXPORTER=none
        ports:
          - "7900:7900"
        volumes:
          - "./logs/chrome:/opt/selenium/logs"
          - "./downloads/chrome:/home/seluser/Downloads"
        ulimits:
          nofile:
            soft: 32768
            hard: 32768
        restart: unless-stopped
        logging:
          driver: local
          options:
            max-size: "10m"
            max-file: "3"

      firefox:
        image: selenium/node-firefox:4.25.0
        platform: linux/amd64
        shm_size: 2gb
        depends_on:
          selenium-hub:
            condition: service_healthy
        environment:
          - SE_EVENT_BUS_HOST=selenium-hub
          - SE_EVENT_BUS_PUBLISH_PORT=4442
          - SE_EVENT_BUS_SUBSCRIBE_PORT=4443
          - SE_NODE_MAX_SESSIONS=1
          - SE_SCREEN_WIDTH=1920
          - SE_SCREEN_HEIGHT=1080
          - SE_SCREEN_DEPTH=24
          - OTEL_TRACES_EXPORTER=none
          - OTEL_METRICS_EXPORTER=none
          - OTEL_LOGS_EXPORTER=none
        volumes:
          - "./logs/firefox:/opt/selenium/logs"
          - "./downloads/firefox:/home/seluser/Downloads"
        ulimits:
          nofile:
            soft: 32768
            hard: 32768
        restart: unless-stopped
        logging:
          driver: local
          options:
            max-size: "10m"
            max-file: "3"
    YAML

    docker compose -f /opt/grid/docker-compose.yml pull
    docker compose -f /opt/grid/docker-compose.yml up -d
  EOF

  tags = { Name = "${var.name_prefix}-ec2" }
}

# ── Elastic IP (optional) ──────────────────────────────────────────────────────
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
  count   = var.create_route53 ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = var.dns_name
  type    = "A"
  ttl     = 60
  records = [aws_eip.grid[0].public_ip]
}
