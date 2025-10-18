terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

################
# Inputs
################
variable "name_prefix"    { type = string,      default = "selenium-grid" }
variable "vpc_id"         { type = string,      default = null }
variable "subnet_ids"     { type = list(string),default = [] } # leave empty to auto-pick default VPC subnets
variable "grid_cidrs"     { type = list(string),default = ["0.0.0.0/0"] }
variable "cpu"            { type = number,      default = 2048 }  # 2 vCPU
variable "memory"         { type = number,      default = 4096 }  # 4 GB
variable "create_route53" { type = bool,        default = false }
variable "hosted_zone_id" { type = string,      default = null }
variable "dns_name"       { type = string,      default = null }
variable "aws_region"     { type = string,      default = null }  # only for logs (optional)

################
# Data sources
################
data "aws_region" "current" {}

data "aws_vpc" "default" {
  count   = var.vpc_id == null ? 1 : 0
  default = true
}

data "aws_subnets" "public" {
  count = length(var.subnet_ids) == 0 ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [var.vpc_id != null ? var.vpc_id : data.aws_vpc.default[0].id]
  }
}

locals {
  vpc_id     = var.vpc_id != null ? var.vpc_id : data.aws_vpc.default[0].id
  subnets    = length(var.subnet_ids) > 0 ? var.subnet_ids : data.aws_subnets.public[0].ids
  aws_region = coalesce(var.aws_region, data.aws_region.current.name)
}

########################
# Security group
########################
resource "aws_security_group" "grid" {
  name        = "${var.name_prefix}-sg"
  description = "Allow Grid and noVNC"
  vpc_id      = local.vpc_id

  # Hub 4444
  dynamic "ingress" {
    for_each = var.grid_cidrs
    content {
      description = "Grid 4444"
      protocol    = "tcp"
      from_port   = 4444
      to_port     = 4444
      cidr_blocks = [ingress.value]
    }
  }

  # Chrome noVNC 7900
  dynamic "ingress" {
    for_each = var.grid_cidrs
    content {
      description = "noVNC chrome 7900"
      protocol    = "tcp"
      from_port   = 7900
      to_port     = 7900
      cidr_blocks = [ingress.value]
    }
  }

  # Firefox noVNC 7901
  dynamic "ingress" {
    for_each = var.grid_cidrs
    content {
      description = "noVNC firefox 7901"
      protocol    = "tcp"
      from_port   = 7901
      to_port     = 7901
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    description      = "All outbound"
    protocol         = "-1"
    from_port        = 0
    to_port          = 0
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = { Name = "${var.name_prefix}-sg" }
}

########################
# ECS Cluster
########################
resource "aws_ecs_cluster" "this" {
  name = "${var.name_prefix}-cluster"
}

########################
# IAM (execution role)
########################
data "aws_iam_policy_document" "task_exec_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${var.name_prefix}-exec-role"
  assume_role_policy = data.aws_iam_policy_document.task_exec_assume.json
}

resource "aws_iam_role_policy_attachment" "exec_policy" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

########################
# Logs
########################
resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name_prefix}"
  retention_in_days = 7
}

########################
# ALB + Target Groups + Listeners
########################
resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  subnets            = local.subnets
  security_groups    = [aws_security_group.grid.id]
}

# Hub 4444
resource "aws_lb_target_group" "hub" {
  name        = "${var.name_prefix}-tg-hub"
  port        = 4444
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
  target_type = "ip"

  health_check {
    path                = "/status"
    port                = "4444"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    matcher             = "200"
  }
}

resource "aws_lb_listener" "hub" {
  load_balancer_arn = aws_lb.this.arn
  port              = 4444
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.hub.arn
  }
}

# Chrome noVNC 7900
resource "aws_lb_target_group" "novnc_chrome" {
  name        = "${var.name_prefix}-tg-chrome"
  port        = 7900
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
  target_type = "ip"

  health_check {
    path                = "/"
    port                = "7900"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200-399"
  }
}

resource "aws_lb_listener" "novnc_chrome" {
  load_balancer_arn = aws_lb.this.arn
  port              = 7900
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.novnc_chrome.arn
  }
}

# Firefox noVNC exposed on 7901
resource "aws_lb_target_group" "novnc_firefox" {
  name        = "${var.name_prefix}-tg-firefox"
  port        = 7901
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
  target_type = "ip"

  health_check {
    path                = "/"
    port                = "7901"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200-399"
  }
}

resource "aws_lb_listener" "novnc_firefox" {
  load_balancer_arn = aws_lb.this.arn
  port              = 7901
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.novnc_firefox.arn
  }
}

########################
# Task Definition (one task, three containers)
########################
locals {
  container_defs = jsonencode([
    {
      name      = "selenium-hub"
      image     = "selenium/hub:4.25.0"
      essential = true
      portMappings = [
        { containerPort = 4444, hostPort = 4444, protocol = "tcp" }
      ]
      environment = [
        { name = "SE_OPTS",               value = "--relax-checks true" },
        { name = "OTEL_TRACES_EXPORTER",  value = "none" },
        { name = "OTEL_METRICS_EXPORTER", value = "none" },
        { name = "OTEL_LOGS_EXPORTER",    value = "none" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = local.aws_region
          awslogs-stream-prefix = "hub"
        }
      }
      healthCheck = {
        command  = ["CMD-SHELL", "wget -q --spider http://localhost:4444/status || exit 1"]
        interval = 10
        retries  = 6
        timeout  = 5
      }
    },
    {
      name      = "chrome"
      image     = "selenium/node-chrome:4.25.0"
      essential = true
      portMappings = [
        { containerPort = 7900, hostPort = 7900, protocol = "tcp" }
      ]
      environment = [
        { name = "SE_EVENT_BUS_HOST",         value = "127.0.0.1" },
        { name = "SE_EVENT_BUS_PUBLISH_PORT", value = "4442" },
        { name = "SE_EVENT_BUS_SUBSCRIBE_PORT", value = "4443" },
        { name = "SE_NODE_MAX_SESSIONS",      value = "1" },
        { name = "SE_SCREEN_WIDTH",           value = "1920" },
        { name = "SE_SCREEN_HEIGHT",          value = "1080" },
        { name = "OTEL_TRACES_EXPORTER",      value = "none" },
        { name = "OTEL_METRICS_EXPORTER",     value = "none" },
        { name = "OTEL_LOGS_EXPORTER",        value = "none" }
      ]
      dependsOn = [{ containerName = "selenium-hub", condition = "HEALTHY" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = local.aws_region
          awslogs-stream-prefix = "chrome"
        }
      }
    },
    {
      name      = "firefox"
      image     = "selenium/node-firefox:4.25.0"
      essential = true
      portMappings = [
        { containerPort = 7900, hostPort = 7901, protocol = "tcp" }
      ]
      environment = [
        { name = "SE_EVENT_BUS_HOST",         value = "127.0.0.1" },
        { name = "SE_EVENT_BUS_PUBLISH_PORT", value = "4442" },
        { name = "SE_EVENT_BUS_SUBSCRIBE_PORT", value = "4443" },
        { name = "SE_NODE_MAX_SESSIONS",      value = "1" },
        { name = "SE_SCREEN_WIDTH",           value = "1920" },
        { name = "SE_SCREEN_HEIGHT",          value = "1080" },
        { name = "OTEL_TRACES_EXPORTER",      value = "none" },
        { name = "OTEL_METRICS_EXPORTER",     value = "none" },
        { name = "OTEL_LOGS_EXPORTER",        value = "none" }
      ]
      dependsOn = [{ containerName = "selenium-hub", condition = "HEALTHY" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = local.aws_region
          awslogs-stream-prefix = "firefox"
        }
      }
    }
  ])
}

resource "aws_ecs_task_definition" "grid" {
  family                   = "${var.name_prefix}-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.cpu)
  memory                   = tostring(var.memory)
  execution_role_arn       = aws_iam_role.task_execution.arn
  container_definitions    = local.container_defs

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
}

########################
# ECS Service
########################
resource "aws_ecs_service" "grid" {
  name            = "${var.name_prefix}-svc"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.grid.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = local.subnets
    security_groups  = [aws_security_group.grid.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.hub.arn
    container_name   = "selenium-hub"
    container_port   = 4444
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.novnc_chrome.arn
    container_name   = "chrome"
    container_port   = 7900
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.novnc_firefox.arn
    container_name   = "firefox"
    container_port   = 7900
  }

  depends_on = [
    aws_lb_listener.hub,
    aws_lb_listener.novnc_chrome,
    aws_lb_listener.novnc_firefox
  ]

  lifecycle {
    ignore_changes = [desired_count]
  }
}

########################
# Optional DNS
########################
resource "aws_route53_record" "grid" {
  count   = var.create_route53 ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = var.dns_name
  type    = "CNAME"
  ttl     = 60
  records = [aws_lb.this.dns_name]
}

########################
# Outputs
########################
output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "grid_url" {
  value = "http://${aws_route53_record.grid.count > 0 ? var.dns_name : aws_lb.this.dns_name}:4444"
}

output "novnc_url_chrome" {
  value = "http://${aws_route53_record.grid.count > 0 ? var.dns_name : aws_lb.this.dns_name}:7900"
}

output "novnc_url_firefox" {
  value = "http://${aws_route53_record.grid.count > 0 ? var.dns_name : aws_lb.this.dns_name}:7901"
}
