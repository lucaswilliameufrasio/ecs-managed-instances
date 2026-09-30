resource "aws_ecr_repository" "api" {
  name                 = var.name
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.name}/${var.benchmark_run_id}"
  retention_in_days = 7
}

resource "aws_ecs_cluster" "benchmark" {
  name = var.name
}

resource "aws_iam_role" "ecs_infrastructure" {
  name = "${var.name}-infrastructure"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}
resource "aws_iam_role_policy_attachment" "ecs_infrastructure" {
  role       = aws_iam_role.ecs_infrastructure.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECSInfrastructureRolePolicyForManagedInstances"
}

resource "aws_iam_role" "ecs_instance" {
  name = "ecsInstanceRole-${var.name}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}
resource "aws_iam_role_policy_attachment" "ecs_instance" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECSInstanceRolePolicyForManagedInstances"
}
resource "aws_iam_instance_profile" "ecs_instance" {
  name = "ecsInstanceRole-${var.name}"
  role = aws_iam_role.ecs_instance.name
}

resource "aws_iam_role" "task_execution" {
  name = "${var.name}-task-execution"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}
resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_capacity_provider" "managed" {
  name    = "mi-${var.name}-m9g"
  cluster = aws_ecs_cluster.benchmark.name
  managed_instances_provider {
    infrastructure_role_arn = aws_iam_role.ecs_infrastructure.arn
    instance_launch_template {
      capacity_option_type     = "ON_DEMAND"
      ec2_instance_profile_arn = aws_iam_instance_profile.ecs_instance.arn
      instance_requirements {
        allowed_instance_types = [var.ecs_instance_type]
        vcpu_count {
          min = var.ecs_instance_vcpus
          max = var.ecs_instance_vcpus
        }
        memory_mib {
          min = var.ecs_instance_memory_mib
          max = var.ecs_instance_memory_mib
        }
      }
      network_configuration {
        subnets         = [aws_subnet.public.id]
        security_groups = [aws_security_group.ecs.id]
      }
    }
  }
  depends_on = [
    aws_iam_role_policy_attachment.ecs_infrastructure,
    aws_iam_role_policy_attachment.ecs_instance,
  ]
}

resource "time_sleep" "capacity_provider_active" {
  create_duration = "30s"
  depends_on      = [aws_ecs_capacity_provider.managed]
}

resource "aws_ecs_cluster_capacity_providers" "benchmark" {
  cluster_name       = aws_ecs_cluster.benchmark.name
  capacity_providers = [aws_ecs_capacity_provider.managed.name]
  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.managed.name
    weight            = 1
  }
  depends_on = [time_sleep.capacity_provider_active]
}

resource "aws_ecs_task_definition" "api" {
  family                   = var.name
  requires_compatibilities = ["MANAGED_INSTANCES"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.task_cpu_units)
  memory                   = tostring(var.task_memory_mib)
  execution_role_arn       = aws_iam_role.task_execution.arn
  container_definitions = jsonencode([{
    name      = "parking-api"
    image     = "${aws_ecr_repository.api.repository_url}:${var.api_image_tag}"
    essential = true
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-create-group"  = "false"
        "awslogs-group"         = aws_cloudwatch_log_group.api.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "parking-api"
      }
    }
    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]
  }])
  depends_on = [aws_iam_role_policy_attachment.task_execution]
}

resource "aws_lb" "api" {
  name               = "${var.name}-internal"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.alb_a.id, aws_subnet.alb_b.id]
}

resource "aws_lb_target_group" "api" {
  name        = "${var.name}-api"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.benchmark.id

  health_check {
    enabled             = true
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "204"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "api_http" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

resource "aws_ecs_service" "api" {
  name            = var.name
  cluster         = aws_ecs_cluster.benchmark.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.service_desired_count
  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.managed.name
    weight            = 1
  }
  network_configuration {
    subnets         = [aws_subnet.public.id]
    security_groups = [aws_security_group.ecs.id]
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "parking-api"
    container_port   = 8080
  }
  depends_on = [aws_ecs_cluster_capacity_providers.benchmark, aws_lb_listener.api_http]

  lifecycle {
    ignore_changes = [desired_count]
  }
  timeouts {
    delete = "5m"
  }
}

resource "aws_appautoscaling_target" "ecs_service" {
  count              = var.enable_service_autoscaling ? 1 : 0
  max_capacity       = var.autoscaling_max_tasks
  min_capacity       = var.autoscaling_min_tasks
  resource_id        = "service/${aws_ecs_cluster.benchmark.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "ecs_service_cpu" {
  count              = var.enable_service_autoscaling ? 1 : 0
  name               = "${var.name}-cpu-target-tracking"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_service[0].resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_service[0].service_namespace
  target_tracking_scaling_policy_configuration {
    target_value       = var.autoscaling_target_cpu_percent
    scale_out_cooldown = var.autoscaling_scale_out_cooldown_seconds
    scale_in_cooldown  = var.autoscaling_scale_in_cooldown_seconds
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
