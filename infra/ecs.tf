resource "aws_ecr_repository" "api" {
  name                 = var.name
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = true
  }
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
    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]
  }])
  depends_on = [aws_iam_role_policy_attachment.task_execution]
}

resource "aws_ecs_service" "api" {
  name            = var.name
  cluster         = aws_ecs_cluster.benchmark.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = 0
  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.managed.name
    weight            = 1
  }
  network_configuration {
    subnets         = [aws_subnet.public.id]
    security_groups = [aws_security_group.ecs.id]
  }
  depends_on = [aws_ecs_cluster_capacity_providers.benchmark]
}
