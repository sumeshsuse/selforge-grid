resource "aws_lb" "alb" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.subnet_ids
  idle_timeout       = 120
  tags               = { Name = "${var.name_prefix}-alb" }
}

resource "aws_lb_target_group" "grid_tg" {
  name        = "${var.name_prefix}-grid-tg"
  port        = 4444
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
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

resource "aws_lb_listener" "http_80" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grid_tg.arn
  }
}

resource "aws_lb_target_group" "novnc_tg" {
  name        = "${var.name_prefix}-novnc-tg"
  port        = 7900
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
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

