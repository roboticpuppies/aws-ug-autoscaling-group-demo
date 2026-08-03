data "aws_caller_identity" "current" {}

# --- Instance role -----------------------------------------------------------

data "aws_iam_policy_document" "instance_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.name_prefix}-instance"
  description        = "Demo instance role: SSM access, own lifecycle action, own Name tag"
  assume_role_policy = data.aws_iam_policy_document.instance_assume_role.json

  tags = local.tags
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name_prefix}-instance"
  role = aws_iam_role.instance.name

  tags = local.tags
}

# Session Manager and Run Command. This is why the demo needs no SSH key and no
# inbound port 22.
resource "aws_iam_role_policy_attachment" "instance_ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Lets user-data release the launch lifecycle hook once nginx answers.
data "aws_iam_policy_document" "instance_lifecycle" {
  statement {
    sid    = "CompleteOwnLifecycleAction"
    effect = "Allow"

    actions = [
      "autoscaling:CompleteLifecycleAction",
      "autoscaling:RecordLifecycleActionHeartbeat",
    ]

    # Built by interpolation, not from aws_autoscaling_group.demo.arn: the ASG
    # depends on this instance profile, so referencing it here would cycle.
    # The wildcard covers the ASG's generated UUID segment.
    resources = [
      "arn:aws:autoscaling:${var.region}:${data.aws_caller_identity.current.account_id}:autoScalingGroup:*:autoScalingGroupName/${local.asg_name}",
    ]
  }
}

resource "aws_iam_role_policy" "instance_lifecycle" {
  name   = "${var.name_prefix}-lifecycle"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance_lifecycle.json
}

# Lets an instance name itself <asg-name>-<last 5 of instance ID>.
#
# Both conditions matter. Together they mean an instance can write only the
# Name key, and only onto instances already tagged Project=Demo -- so it cannot
# rename anything else in the account, and cannot edit the Project tag that
# gates its own access.
#
# The aws:ResourceTag condition is evaluated against tags the instance ALREADY
# has, so this works only because the ASG propagates Project=Demo at launch.
# If that propagation is ever removed, self-naming starts failing with
# UnauthorizedOperation and nothing else visibly changes.
data "aws_iam_policy_document" "instance_self_tag" {
  statement {
    sid       = "NameOwnInstanceOnly"
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["Demo"]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = ["Name"]
    }
  }
}

resource "aws_iam_role_policy" "instance_self_tag" {
  name   = "${var.name_prefix}-self-tag"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance_self_tag.json
}

# --- FIS role ----------------------------------------------------------------

data "aws_iam_policy_document" "fis_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["fis.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fis" {
  name               = "${var.name_prefix}-fis"
  description        = "Role AWS FIS assumes to interrupt Spot Instances in this demo"
  assume_role_policy = data.aws_iam_policy_document.fis_assume_role.json

  tags = local.tags
}

# The managed policy the FIS actions reference names for
# aws:ec2:send-spot-instance-interruptions. It already grants exactly the two
# permissions that action needs: ec2:SendSpotInstanceInterruptions and
# ec2:DescribeInstances.
resource "aws_iam_role_policy_attachment" "fis_ec2" {
  role       = aws_iam_role.fis.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSFaultInjectionSimulatorEC2Access"
}

# Needed so the experiment can read its CloudWatch stop-condition alarm.
data "aws_iam_policy_document" "fis_cloudwatch" {
  statement {
    sid       = "ReadStopConditionAlarm"
    effect    = "Allow"
    actions   = ["cloudwatch:DescribeAlarms"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "fis_cloudwatch" {
  name   = "${var.name_prefix}-fis-cloudwatch"
  role   = aws_iam_role.fis.id
  policy = data.aws_iam_policy_document.fis_cloudwatch.json
}
