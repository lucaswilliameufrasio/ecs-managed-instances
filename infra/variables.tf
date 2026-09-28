variable "aws_region" {
  type    = string
  default = "us-east-1"
}
variable "name" {
  type    = string
  default = "ecs-mi-benchmark"
}
variable "runner_instance_type" {
  type    = string
  default = "m9g.2xlarge"
}
variable "runner_vcpus" {
  type    = number
  default = 8
}
variable "runner_memory_mib" {
  type    = number
  default = 32768
}
variable "ecs_instance_type" {
  type    = string
  default = "m9g.xlarge"
}
variable "ecs_instance_vcpus" {
  type    = number
  default = 4
}
variable "ecs_instance_memory_mib" {
  type    = number
  default = 16384
}
variable "task_cpu_units" {
  type    = number
  default = 1024
}
variable "task_memory_mib" {
  type    = number
  default = 2048
}
variable "service_desired_count" {
  type    = number
  default = 0
}
variable "enable_service_autoscaling" {
  type    = bool
  default = false
}
variable "autoscaling_min_tasks" {
  type    = number
  default = 1
}
variable "autoscaling_max_tasks" {
  type    = number
  default = 8
  validation {
    condition     = var.autoscaling_max_tasks >= var.autoscaling_min_tasks
    error_message = "autoscaling_max_tasks must be greater than or equal to autoscaling_min_tasks."
  }
}
variable "autoscaling_target_cpu_percent" {
  type    = number
  default = 60
  validation {
    condition     = var.autoscaling_target_cpu_percent > 0 && var.autoscaling_target_cpu_percent <= 100
    error_message = "autoscaling_target_cpu_percent must be in the range (0, 100]."
  }
}
variable "autoscaling_scale_out_cooldown_seconds" {
  type    = number
  default = 30
}
variable "autoscaling_scale_in_cooldown_seconds" {
  type    = number
  default = 300
}
variable "key_name" {
  type        = string
  description = "Existing EC2 key pair for Ansible SSH"
}
variable "create_key_pair" {
  type        = bool
  description = "Create and manage a temporary EC2 key pair for this run"
  default     = false
}
variable "ssh_public_key_path" {
  type        = string
  description = "Local path to the SSH public key used by the runner"
}
variable "allowed_ssh_cidr" {
  type        = string
  description = "Public IPv4 CIDR permitted to SSH to the temporary runner"
}
variable "api_image_tag" {
  type    = string
  default = "benchmark"
}
variable "load_duration_seconds" {
  type    = number
  default = 60
}
variable "load_connections" {
  type    = number
  default = 64
}
variable "load_max_connections" {
  type    = number
  default = 1024
  validation {
    condition     = var.load_max_connections >= var.load_connections
    error_message = "load_max_connections must be greater than or equal to load_connections."
  }
}
variable "load_scale_settle_seconds" {
  type    = number
  default = 60
}
