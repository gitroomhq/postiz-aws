output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  value = aws_ecs_cluster.this.arn
}

# read from the association so services are only created once the capacity
# provider is attached to the cluster (the default strategy is the EC2 provider;
# capacity_providers also lists FARGATE when enable_fargate is on)
output "capacity_provider_name" {
  value = one(aws_ecs_cluster_capacity_providers.this.default_capacity_provider_strategy).capacity_provider
}

output "instance_security_group_id" {
  value = aws_security_group.instance.id
}

output "autoscaling_group_name" {
  value = aws_autoscaling_group.this.name
}

output "capacity_providers" {
  value = aws_ecs_cluster_capacity_providers.this.capacity_providers
}
