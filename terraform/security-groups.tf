resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "Public HTTP ingress to the demo ALB"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.tags, { Name = "${var.name_prefix}-alb" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from anywhere"

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 80
  to_port     = 80
  ip_protocol = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "All outbound, so the ALB can reach its targets"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}

resource "aws_security_group" "instance" {
  name        = "${var.name_prefix}-instance"
  description = "HTTP from the ALB only; optional opt-in SSH"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.tags, { Name = "${var.name_prefix}-instance" })
}

# Referencing the ALB's security group rather than a CIDR means instances are
# unreachable from the internet on port 80 even though they sit in public subnets.
resource "aws_vpc_security_group_ingress_rule" "instance_http" {
  security_group_id            = aws_security_group.instance.id
  description                  = "HTTP from the ALB security group"
  referenced_security_group_id = aws_security_group.alb.id

  from_port   = 80
  to_port     = 80
  ip_protocol = "tcp"
}

# Off by default. Shell access is via SSM Session Manager, which needs no
# inbound rule at all. This exists only for someone cloning the repo who wants
# SSH with their own key pair.
resource "aws_vpc_security_group_ingress_rule" "instance_ssh" {
  count = var.ssh_ingress_cidr == null ? 0 : 1

  security_group_id = aws_security_group.instance.id
  description       = "Opt-in SSH from a single caller-supplied CIDR"

  cidr_ipv4   = var.ssh_ingress_cidr
  from_port   = 22
  to_port     = 22
  ip_protocol = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "instance_all" {
  security_group_id = aws_security_group.instance.id
  description       = "All outbound for Docker Hub, SSM and the Autoscaling API"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}
