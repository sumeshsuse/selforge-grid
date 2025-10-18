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

  # SSH 22 (only if provided)
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
      description = "Grid Hub"
      from_port   = 4444
      to_port     = 4444
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  # noVNC 7900 (Chrome node)
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

# Install Docker (Amazon Linux 2023)
dnf -y makecache
dnf -y install docker curl wget jq

# Enable and start Docker
systemctl enable --now docker
sleep 3
docker version || (systemctl status docker || true)

# Create a dedicated Docker network for Grid (idempotent)
docker network create grid || true

# Pull images (explicit)
docker pull selenium/hub:4.25.0
docker pull selenium/node-chrome:4.25.0
docker pull selenium/node-firefox:4.25.0

# Run Hub
docker rm -f selenium-hub || true
docker run -d --restart=unless-stopped --name selenium-hub --network grid \
  -p 4444:4444 \
  -e SE_OPTS="--relax-checks true" \
  -e OTEL_TRACES_EXPORTER=none -e OTEL_METRICS_EXPORTER=none -e OTEL_LOGS_EXPORTER=none \
  selenium/hub:4.25.0

# Wait for hub port + /status
echo "[user-data] wait for hub 4444..."
for i in $(seq 1 120); do
  if timeout 2 bash -lc "cat </dev/null >/dev/tcp/127.0.0.1/4444" 2>/dev/null; then
    READY="$(curl -fsS http://127.0.0.1:4444/status | jq -r '.value.ready // .ready // empty' || true)"
    if [ "$READY" = "true" ]; then
      echo "[user-data] hub is ready"
      break
    fi
    echo "[user-data] 4444 open, but hub not ready yet... ($i/120)"
  else
    echo "[user-data] 4444 not open yet... ($i/120)"
  fi
  sleep 5
done

# Start Chrome node (expose noVNC 7900)
docker rm -f node-chrome || true
docker run -d --restart=unless-stopped --name node-chrome --network grid \
  -p 7900:7900 \
  -e SE_EVENT_BUS_HOST=selenium-hub \
  -e SE_EVENT_BUS_PUBLISH_PORT=4442 \
  -e SE_EVENT_BUS_SUBSCRIBE_PORT=4443 \
  -e SE_NODE_MAX_SESSIONS=1 \
  -e SE_SCREEN_WIDTH=1920 \
  -e SE_SCREEN_HEIGHT=1080 \
  -e OTEL_TRACES_EXPORTER=none -e OTEL_METRICS_EXPORTER=none -e OTEL_LOGS_EXPORTER=none \
  --shm-size="2g" \
  selenium/node-chrome:4.25.0

# Start Firefox node
docker rm -f node-firefox || true
docker run -d --restart=unless-stopped --name node-firefox --network grid \
  -e SE_EVENT_BUS_HOST=selenium-hub \
  -e SE_EVENT_BUS_PUBLISH_PORT=4442 \
  -e SE_EVENT_BUS_SUBSCRIBE_PORT=4443 \
  -e SE_NODE_MAX_SESSIONS=1 \
  -e SE_SCREEN_WIDTH=1920 \
  -e SE_SCREEN_HEIGHT=1080 \
  -e OTEL_TRACES_EXPORTER=none -e OTEL_METRICS_EXPORTER=none -e OTEL_LOGS_EXPORTER=none \
  --shm-size="2g" \
  selenium/node-firefox:4.25.0

echo "[user-data] containers:"
docker ps -a

# Final readiness verify (up to 10 min)
for i in $(seq 1 120); do
  READY="$(curl -fsS http://127.0.0.1:4444/status | jq -r '.value.ready // .ready // empty' || true)"
  if [ "$READY" = "true" ]; then
    echo "[user-data] Grid READY ✅"
    exit 0
  fi
  sleep 5
done

echo "[user-data] Grid NOT ready ❌. Dumping status and logs."
curl -v http://127.0.0.1:4444/status || true
docker logs selenium-hub || true
docker logs node-chrome || true
docker logs node-firefox || true
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
