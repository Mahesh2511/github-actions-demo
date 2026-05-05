output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "alb_controller_role_arn" {
  value       = aws_iam_role.alb_controller.arn
  description = "IAM role ARN for AWS Load Balancer Controller (used by Helm serviceAccount annotation)"
}
