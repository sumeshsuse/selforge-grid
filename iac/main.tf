terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {}

########################
# Variables (tweakable) #
########################
variable "name_prefix"    { type = string  default = "selenium-fargate" }
variable "desired_count"  { type = number  default = 1 }
variable "cpu"            { type = number  default = 1024 } # 1 vCPU
variable "memory"         { type = number  default = 2048 } # 2 GB
variable "grid_cidrs"     { type = list(string) default = ["0.0.0.0/0"] } # who can hit ALB (HTTP)

################
# Default VPC  #
################
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

######################
# Security Groups    #
######################
# ALB: internet → 80 (Grid) and 7900 (noVNC)
resource "aws_security_group" "alb_sg" {
  name        = "${var.name_prefix}-alb-sg"
  description = "ALB SG"
  vpc_id      = data.aws_vpc.default.id

  dynamic "ingress" {
    for_each = var.grid_cidrs
    content {
      description = "HTTP to Grid via ALB"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  dynamic "ingress" {
    for_each = var.grid_cidrs
    content {
      description = "noVNC via ALB"
      from_port   = 7900
      to_port     = 7900
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    description      = "All egress"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = { Name = "${var.name_prefix}-alb-sg" }
}

# Service: only ALB → 4444 and 7900
resource "aws_security_group" "svc_sg" {
  name        = "${var.name_prefix}-svc-sg"
  description = "Service SG"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Grid traffic from ALB"
    from_port       = 4444
    to_port         = 4444
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  ingress {
    description     = "noVNC traffic from ALB"
    from_port       = 7900
    to_port         = 7900
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    description      = "All egress"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = { Name = "${var.name_prefix}-svc-sg" }
}

#########################
# Application LB (HTTP) #
#########################
resource "aws_lb" "alb" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = data.aws_subnets.default.ids

  idle_timeout = 120
  tags = { Name = "${var.name_prefix}-alb" }
}

# Target Group for Grid (port 4444) — target_type=ip for Fargate
resource "aws_lb_target_group" "grid_tg" {
  name        = "${var.name_prefix}-grid-tg"
  port        = 4444
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"

  health_check {
    protocol            = "HTTP"
    path                = "/status"
    matcher             = "200-399"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
  }

  tags = { Name = "${var.name_prefix}-grid-tg" }
}

# Listener 80 -> Grid TG: so you can call http://ALB/ and it forwards to :4444
resource "aws_lb_listener" "http_80" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grid_tg.arn
  }
}

# Optional noVNC on 7900 via ALB
resource "aws_lb_target_group" "novnc_tg" {
  name        = "${var.name_prefix}-novnc-tg"
  port        = 7900
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"

  health_check {
    protocol            = "HTTP"
    path                = "/"
    matcher             = "200-399"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
  }

  tags = { Name = "${var.name_prefix}-novnc-tg" }
}

resource "aws_lb_listener" "http_7900" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 7900
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.novnc_tg.arn
  }
}

##########################
# ECS + Fargate bits     #
##########################
resource "aws_ecs_cluster" "this" {
  name = "${var.name_prefix}-cluster"
  setting {
    name  = "containerInsights"
    value = "disabled"
  }
  tags = { Name = "${var.name_prefix}-cluster" }
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name_prefix}"
  retention_in_days = 7
}

# IAM roles
data "aws_iam_policy_document" "task_assume" {
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
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
}

resource "aws_iam_role_policy_attachment" "exec_policy" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task_role" {
  name               = "${var.name_prefix}-task-role"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
}

# Task Definition — Selenium Standalone Chrome
resource "aws_ecs_task_definition" "selenium" {
  family                   = "${var.name_prefix}-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task_role.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "selenium"
      image     = "selenium/standalone-chrome:4.25.0"
      essential = true
      portMappings = [
        { containerPort = 4444, hostPort = 4444, protocol = "tcp" },
        { containerPort = 7900, hostPort = 7900, protocol = "tcp" }
      ]
      environment = [
        { name = "SE_NODE_MAX_SESSIONS", value = "1" },
        { name = "SE_SCREEN_WIDTH",      value = "1920" },
        { name = "SE_SCREEN_HEIGHT",     value = "1080" },
        { name = "JAVA_OPTS",            value = "-Xmx1024m" },
        { name = "OTEL_TRACES_EXPORTER", value = "none" },
        { name = "OTEL_METRICS_EXPORTER",value = "none" },
        { name = "OTEL_LOGS_EXPORTER",   value = "none" }
      ]
      ulimits = [
        { name = "nofile", softLimit = 32768, hardLimit = 32768 }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = data.aws_vpc.default.arn.split(":")[3]
          awslogs-stream-prefix = "selenium"
        }
      }
    }
  ])
}

# ECS Service
resource "aws_ecs_service" "svc" {
  name            = "${var.name_prefix}-svc"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.selenium.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = data.aws_subnets.default.ids
    security_groups = [aws_security_group.svc_sg.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.grid_tg.arn
    container_name   = "selenium"
    container_port   = 4444
  }

  depends_on = [
    aws_lb_listener.http_80
  ]

  lifecycle {
    ignore_changes = [task_definition] # allow rolling image updates
  }

  tags = { Name = "${var.name_prefix}-svc" }
}

############
# Outputs  #
############
output "alb_dns_name" {
  description = "ALB DNS name"
  value       = aws_lb.alb.dns_name
}

output "grid_url" {
  description = "Use this in tests (-Dgrid.url)"
  value       = "http://${aws_lb.alb.dns_name}"
}

output "novnc_url" {
  description = "Open this in browser for VNC"
  value       = "http://${aws_lb.alb.dns_name}:7900"
}
