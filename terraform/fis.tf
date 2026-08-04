# Stop condition for the experiment. Minimum statistic over a single 60s period
# so a real dip trips it quickly. treat_missing_data = notBreaching keeps the
# alarm from firing before the ALB has published any metrics.
resource "aws_cloudwatch_metric_alarm" "healthy_hosts" {
  alarm_name          = "${var.name_prefix}-healthy-hosts"
  alarm_description   = "Aborts the FIS experiment if the ALB runs out of healthy targets"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.demo.arn_suffix
    TargetGroup  = aws_lb_target_group.demo.arn_suffix
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-healthy-hosts" })
}

resource "aws_fis_experiment_template" "spot_interruption" {
  description = "Interrupt one Spot Instance in ${local.asg_name}"
  role_arn    = aws_iam_role.fis.arn

  # The AWS tutorial uses source = "none". This runs in front of an audience,
  # so it aborts instead of deepening an outage.
  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = aws_cloudwatch_metric_alarm.healthy_hosts.arn
  }

  action {
    name      = "interrupt-one-spot-instance"
    action_id = "aws:ec2:send-spot-instance-interruptions"

    # 2-15 minutes. PT5M, not the PT2M minimum: the rebalance recommendation
    # arrives immediately while the interruption notice arrives two minutes
    # before termination, so at PT2M both land together and Capacity
    # Rebalance's head start -- the thing worth showing -- is invisible.
    parameter {
      key   = "durationBeforeInterruption"
      value = var.fis_duration_before_interruption
    }

    # "SpotInstances" is the action's fixed target key, defined by AWS. It is
    # NOT the name of the target block below.
    target {
      key   = "SpotInstances"
      value = "one-spot-instance"
    }
  }

  target {
    name           = "one-spot-instance"
    resource_type  = "aws:ec2:spot-instance"
    selection_mode = "COUNT(1)"

    resource_tag {
      key   = "Project"
      value = "Demo"
    }

    filter {
      path   = "State.Name"
      values = ["running"]
    }
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-spot-interruption" })
}
