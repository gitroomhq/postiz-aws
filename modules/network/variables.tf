variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "cidr" {
  type = string
}

variable "az_count" {
  type    = number
  default = 3
}
