output "alb_dns_name" {
  description = "Public DNS name of the demo ALB."
  value       = aws_lb.demo.dns_name
}

output "asg_name" {
  description = "Auto Scaling group name."
  value       = aws_autoscaling_group.demo.name
}

output "target_group_arn" {
  description = "Target group ARN, used by `make targets`."
  value       = aws_lb_target_group.demo.arn
}

output "fis_experiment_template_id" {
  description = "FIS experiment template ID, used by `make interrupt`."
  value       = aws_fis_experiment_template.spot_interruption.id
}

output "region" {
  description = "Region the stack is deployed in, so the Makefile need not hardcode it."
  value       = var.region
}
