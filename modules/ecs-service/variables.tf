variable "name" {
  description = "Service and main container name."
  type        = string
}

variable "cluster_name" {
  type = string
}

variable "cluster_arn" {
  type = string
}

variable "capacity_provider_name" {
  type = string
}

variable "execution_role_arn" {
  type = string
}

variable "network_mode" {
  type    = string
  default = "bridge"

  validation {
    condition     = contains(["bridge", "awsvpc"], var.network_mode)
    error_message = "network_mode must be bridge or awsvpc."
  }
}

variable "subnet_ids" {
  description = "awsvpc only."
  type        = list(string)
  default     = []
}

variable "security_group_ids" {
  description = "awsvpc only. Bridge-mode tasks use the host security group."
  type        = list(string)
  default     = []
}

variable "image" {
  type = string
}

variable "command" {
  type    = list(string)
  default = null
}

variable "entry_point" {
  type    = list(string)
  default = null
}

variable "cpu" {
  description = "CPU units (1024 = 1 vCPU), a share, not a hard cap."
  type        = number
}

variable "memory" {
  description = "Hard memory limit in MiB, the container is killed above it."
  type        = number
}

variable "memory_reservation" {
  description = "MiB reserved for placement. The container may burst up to memory."
  type        = number
}

variable "port" {
  type    = number
  default = null
}

variable "environment" {
  type    = map(string)
  default = {}
}

variable "secrets" {
  description = "Env var name => Secrets Manager valueFrom (arn:...:secret:name:json-key::)."
  type        = map(string)
  default     = {}
}

variable "health_check" {
  type = object({
    command      = list(string)
    interval     = number
    timeout      = number
    retries      = number
    start_period = number
  })
  default = null
}

variable "stop_timeout" {
  type    = number
  default = 60
}

variable "sidecars" {
  description = "Extra container definitions (ECS JSON shape). Logging is added when missing."
  type        = any
  default     = []
}

variable "host_volumes" {
  description = "Volume name => host path."
  type        = map(string)
  default     = {}
}

variable "mount_points" {
  type = list(object({
    volume    = string
    path      = string
    read_only = bool
  }))
  default = []
}

variable "create_service" {
  description = "false only registers the task definition (one-off tasks)."
  type        = bool
  default     = true
}

variable "desired_count" {
  type    = number
  default = 1
}

variable "autoscaling" {
  type = object({
    max        = number
    cpu_target = number
  })
  default = null
}

variable "target_group_arn" {
  type    = string
  default = null
}

variable "lb_container_name" {
  type    = string
  default = null
}

variable "lb_container_port" {
  type    = number
  default = null
}

variable "health_check_grace_period" {
  type    = number
  default = 180
}

variable "service_registry_arn" {
  type    = string
  default = null
}

variable "deployment_minimum_healthy_percent" {
  type    = number
  default = 100
}

variable "deployment_maximum_percent" {
  type    = number
  default = 200
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "task_role_policy_json" {
  type    = string
  default = null
}
