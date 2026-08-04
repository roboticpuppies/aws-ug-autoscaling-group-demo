# Finds the newest AMI produced by packer/asg-demo.pkr.hcl. This requires that
# `make ami` has been run at least once; until then `terraform plan` fails with
# "Your query returned no results", which is expected, not a bug.
data "aws_ami" "demo" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "name"
    values = ["${var.name_prefix}-*"]
  }

  filter {
    name   = "tag:Project"
    values = ["Demo"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_launch_template" "demo" {
  name        = var.name_prefix
  description = "Demo instances: nginx in Docker on a Packer-built AL2023 arm64 AMI"

  image_id = data.aws_ami.demo.id

  # Overridden per-type by the ASG's mixed instances policy; set so the template
  # is valid on its own.
  instance_type = var.instance_types[0]

  # null unless the operator opts in. Shell access is via SSM Session Manager.
  key_name = var.key_name

  vpc_security_group_ids = [aws_security_group.instance.id]

  iam_instance_profile {
    arn = aws_iam_instance_profile.instance.arn
  }

  # Matches the T4g default, but pinned deliberately. Under "standard" a t4g
  # starts with zero accrued credits -- launch credits are a T2-only feature --
  # so it would be throttled to its 10% baseline from boot. docker pull plus
  # container start would then crawl, risk blowing the 300s launch hook
  # heartbeat, and get the instance ABANDONed, producing launch-and-replace
  # churn that looks like a broken stack. Ignored by the non-burstable c6g
  # overrides.
  credit_specification {
    cpu_credits = "unlimited"
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(templatefile("${path.module}/templates/user-data.sh.tftpl", {
    asg_name         = local.asg_name
    launch_hook_name = local.launch_hook_name
    region           = var.region
  }))

  # No Name tag: instances name themselves <asg-name>-<last 5 of instance ID>
  # in user-data. Setting one here would only be overwritten seconds later.
  tag_specifications {
    resource_type = "instance"
    tags          = local.tags
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.tags
  }

  tags = merge(local.tags, { Name = var.name_prefix })
}
