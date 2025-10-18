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

#####################
# Security Group
#####################
resource "aws_security_group" "grid_sg" {
  name        = "${var.name_prefix}-sg"
  description = "Allow Selenium Grid and optional SSH"
  vpc_id      = local.effective_vpc_id

  # SSH 22
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

  # noVNC 7900
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
  user_data = <<EOF
#!/bin/bash
set -euxo pipefail
exec > >(tee -a /var/log/user-data.log) 2>&1
echo "[user-data] start $(date -Iseconds)"

dnf -y makecache
dnf -y install docker curl wget jq

systemctl enable --now docker
sleep 3

# docker compose v2
mkdir -p /usr/local/lib/docker/cli-plugins
curl -L "https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
docker compose version || true

# folders
mkdir -p /opt/grid/logs/hub /opt/grid/logs/chrome /opt/grid/logs/firefox
mkdir -p /opt/grid/downloads/chrome /opt/grid/downloads/firefox
cd /opt/grid

# compose file
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
      - SE_OPTS=--relax-checks true
      - OTEL_TRACES_EXPORTER=none
      - OTEL_METRICS_EXPORTER=none
      - OTEL_LOGS_EXPORTER=none
    volumes:
      - "./logs/hub:/opt/selenium/logs"
    healthcheck:
      test: ["CMD", "bash", "-lc", "wget -q --spider http://localhost:4444/status"]
      interval: 5s
      timeout: 3s
      retries: 60
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

echo "[user-data] docker pull + up"
docker compose -f /opt/grid/docker-compose.yml pull
docker compose -f /opt/grid/docker-compose.yml up -d

echo "[user-data] docker ps after up:"
docker ps -a

# Wait for hub
echo "[user-data] waiting for hub readiness..."
for i in $(seq 1 120); do
  if curl -fsS http://localhost:4444/status | jq -e '.value.ready == true' >/dev/null 2>&1; then
    echo "[user-data] hub is ready"
    exit 0
  fi
  sleep 5
done

echo "[user-data] hub NOT ready; last /status:"
curl -v http://localhost:4444/status || true
echo "[user-data] docker ps (final):"
docker ps -a
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
