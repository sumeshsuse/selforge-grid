terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

################
# Module inputs
################
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
  default = 35
}

variable "key_name" {
  type        = string
  default     = null
  description = "Existing EC2 key pair name (or null)"
}

variable "vpc_id" {
  type    = string
  default = null
}

variable "subnet_id" {
  type    = string
  default = null
}

variable "ssh_cidrs" {
  type    = list(string)
  default = []
}

variable "grid_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "create_iam_role" {
  type    = bool
  default = false
}

variable "create_eip" {
  type    = bool
  default = false
}

variable "create_route53" {
  type    = bool
  default = false
}

variable "hosted_zone_id" {
  type    = string
  default = null
}

variable "dns_name" {
  type    = string
  default = null
}

#############
# Networking
#############
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

locals {
  effective_vpc_id    = var.vpc_id    != null ? var.vpc_id    : data.aws_vpc.default[0].id
  effective_subnet_id = var.subnet_id != null ? var.subnet_id : data.aws_subnets.default[0].ids[0]

  ssh_allow  = var.ssh_cidrs
  grid_allow = var.grid_cidrs
}

###########################
# AMI (Amazon Linux 2023)
###########################
# Use SSM public parameter for the latest AL2023 x86_64 AMI
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

#####################
# Security Group
#####################
resource "aws_security_group" "grid_sg" {
  name        = "${var.name_prefix}-sg"
  description = "Allow Selenium Grid and optional SSH"
  vpc_id      = local.effective_vpc_id

  # SSH 22 (optional)
  dynamic "ingress" {
    for_each = local.ssh_allow
    content {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  # Grid 4444
  dynamic "ingress" {
    for_each = local.grid_allow
    content {
      description = "Grid"
      from_port   = 4444
      to_port     = 4444
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  # noVNC 7900 (Chrome)
  dynamic "ingress" {
    for_each = local.grid_allow
    content {
      description = "noVNC"
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

  tags = {
    Name = "${var.name_prefix}-sg"
  }
}

############
# Optional IAM
############
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

#############
# EC2 host
#############
resource "aws_instance" "grid" {
  ami                         = data.aws_ssm_parameter.al2023.value
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
  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    exec > >(tee -a /var/log/user-data.log) 2>&1
    echo "[user-data] start $(date -Iseconds)"

    # If ECS agent exists on the AMI, stop/disable so it doesn't interfere
    if systemctl list-unit-files | grep -q '^ecs.service'; then
      systemctl stop ecs || true
      systemctl disable ecs || true
    fi

    dnf -y makecache
    dnf -y install docker jq curl

    systemctl enable --now docker
    usermod -aG docker ec2-user || true

    echo "[user-data] docker info"
    docker info || true

    # Pull required images
    docker pull selenium/hub:4.25.0
    docker pull selenium/node-chrome:4.25.0
    docker pull selenium/node-firefox:4.25.0

    # Clean previous (if rerun)
    docker rm -f selenium-hub chrome firefox || true

    # Run hub on host network (binds :4444 on the host)
    docker run -d --name selenium-hub --restart unless-stopped \
      --network host \
      -e SE_OPTS="--relax-checks true" \
      -e OTEL_TRACES_EXPORTER=none \
      -e OTEL_METRICS_EXPORTER=none \
      -e OTEL_LOGS_EXPORTER=none \
      selenium/hub:4.25.0

    # Wait for hub to be ready locally
    for i in $(seq 1 120); do
      if curl -fsS http://127.0.0.1:4444/status | jq -e '.value.ready == true' >/dev/null 2>&1; then
        echo "[user-data] hub is ready"
        break
      fi
      echo "[user-data] waiting hub... ($i/120)"
      sleep 2
    done

    # Start nodes on host network; talk to hub via localhost
    docker run -d --name chrome --restart unless-stopped \
      --network host \
      --shm-size=2g \
      -e SE_EVENT_BUS_HOST=127.0.0.1 \
      -e SE_EVENT_BUS_PUBLISH_PORT=4442 \
      -e SE_EVENT_BUS_SUBSCRIBE_PORT=4443 \
      -e SE_NODE_MAX_SESSIONS=1 \
      -e SE_SCREEN_WIDTH=1920 \
      -e SE_SCREEN_HEIGHT=1080 \
      -e OTEL_TRACES_EXPORTER=none \
      -e OTEL_METRICS_EXPORTER=none \
      -e OTEL_LOGS_EXPORTER=none \
      selenium/node-chrome:4.25.0

    docker run -d --name firefox --restart unless-stopped \
      --network host \
      --shm-size=2g \
      -e SE_EVENT_BUS_HOST=127.0.0.1 \
      -e SE_EVENT_BUS_PUBLISH_PORT=4442 \
      -e SE_EVENT_BUS_SUBSCRIBE_PORT=4443 \
      -e SE_NODE_MAX_SESSIONS=1 \
      -e SE_SCREEN_WIDTH=1920 \
      -e SE_SCREEN_HEIGHT=1080 \
      -e OTEL_TRACES_EXPORTER=none \
      -e OTEL_METRICS_EXPORTER=none \
      -e OTEL_LOGS_EXPORTER=none \
      selenium/node-firefox:4.25.0

    echo "[user-data] docker ps:"
    docker ps -a || true

    echo "[user-data] listening ports:"
    ss -ltn || true

    # Final readiness
    for i in $(seq 1 150); do
      if curl -fsS http://127.0.0.1:4444/status | jq -e '.value.ready == true' >/dev/null 2>&1; then
        echo "[user-data] DONE. Hub ready."
        exit 0
      fi
      sleep 2
    done

    echo "[user-data] hub NOT ready; dumping logs"
    docker logs selenium-hub || true
    exit 1
  EOF

  tags = {
    Name = "${var.name_prefix}-ec2"
  }
}

#############
# Optional EIP / DNS
#############
resource "aws_eip" "grid" {
  count  = var.create_eip ? 1 : 0
  domain = "vpc"
  tags = {
    Name = "${var.name_prefix}-eip"
  }
}

resource "aws_eip_association" "grid" {
  count         = var.create_eip ? 1 : 0
  instance_id   = aws_instance.grid.id
  allocation_id = aws_eip.grid[0].id
}

resource "aws_route53_record" "grid" {
  count   = var.create_route53 ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = var.dns_name
  type    = "A"
  ttl     = 60
  records = [
    var.create_eip ? aws_eip.grid[0].public_ip : aws_instance.grid.public_ip
  ]
}

#########
# Outputs
#########
output "public_ip" {
  value = aws_instance.grid.public_ip
}

output "public_dns" {
  value = aws_instance.grid.public_dns
}

output "instance_id" {
  value = aws_instance.grid.id
}

output "security_group_id" {
  value = aws_security_group.grid_sg.id
}

output "grid_url" {
  value = "http://${aws_instance.grid.public_ip}:4444"
}

output "novnc_url" {
  value = "http://${aws_instance.grid.public_ip}:7900"
}
