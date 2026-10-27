output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  value = aws_ecs_cluster.this.arn
}

# read from the association so services are only created once the capacity
# provider is attached to the cluster
output "capacity_provider_name" {
  value = one(aws_ecs_cluster_capacity_providers.this.capacity_providers)
}

output "instance_security_group_id" {
  value = aws_security_group.instance.id
}

output "autoscaling_group_name" {
  value = aws_autoscaling_group.this.name
}
