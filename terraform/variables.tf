variable "region" {
  description = "AWS region. Must be a region where AWS FIS is available; ap-southeast-3 is not."
  type        = string
  default     = "ap-southeast-1"
}

variable "name_prefix" {
  description = "Prefix for all resource names. The Auto Scaling group is named exactly this."
  type        = string
  default     = "asg-demo"
}

variable "vpc_cidr" {
  description = "CIDR block for the demo VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidrs" {
  description = "One public subnet CIDR per Availability Zone. Length determines how many AZs are used."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "instance_types" {
  description = "Instance types for the mixed instances policy, in priority order. All must be arm64 to match the AMI."
  type        = list(string)
  default     = ["t4g.micro", "t4g.small", "c6g.medium", "c6g.large"]
}

variable "min_size" {
  description = "Auto Scaling group minimum size."
  type        = number
  default     = 1
}

variable "desired_capacity" {
  description = "Auto Scaling group desired capacity. 3 means 1 On-Demand plus 2 Spot, so FIS always has a Spot instance to interrupt."
  type        = number
  default     = 3
}

variable "max_size" {
  description = "Auto Scaling group maximum size."
  type        = number
  default     = 5
}

variable "cpu_target" {
  description = "Target tracking CPU percentage. 10 is the t4g.micro credit baseline (12 credits/hour / 2 vCPU / 60 min), so the group scales out before instances draw down credit balance."
  type        = number
  default     = 10
}

variable "key_name" {
  description = "Optional existing EC2 key pair name. Leave null: access is via SSM Session Manager and no key material belongs in this repo."
  type        = string
  default     = null
}

variable "ssh_ingress_cidr" {
  description = "Optional CIDR allowed to reach port 22. Leave null to have no SSH surface at all. Never set this to 0.0.0.0/0."
  type        = string
  default     = null
}

variable "fis_duration_before_interruption" {
  description = "FIS durationBeforeInterruption, ISO 8601, valid range 2-15 minutes. PT5M separates the rebalance recommendation from the interruption notice enough to see both; PT2M makes them land together."
  type        = string
  default     = "PT5M"
}
