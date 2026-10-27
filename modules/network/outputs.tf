output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "azs" {
  value = local.azs
}

output "public_subnet_ids" {
  value = [for az in local.azs : aws_subnet.public[az].id]
}

output "private_subnet_ids" {
  value = [for az in local.azs : aws_subnet.private[az].id]
}

output "public_subnet_ids_by_az" {
  value = { for az in local.azs : az => aws_subnet.public[az].id }
}
