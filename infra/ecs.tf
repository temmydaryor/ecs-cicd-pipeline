resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.project_name}"
  retention_in_days = 14 # default is "never expire" = silent cost growth
}

resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# --- IAM: two different roles, a very common interview question -------------
# Execution role = used by the ECS AGENT to pull the image and ship logs.
# Task role      = used by YOUR CODE inside the container to call AWS APIs.
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${var.project_name}-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name               = "${var.project_name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
  # Intentionally no policies attached: this app calls no AWS APIs (least privilege).
}

# --- Task definition (first revision only; the pipeline registers later ones) ---
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.project_name}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  # Must match the CPU architecture you BUILD for. GitHub's ubuntu-latest runners
  # are x86_64. (Building on an Apple Silicon Mac? add --platform linux/amd64.)
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "app" # the pipeline's CONTAINER_NAME must match this
      image     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
      essential = true

      portMappings = [{
        containerPort = var.container_port
        protocol      = "tcp"
      }]

      environment = [
        { name = "APP_ENV", value = "production" }
      ]

      # Container-level health check (separate from the ALB health check).
      healthCheck = {
        command     = ["CMD-SHELL", "python -c \"import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:${var.container_port}/health', timeout=2).status == 200 else 1)\""]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 15
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.app.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "app"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "app" {
  name            = "${var.project_name}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # Rolling update that never drops below full capacity => zero downtime.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # Ignore ALB health failures for the first N seconds so slow starters are not killed.
  health_check_grace_period_seconds = 30

  # ROLLBACK #1: if new tasks keep failing to reach steady state, ECS stops the
  # deployment and automatically returns to the last good task definition.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # ROLLBACK #2: if either alarm fires DURING a deployment, ECS rolls back too.
  alarms {
    enable      = true
    rollback    = true
    alarm_names = [
      aws_cloudwatch_metric_alarm.unhealthy_hosts.alarm_name,
      aws_cloudwatch_metric_alarm.target_5xx.alarm_name,
    ]
  }

  network_configuration {
    subnets          = local.subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = true # no NAT gateway; see network.tf
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = var.container_port
  }

  # The PIPELINE registers new task definition revisions and updates the service.
  # Without this, every `terraform apply` would try to revert to revision 1.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener.http]
}
