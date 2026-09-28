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
variable "ecs_instance_type" {
  type    = string
  default = "m9g.xlarge"
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
  default = 30
}
variable "load_connections" {
  type    = number
  default = 64
}
