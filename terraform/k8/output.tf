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

output "ebs_csi_role_arn" {
  value       = aws_iam_role.ebs_csi.arn
  description = "IAM role ARN for EBS CSI driver"
}
