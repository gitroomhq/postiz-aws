variable "name" {
  description = "Prefix of the forwarding rule's name."
  type        = string
}

variable "features" {
  description = <<-EOT
    Protection plan => ENABLED or DISABLED, with the plan's add-ons in "additional"
    (RUNTIME_MONITORING: EC2_AGENT_MANAGEMENT, ECS_FARGATE_AGENT_MANAGEMENT,
    EKS_ADDON_MANAGEMENT; RDS_LOGIN_EVENTS: RDS_DATA_RISK). A plan not named here
    keeps what GuardDuty sets by itself.
  EOT
  type = map(object({
    status     = string
    additional = optional(map(string), {})
  }))
  default = {}
}

variable "forward_findings_to" {
  description = "Event bus of the Region where the alerts are, and the role EventBridge uses to put events on it. Null in that Region itself."
  type = object({
    event_bus_arn = string
    role_arn      = string
  })
  default = null
}
