locals {
  asg_name            = var.name_prefix
  launch_hook_name    = "${var.name_prefix}-launch"
  terminate_hook_name = "${var.name_prefix}-terminate"

  # Project=Demo is load-bearing: FIS target selection, the SSM Run Command
  # target filter, and the ec2:CreateTags IAM condition all match on it.
  tags = {
    Project = "Demo"
  }
}
