variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Public subnets: the hosts need public IPs because there is no NAT gateway."
  type        = list(string)
}

variable "alb_security_group_id" {
  type = string
}

variable "instance_type" {
  type    = string
  default = "r8g.xlarge"
}

variable "min_size" {
  type    = number
  default = 2
}

variable "max_size" {
  type    = number
  default = 4
}

variable "root_volume_size" {
  description = "GiB. Holds images, container logs and the migration dump scratch space."
  type        = number
  default     = 100
}

variable "max_instance_lifetime_days" {
  type    = number
  default = 14
}

variable "container_insights" {
  type    = string
  default = "enabled"
}

variable "enable_awsvpc_trunking" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
