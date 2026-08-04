resource "aws_autoscaling_group" "demo" {
  name                = local.asg_name
  vpc_zone_identifier = aws_subnet.public[*].id

  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.desired_capacity

  # "ELB" covers both: it adds ALB health checks on top of EC2 status checks.
  # There is no separate EC2 toggle. The grace period only starts once an
  # instance reaches InService -- which the launch hook already gates on nginx
  # answering -- so it is headroom against a container dying just after
  # bootstrap, not cover for boot time.
  health_check_type         = "ELB"
  health_check_grace_period = 300

  target_group_arns = [aws_lb_target_group.demo.arn]

  # EC2 emits a rebalance recommendation when a Spot Instance is at elevated
  # risk of interruption, earlier than the two-minute notice. With this on, the
  # ASG launches a replacement on that earlier signal instead of waiting for
  # the reclaim. This is the mechanism behind "Spot without losing availability".
  capacity_rebalance = true

  availability_zone_distribution {
    capacity_distribution_strategy = "balanced-best-effort"
  }

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 1
      on_demand_percentage_above_base_capacity = 0
      on_demand_allocation_strategy            = "prioritized"

      # capacity-optimized-prioritized honours the override order below as
      # best-effort while still preferring the deepest capacity pools.
      # price-capacity-optimized was considered and rejected: it ignores
      # override order for Spot, silently discarding the type prioritisation.
      spot_allocation_strategy = "capacity-optimized-prioritized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.demo.id
        version            = aws_launch_template.demo.latest_version
      }

      # Order is priority order.
      dynamic "override" {
        for_each = var.instance_types

        content {
          instance_type = override.value
        }
      }
    }
  }

  # Declared here rather than as separate aws_autoscaling_lifecycle_hook
  # resources on purpose. A separate resource is created after the ASG, so the
  # first instances would launch before the launch hook existed and reach
  # InService without waiting for nginx -- defeating the hook exactly once, on
  # the first apply, which is the hardest case to notice.
  initial_lifecycle_hook {
    name                 = local.launch_hook_name
    lifecycle_transition = "autoscaling:EC2_INSTANCE_LAUNCHING"
    heartbeat_timeout    = 300

    # Safe failure mode: an instance whose bootstrap never finishes is replaced
    # rather than joining the ALB half-built.
    default_result = "ABANDON"
  }

  # Holds a terminating instance for 60s and then proceeds on timeout. Nothing
  # completes this hook; that is deliberate. 60s exceeds the target group's 30s
  # deregistration delay, so draining finishes before termination proceeds --
  # a graceful drain by arithmetic rather than by a Lambda.
  initial_lifecycle_hook {
    name                 = local.terminate_hook_name
    lifecycle_transition = "autoscaling:EC2_INSTANCE_TERMINATING"
    heartbeat_timeout    = 60
    default_result       = "CONTINUE"
  }

  # Load-bearing: FIS target selection, the SSM Run Command filter and the
  # ec2:CreateTags IAM condition all match on Project=Demo, so it must reach
  # instances at launch.
  tag {
    key                 = "Project"
    value               = "Demo"
    propagate_at_launch = true
  }

  # Not propagated: instances name themselves in user-data. This Name is for the
  # ASG's own row in the console.
  tag {
    key                 = "Name"
    value               = local.asg_name
    propagate_at_launch = false
  }
}

# 10 is the t4g.micro credit baseline: 12 credits/hour / 2 vCPU / 60 min. The
# group therefore scales out before any instance draws down credit balance,
# keeping the CPU signal that drives this policy linear and trustworthy.
resource "aws_autoscaling_policy" "cpu" {
  name                   = "${var.name_prefix}-cpu-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.demo.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = var.cpu_target
  }
}
