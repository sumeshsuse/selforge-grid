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
      name      = "selenium",
      image     = var.image,
      essential = true,
      portMappings = [
        { containerPort = 4444, hostPort = 4444, protocol = "tcp" },
        { containerPort = 7900, hostPort = 7900, protocol = "tcp" }
      ],
      environment = [
        { name = "SE_NODE_MAX_SESSIONS", value = "1" },
        { name = "SE_SCREEN_WIDTH",      value = "1920" },
        { name = "SE_SCREEN_HEIGHT",     value = "1080" },
        { name = "JAVA_OPTS",            value = "-Xmx1024m" },
        { name = "OTEL_TRACES_EXPORTER", value = "none" },
        { name = "OTEL_METRICS_EXPORTER",value = "none" },
        { name = "OTEL_LOGS_EXPORTER",   value = "none" }
      ],
      ulimits = [
        { name = "nofile", softLimit = 32768, hardLimit = 32768 }
      ],
      logConfiguration = {
        logDriver = "awslogs",
        options = {
          awslogs-group         = "/ecs/${var.name_prefix}",
          awslogs-region        = var.region,
          awslogs-stream-prefix = "selenium"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "svc" {
  name            = "${var.name_prefix}-svc"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_iam_role.task_execution.arn == "" ? aws_ecs_task_definition.selenium.arn : aws_ecs_task_definition.selenium.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [var.svc_sg_id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = var.grid_tg_arn
    container_name   = "selenium"
    container_port   = 4444
  }

  load_balancer {
    target_group_arn = var.novnc_tg_arn
    container_name   = "selenium"
    container_port   = 7900
  }

  lifecycle {
    ignore_changes = [task_definition]
  }

  tags = { Name = "${var.name_prefix}-svc" }
}
