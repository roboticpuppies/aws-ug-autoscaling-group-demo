# AWS UG Auto-Scaling & Spot Demo — Implementation Plan

> **For agentic workers:** work through the tasks below in order. Each task's steps use checkbox (`- [ ]`) syntax for tracking. Run every check a task lists, and do not start the next task while one is failing.
>
> *If you are running inside Claude Code:* optionally use `superpowers:subagent-driven-development` or `superpowers:executing-plans` to drive this. *If you are any other agent* — Codex, Cursor, Gemini CLI, Copilot — ignore that sentence; those are Claude Code skills and have no meaning for you. Nothing else in this plan depends on them.
>
> Read `AGENTS.md` at the repository root before starting. It holds the conventions and the list of commands you must never run.

**Goal:** Build a Terraform + Packer stack in `ap-southeast-1` that demonstrates EC2 Auto Scaling with a mostly-Spot mixed instances policy, lifecycle hooks on both launch and terminate, and an AWS FIS Spot-interruption experiment, driven by a `make`-based command surface.

**Architecture:** A Packer-built Amazon Linux 2023 arm64 AMI carries Docker, AWS CLI v2 and `stress-ng`. Terraform creates a 3-AZ public VPC, an ALB, and an Auto Scaling group whose launch template boots that AMI; user-data starts nginx in Docker, names the instance after itself, and releases a launch lifecycle hook only once nginx answers. A separate AWS FIS experiment template injects a genuine Spot interruption on demand.

**Tech Stack:** Terraform `>= 1.6.0` with AWS provider `~> 6.0`, Packer `>= 1.9.0` with the `amazon` plugin `~> 1.3`, AWS CLI v2, GNU Make, Bash, Docker, nginx.

**Source of truth:** `docs/superpowers/specs/2026-08-04-asg-spot-demo-design.md`. That spec is reviewed and approved. Do not change any approved value in it (capacities, timeouts, targets, strategies) to make a task pass — if something in it appears wrong, stop and report rather than silently deviating.

---

## How this plan is verified (read before Task 1)

This project has **no unit tests and no test framework**, by design — the spec's Verification section says so explicitly. It is declarative infrastructure; there is nothing to unit-test, and real behavioural verification requires `terraform apply` against live AWS, which is human-gated (see Global Constraints).

So the usual write-failing-test-first cycle does not apply. Each task instead uses this cycle, and every check below is a real command with a deterministic pass/fail:

1. Write the file(s).
2. Run the static checks named in the task.
3. Confirm the exact expected output.
4. Commit.

The available static checks are:

| Check | Command | What it proves |
| --- | --- | --- |
| Terraform syntax + schema | `terraform -chdir=terraform validate` | Resource arguments, types and references are valid for AWS provider 6.x |
| Terraform formatting | `terraform -chdir=terraform fmt -check -recursive` | Canonical formatting |
| Packer syntax + schema | `cd packer && packer validate .` | Template and plugin arguments are valid |
| Shell syntax | `bash -n <file>` | The script parses |
| Shell linting | `shellcheck <file>` | Common shell bugs |
| Exact content | `grep -q '<literal>' <file>` | A specific required value is present |

`terraform validate` requires providers to be downloaded first. Task 1 runs `terraform -chdir=terraform init -backend=false`, which downloads the AWS provider over the network but makes **no AWS API calls and needs no credentials**. Run it once; later tasks reuse it.

`terraform validate` does **not** evaluate data sources, so tasks that add `data` blocks still validate offline. `terraform plan` *would* hit AWS — do not run it.

**The code in this plan has been validated as written.** Before this plan was committed, every HCL block was extracted into a scratch directory and checked with `terraform init -backend=false`, `terraform validate` and `terraform fmt -check -recursive`; the Packer template with `packer init` and `packer validate`; both shell files with `bash -n` and `shellcheck`; and the Makefile by running `make -n` against all 18 targets. All passed. Two bugs were found and fixed that way — a comment line beginning with `# shellcheck` that shellcheck parsed as a malformed directive, and a comment containing a literal dollar-brace sequence that Terraform tried to interpolate. So if a block fails for you, suspect a transcription slip (tabs converted to spaces in the Makefile is the likeliest) before suspecting the plan.

---

## Global Constraints

Every task's requirements implicitly include this section. Values are copied verbatim from the approved spec.

**Hard command gate — this is not negotiable.** You may run: `terraform fmt`, `terraform validate`, `terraform init -backend=false`, `packer init`, `packer validate`, `bash -n`, `shellcheck`, `grep`, `git`. You must **never** run: `terraform apply`, `terraform destroy`, `terraform plan`, `packer build`, or any `aws` CLI command that creates, modifies or deletes resources. Those create real billable AWS resources under the owner's credentials, and the owner runs them personally. If a task seems to require one, stop and report instead.

**Region:** `ap-southeast-1`. Never `ap-southeast-3` — AWS FIS does not exist there, which is why the region is what it is.

**Naming:** every resource name derives from `var.name_prefix`, default `"asg-demo"`. The Auto Scaling group name is exactly `var.name_prefix`.

**Tagging:** every taggable resource carries `Project = "Demo"`. This tag is load-bearing in three places — FIS target selection, the SSM Run Command target filter, and the `ec2:CreateTags` IAM condition — so it is never optional. Do **not** use provider-level `default_tags`; tag resources explicitly from `local.tags` so ASG tag propagation stays predictable.

**Secrets:** no private keys, no webhook URLs, no credentials in any file. `.gitignore` already blocks common key patterns.

**Capacities:** `min_size = 1`, `desired_capacity = 3`, `max_size = 5`.

**Instance types, in priority order:** `t4g.micro`, `t4g.small`, `c6g.medium`, `c6g.large`. All arm64; the AMI is arm64 and x86 types would fail to boot it.

**Mixed instances policy:** `on_demand_base_capacity = 1`, `on_demand_percentage_above_base_capacity = 0`, `on_demand_allocation_strategy = "prioritized"`, `spot_allocation_strategy = "capacity-optimized-prioritized"`.

**Capacity Rebalance:** `capacity_rebalance = true`.

**AZ distribution:** `capacity_distribution_strategy = "balanced-best-effort"`.

**Health check:** `health_check_type = "ELB"`, `health_check_grace_period = 300`.

**Lifecycle hooks:** launch — `autoscaling:EC2_INSTANCE_LAUNCHING`, heartbeat `300`, default result `ABANDON`. Terminate — `autoscaling:EC2_INSTANCE_TERMINATING`, heartbeat `60`, default result `CONTINUE`.

**Scaling policy:** target tracking on `ASGAverageCPUUtilization`, `target_value = 10`. This is the `t4g.micro` credit baseline (12 credits/hour ÷ 2 vCPU ÷ 60 min), not an arbitrary low number.

**Credit specification:** `cpu_credits = "unlimited"`, pinned explicitly in the launch template. Never `standard`.

**ALB / target group:** HTTP on port 80, health check path `/`, `interval = 15`, `timeout = 5`, `healthy_threshold = 2`, `deregistration_delay = 30`. The 30s deregistration delay must stay below the 60s terminate hook heartbeat.

**IMDS:** `http_tokens = "required"` (IMDSv2 only).

**FIS:** `action_id = "aws:ec2:send-spot-instance-interruptions"`, action target key exactly `SpotInstances`, parameter `durationBeforeInterruption = "PT5M"`, target `resource_type = "aws:ec2:spot-instance"`, `selection_mode = "COUNT(1)"`, resource tag `Project = Demo`, filter path `State.Name` value `running`, stop condition on a CloudWatch alarm.

**Two file-format rules that will silently bite you:**

1. In `terraform/templates/user-data.sh.tftpl`, **never write shell variables as `${VAR}`** — Terraform's `templatefile()` consumes `${...}` as its own interpolation. Always write `$VAR` without braces. This also keeps the raw file valid Bash so `bash -n` and `shellcheck` work on it directly.
2. In the `Makefile`, recipe lines **must** be indented with a literal TAB, never spaces. Inside recipes, a literal shell `$` must be written `$$`.

---

## File Structure

| Path | Responsibility |
| --- | --- |
| `AGENTS.md` | Already exists. Conventions and command gate for any agent working in this repo — read it, do not rewrite it |
| `packer/asg-demo.pkr.hcl` | AMI definition: source AMI filter, build, tags |
| `packer/scripts/provision.sh` | Package installation and assertions inside the AMI |
| `terraform/versions.tf` | Terraform and provider version pins, provider config |
| `terraform/variables.tf` | All input variables with defaults |
| `terraform/locals.tf` | Derived names and the shared tag map |
| `terraform/vpc.tf` | VPC, 3 public subnets, IGW, route table, associations |
| `terraform/security-groups.tf` | ALB and instance security groups and their rules |
| `terraform/iam.tf` | Instance role/profile with 3 policies; FIS role |
| `terraform/templates/user-data.sh.tftpl` | Instance bootstrap: self-naming, nginx, hook completion, failure handler |
| `terraform/launch-template.tf` | AMI lookup and launch template |
| `terraform/alb.tf` | ALB, target group, listener |
| `terraform/asg.tf` | ASG with mixed instances policy, initial lifecycle hooks, scaling policy |
| `terraform/fis.tf` | CloudWatch alarm and FIS experiment template |
| `terraform/outputs.tf` | Values the Makefile consumes |
| `Makefile` | Command surface, grouped by the human-gate boundary |
| `docs/*.md` | Six topic docs plus an index |
| `README.md` | Already written; only its status note is removed, in the final task |

Two deviations from the spec's illustrative layout, both deliberate: `locals.tf` is added (the spec did not list it, but the shared tag map and derived names need a home), and the launch template lives in its own `launch-template.tf` rather than inside `asg.tf`, because `asg.tf` is already the largest file and the two are separately reviewable.

---

### Task 1: Terraform skeleton

**Files:**
- Create: `terraform/versions.tf`
- Create: `terraform/variables.tf`
- Create: `terraform/locals.tf`

**Interfaces:**
- Consumes: nothing.
- Produces: `var.region`, `var.name_prefix`, `var.vpc_cidr`, `var.subnet_cidrs`, `var.instance_types`, `var.min_size`, `var.desired_capacity`, `var.max_size`, `var.cpu_target`, `var.key_name`, `var.ssh_ingress_cidr`, `var.fis_duration_before_interruption`; `local.asg_name`, `local.launch_hook_name`, `local.terminate_hook_name`, `local.tags`. Every later task uses these exact names.

- [x] **Step 1: Write `terraform/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# No default_tags here on purpose. Auto Scaling group tag propagation behaves
# more predictably when tags are declared explicitly, so resources take their
# tags from local.tags instead.
provider "aws" {
  region = var.region
}
```

- [x] **Step 2: Write `terraform/variables.tf`**

```hcl
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
```

- [x] **Step 3: Write `terraform/locals.tf`**

```hcl
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
```

- [x] **Step 4: Initialise providers (no AWS calls)**

Run: `terraform -chdir=terraform init -backend=false`

Expected: ends with `Terraform has been successfully initialized!`. It downloads `hashicorp/aws` v6.x. If it tries to contact AWS or asks for credentials, stop — something is wrong with the config.

- [x] **Step 5: Validate and check formatting**

Run:
```bash
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
```

Expected: `fmt -check` prints nothing and exits 0. `validate` prints `Success! The configuration is valid.`

If `fmt -check` lists files, run `terraform -chdir=terraform fmt -recursive` and re-check.

- [x] **Step 6: Confirm required values are present**

Run:
```bash
grep -q '"~> 6.0"' terraform/versions.tf
grep -q 'ap-southeast-1' terraform/variables.tf
grep -q 'default     = 10' terraform/variables.tf
grep -q '"PT5M"' terraform/variables.tf
grep -q 'Project = "Demo"' terraform/locals.tf
! grep -q 'default_tags' terraform/versions.tf
echo OK
```

Expected: prints `OK`. Any failure means a Global Constraint value is missing.

- [x] **Step 7: Commit**

```bash
git add terraform/versions.tf terraform/variables.tf terraform/locals.tf
git commit -m "Add Terraform skeleton"
```

---

### Task 2: Packer AMI

**Files:**
- Create: `packer/asg-demo.pkr.hcl`
- Create: `packer/scripts/provision.sh`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: AMIs named `asg-demo-<timestamp>` tagged `Project=Demo`. Task 7's `data "aws_ami" "demo"` finds them by that name prefix and tag, so the `ami_name` prefix and the `Project=Demo` tag must not drift.

The source AMI is selected with `source_ami_filter` rather than an SSM-parameter data source, deliberately: Packer evaluates HCL data sources during `packer validate`, which would require AWS credentials and break credential-free validation. `source_ami_filter` resolves at build time instead.

- [x] **Step 1: Write `packer/asg-demo.pkr.hcl`**

```hcl
packer {
  required_version = ">= 1.9.0"

  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1.3"
    }
  }
}

variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "name_prefix" {
  type    = string
  default = "asg-demo"
}

locals {
  timestamp = regex_replace(timestamp(), "[- TZ:]", "")
  ami_name  = "${var.name_prefix}-${local.timestamp}"
}

# Resolved at build time, not at validate time. A data source here would make
# `packer validate` require AWS credentials.
source "amazon-ebs" "al2023" {
  region        = var.region
  instance_type = "t4g.micro"
  ssh_username  = "ec2-user"
  ami_name      = local.ami_name

  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023*-arm64"
      architecture        = "arm64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  tags = {
    Name      = local.ami_name
    Project   = "Demo"
    BuildTime = local.timestamp
  }

  snapshot_tags = {
    Name    = local.ami_name
    Project = "Demo"
  }
}

build {
  name    = "asg-demo"
  sources = ["source.amazon-ebs.al2023"]

  provisioner "shell" {
    script          = "${path.root}/scripts/provision.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
  }
}
```

- [x] **Step 2: Write `packer/scripts/provision.sh`**

```bash
#!/usr/bin/env bash
#
# Runs as root inside the Packer build instance. Everything installed here is
# something the demo would otherwise have to install at boot, on stage.
set -euo pipefail

log() {
  echo "[provision] $*"
}

log "updating base packages"
dnf -y update

log "installing docker and stress-ng"
dnf -y install docker stress-ng

# AL2023 already ships AWS CLI v2. Install explicitly anyway so the AMI's
# contents are not left to base-image drift, but tolerate the package being
# absent or already satisfied -- the assertion below is what actually matters.
log "ensuring AWS CLI v2 is present"
dnf -y install awscli-2 || log "awscli-2 not installed via dnf; relying on the preinstalled CLI"

log "enabling docker"
systemctl enable --now docker

# Pre-pull the web server image so user-data's docker pull is a cache hit and
# scale-out is fast in front of an audience.
log "pre-pulling nginx:alpine"
docker pull nginx:alpine

log "asserting the AMI contains what the demo needs"
docker --version
stress-ng --version
aws --version

# Hard-fail the build if the CLI is not v2. v1 has different command output and
# would break the lifecycle-hook calls in user-data.
if ! aws --version 2>&1 | grep -q 'aws-cli/2'; then
  log "ERROR: AWS CLI v2 is required but not present"
  exit 1
fi

log "verifying nginx:alpine is in the local image cache"
docker image inspect nginx:alpine >/dev/null

log "done"
```

- [x] **Step 3: Check the provisioner script parses and lints clean**

Run:
```bash
bash -n packer/scripts/provision.sh
shellcheck packer/scripts/provision.sh
```

Expected: both silent, exit 0.

- [x] **Step 4: Initialise the Packer plugin and validate**

Run:
```bash
cd packer && packer init . && packer validate .
```

Expected: `packer init` installs the amazon plugin; `packer validate` prints `The configuration is valid.`

If validate complains about credentials, a data source has crept in — remove it and use `source_ami_filter`.

- [x] **Step 5: Confirm required values are present**

Run:
```bash
grep -q 'source_ami_filter' packer/asg-demo.pkr.hcl
grep -q '"arm64"' packer/asg-demo.pkr.hcl
grep -q 'Project   = "Demo"' packer/asg-demo.pkr.hcl
grep -q 'dnf -y install docker stress-ng' packer/scripts/provision.sh
grep -q 'docker pull nginx:alpine' packer/scripts/provision.sh
grep -q "aws-cli/2" packer/scripts/provision.sh
! grep -q 'amazon-parameterstore' packer/asg-demo.pkr.hcl
echo OK
```

Expected: prints `OK`.

- [x] **Step 6: Commit**

```bash
git add packer/
git commit -m "Add Packer template for the demo AMI"
```

> **Note for the repository owner, not a task step:** the `awscli-2` dnf package name is the one uncertainty in this task. The script tolerates its absence and hard-asserts `aws-cli/2` instead, so the build fails loudly rather than producing a subtly broken AMI. Confirm on the first `make ami`.

---

### Task 3: VPC and networking

**Files:**
- Create: `terraform/vpc.tf`

**Interfaces:**
- Consumes: `var.vpc_cidr`, `var.subnet_cidrs`, `var.name_prefix`, `local.tags`.
- Produces: `aws_vpc.main` (referenced by both security groups and the target group) and `aws_subnet.public` — a **list** of 3 subnets, referenced later as `aws_subnet.public[*].id`.

- [x] **Step 1: Write `terraform/vpc.tf`**

```hcl
data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = var.name_prefix })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.tags, { Name = var.name_prefix })
}

# Public subnets only. Instances need outbound reach for Docker Hub, SSM and the
# Autoscaling API; a NAT gateway would add cost and one more thing to explain
# for no demo value.
resource "aws_subnet" "public" {
  count = length(var.subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.tags, { Name = "${var.name_prefix}-public-${count.index + 1}" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-public" })
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
```

- [x] **Step 2: Validate and check formatting**

Run:
```bash
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
```

Expected: `fmt -check` silent; `validate` prints `Success! The configuration is valid.`

- [x] **Step 3: Confirm required values are present**

Run:
```bash
grep -q 'map_public_ip_on_launch = true' terraform/vpc.tf
grep -q 'count = length(var.subnet_cidrs)' terraform/vpc.tf
grep -q 'data "aws_availability_zones" "available"' terraform/vpc.tf
! grep -q 'aws_nat_gateway' terraform/vpc.tf
echo OK
```

Expected: prints `OK`. The last check matters: a NAT gateway is an explicit non-goal and the single most expensive thing that could sneak into this stack.

- [x] **Step 4: Commit**

```bash
git add terraform/vpc.tf
git commit -m "Add demo VPC with three public subnets"
```

---

### Task 4: Security groups

**Files:**
- Create: `terraform/security-groups.tf`

**Interfaces:**
- Consumes: `aws_vpc.main.id`, `var.name_prefix`, `var.ssh_ingress_cidr`, `local.tags`.
- Produces: `aws_security_group.alb` (used by the ALB) and `aws_security_group.instance` (used by the launch template).

Rules use the modern `aws_vpc_security_group_ingress_rule` / `..._egress_rule` resources rather than inline `ingress`/`egress` blocks — one rule per resource, so a plan diff names exactly which rule changed.

- [x] **Step 1: Write `terraform/security-groups.tf`**

```hcl
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
```

- [x] **Step 2: Validate and check formatting**

Run:
```bash
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
```

Expected: `fmt -check` silent; `validate` prints `Success! The configuration is valid.`

- [x] **Step 3: Confirm the SSH rule is opt-in and instance HTTP is ALB-only**

Run:
```bash
grep -q 'count = var.ssh_ingress_cidr == null ? 0 : 1' terraform/security-groups.tf
grep -q 'referenced_security_group_id = aws_security_group.alb.id' terraform/security-groups.tf
test "$(grep -c 'from_port   = 22' terraform/security-groups.tf)" -eq 1
echo OK
```

Expected: prints `OK`. This proves port 22 appears exactly once and only inside the counted, default-disabled rule, and that instance HTTP ingress is scoped to the ALB's security group rather than a CIDR.

- [x] **Step 4: Commit**

```bash
git add terraform/security-groups.tf
git commit -m "Add ALB and instance security groups"
```

---

### Task 5: IAM roles and policies

**Files:**
- Create: `terraform/iam.tf`

**Interfaces:**
- Consumes: `var.name_prefix`, `var.region`, `local.asg_name`, `local.tags`.
- Produces: `aws_iam_instance_profile.instance` (its `.arn` is used by the launch template) and `aws_iam_role.fis` (its `.arn` is used by the FIS experiment template). Also `data.aws_caller_identity.current`, reused by no other task but referenced here.

Region comes from `var.region`, not a `data "aws_region"` lookup — the attribute for that data source was renamed between provider major versions, and there is no reason to depend on it when the region is already an input.

The Auto Scaling group ARN is built by string interpolation rather than read from `aws_autoscaling_group.demo.arn`. That is not laziness: the ASG depends on the instance profile, so reading the ASG's ARN here would create a dependency cycle. The `autoScalingGroup:*` segment wildcards the ASG's generated UUID.

- [x] **Step 1: Write `terraform/iam.tf`**

```hcl
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
```

- [x] **Step 2: Validate and check formatting**

Run:
```bash
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
```

Expected: `fmt -check` silent; `validate` prints `Success! The configuration is valid.`

- [x] **Step 3: Confirm both `ec2:CreateTags` conditions are present**

Run:
```bash
grep -q '"aws:ResourceTag/Project"' terraform/iam.tf
grep -q '"ForAllValues:StringEquals"' terraform/iam.tf
grep -q '"aws:TagKeys"' terraform/iam.tf
grep -q 'AmazonSSMManagedInstanceCore' terraform/iam.tf
grep -q 'service-role/AWSFaultInjectionSimulatorEC2Access' terraform/iam.tf
grep -q 'autoScalingGroupName/${local.asg_name}' terraform/iam.tf
! grep -q 'data "aws_region"' terraform/iam.tf
echo OK
```

Expected: prints `OK`. If either `ec2:CreateTags` condition is missing, the policy is far broader than intended — an instance could rename arbitrary instances in the account.

- [x] **Step 4: Commit**

```bash
git add terraform/iam.tf
git commit -m "Add instance and FIS IAM roles"
```

> **Note for the repository owner, not a task step:** `arn:aws:iam::aws:policy/service-role/AWSFaultInjectionSimulatorEC2Access` is the one ARN in this plan that static validation cannot confirm — a wrong path fails only at `apply`. Verify with `aws iam get-policy --policy-arn arn:aws:iam::aws:policy/service-role/AWSFaultInjectionSimulatorEC2Access` before the first apply.

---

### Task 6: User-data bootstrap script

**Files:**
- Create: `terraform/templates/user-data.sh.tftpl`

**Interfaces:**
- Consumes: three `templatefile()` variables, supplied by Task 7 — `asg_name`, `launch_hook_name`, `region`. No others.
- Produces: the served document root `/opt/demo/html` containing `index.html` and `name.txt`. `name.txt` holds one line, `<instance-name> <lifecycle> <az>`, which `make poll` (Task 11) curls and prints. That contract must not change.

**Read the format rule before writing a character of this file.** Terraform's `templatefile()` consumes `${...}`. Write every shell variable as `$VAR`, never `${VAR}`. Keeping braces out has a second benefit: the raw template stays valid Bash, so `bash -n` and `shellcheck` run on it directly. The only `${...}` occurrences in the finished file are the three Terraform variables above.

- [x] **Step 1: Write `terraform/templates/user-data.sh.tftpl`**

```bash
#!/usr/bin/env bash
#
# Instance bootstrap for the AWS UG Auto Scaling / Spot demo.
#
# Rendered by Terraform's templatefile(). Terraform consumes dollar-brace
# interpolations, so every SHELL variable below is written $VAR with no braces.
# The only dollar-brace expressions in this file are the three Terraform
# variables: asg_name, launch_hook_name, region. Note that even a COMMENT
# containing a dollar-brace sequence is interpolated and will fail the render,
# which is why this paragraph spells it out in words.
#
# Keeping braces out of shell variables also leaves this file valid Bash, so
# static checks run on it as-is.
#
# shellcheck disable=SC2154  # asg_name/launch_hook_name/region come from Terraform.
set -euo pipefail

exec > >(tee -a /var/log/user-data.log) 2>&1

ASG_NAME="${asg_name}"
LAUNCH_HOOK_NAME="${launch_hook_name}"
export AWS_DEFAULT_REGION="${region}"

# Set before the ERR trap is installed so on_failure can test it safely under
# `set -u` even if we die before reading instance metadata.
INSTANCE_ID=""

log() {
  echo "[user-data $(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

notify_failure() {
  local failed_line="$1"

  # INTENTIONALLY NOT IMPLEMENTED. This is a demo; the comment is the point.
  #
  # In a real deployment this is where a failed bootstrap becomes someone's
  # problem instead of a silent instance replacement. It would POST to a Slack
  # (or equivalent) incoming webhook with enough context to triage without
  # opening a shell anywhere:
  #
  #   - instance ID, the self-assigned Name tag, AZ, instance type
  #   - whether this was a Spot or an On-Demand instance
  #   - the line number that failed
  #   - the last ~50 lines of /var/log/user-data.log
  #
  # The webhook URL MUST NOT be hardcoded here, and MUST NOT be passed in as a
  # Terraform variable rendered into user-data. User-data is readable through
  # the instance metadata service by any process or user on this instance, and
  # is visible to anyone holding ec2:DescribeLaunchTemplateVersions. A webhook
  # URL is a credential: whoever holds it can post into the channel. Fetch it
  # at runtime from Secrets Manager or SSM Parameter Store using the instance
  # role, which also gets you rotation and an audit trail.
  log "notify_failure: stub only, nothing sent (line $failed_line)"
}

on_failure() {
  local failed_line="$1"

  # Drop the trap first so a failure inside this handler cannot recurse.
  trap - ERR

  log "FAILED at line $failed_line -- abandoning this instance"

  # ABANDON first: it is the time-sensitive part. Notification is best effort,
  # and a hanging webhook must never delay the ASG replacing a dead instance.
  if [ -n "$INSTANCE_ID" ]; then
    aws autoscaling complete-lifecycle-action \
      --lifecycle-hook-name "$LAUNCH_HOOK_NAME" \
      --auto-scaling-group-name "$ASG_NAME" \
      --instance-id "$INSTANCE_ID" \
      --lifecycle-action-result ABANDON \
      || log "WARN: could not complete lifecycle action; the hook will time out to ABANDON"
  else
    log "WARN: no instance ID yet; leaving the hook to time out to ABANDON"
  fi

  notify_failure "$failed_line"
  exit 1
}

trap 'on_failure $LINENO' ERR

# --- Identity ----------------------------------------------------------------

log "reading instance metadata (IMDSv2)"
TOKEN="$(curl -sf -X PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')"

imds() {
  curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
    "http://169.254.169.254/latest/meta-data/$1"
}

INSTANCE_ID="$(imds instance-id)"
AZ="$(imds placement/availability-zone)"
INSTANCE_TYPE="$(imds instance-type)"

# instance-life-cycle returns "spot" or "on-demand".
LIFECYCLE="$(imds instance-life-cycle)"

# Last 5 characters of the instance ID, Kubernetes-pod style. printf avoids the
# trailing newline that echo would add, so tail counts real characters.
SUFFIX="$(printf '%s' "$INSTANCE_ID" | tail -c 5)"
INSTANCE_NAME="$ASG_NAME-$SUFFIX"

log "this instance is $INSTANCE_NAME ($INSTANCE_TYPE, $LIFECYCLE, $AZ)"

# --- Self-naming -------------------------------------------------------------

# Cosmetic, and deliberately non-fatal: `|| log` keeps a failure here from
# tripping the ERR trap and abandoning an otherwise healthy instance. Only nginx
# failing to answer is worth abandoning over.
log "tagging self as $INSTANCE_NAME"
aws ec2 create-tags \
  --resources "$INSTANCE_ID" \
  --tags Key=Name,Value="$INSTANCE_NAME" \
  || log "WARN: self-tagging failed, continuing -- the Name tag is cosmetic"

# --- Content -----------------------------------------------------------------

log "writing the document root"
mkdir -p /opt/demo/html

# One machine-readable line, curled by `make poll`. Keep this format stable.
printf '%s %s %s\n' "$INSTANCE_NAME" "$LIFECYCLE" "$AZ" > /opt/demo/html/name.txt

cat > /opt/demo/html/index.html <<HTML
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>$INSTANCE_NAME</title></head>
<body style="font-family: system-ui, sans-serif; font-size: 1.5rem; padding: 2rem">
  <h1>$INSTANCE_NAME</h1>
  <p>instance-id: $INSTANCE_ID</p>
  <p>instance-type: $INSTANCE_TYPE</p>
  <p>availability-zone: $AZ</p>
  <p>purchase-option: <strong>$LIFECYCLE</strong></p>
</body>
</html>
HTML

# --- Web server --------------------------------------------------------------

# Cache hit: the AMI already carries this image, so scale-out is fast on stage.
log "starting nginx"
docker pull nginx:alpine
docker run -d --name web -p 80:80 \
  -v /opt/demo/html:/usr/share/nginx/html:ro \
  nginx:alpine

log "waiting for nginx to answer on port 80"
for attempt in $(seq 1 30); do
  if curl -fs -o /dev/null http://localhost:80/; then
    log "nginx is answering after $attempt attempt(s)"
    break
  fi

  if [ "$attempt" -eq 30 ]; then
    log "nginx did not answer after 30 attempts"
    # Trips the ERR trap, which ABANDONs this instance.
    false
  fi

  sleep 2
done

# --- Release the launch hook -------------------------------------------------

# The whole point of the launch hook: this instance joins the load balancer
# because the APPLICATION is ready, not because EC2 finished booting.
log "releasing the launch lifecycle hook"
aws autoscaling complete-lifecycle-action \
  --lifecycle-hook-name "$LAUNCH_HOOK_NAME" \
  --auto-scaling-group-name "$ASG_NAME" \
  --instance-id "$INSTANCE_ID" \
  --lifecycle-action-result CONTINUE

log "bootstrap complete"
```

- [x] **Step 2: Verify the template is valid Bash as written**

Run:
```bash
bash -n terraform/templates/user-data.sh.tftpl
shellcheck --shell=bash terraform/templates/user-data.sh.tftpl
```

Expected: both silent, exit 0.

If `bash -n` reports a syntax error, you almost certainly wrote a shell variable as `${VAR}` — Bash accepts that, but check the next step, which is the one that catches it.

- [x] **Step 3: Prove nothing but the three Terraform variables uses brace syntax**

Run:
```bash
grep -o '\${[^}]*}' terraform/templates/user-data.sh.tftpl | sort -u
```

Expected output, exactly these three lines and nothing else:
```
${asg_name}
${launch_hook_name}
${region}
```

The pattern is deliberately `[^}]*` rather than `[a-z_]*`: Terraform interpolates **every** dollar-brace sequence in the file, including ones inside comments and heredocs. A narrower pattern would miss those, and the failure surfaces two tasks later as an opaque `templatefile` error.

Any extra entry is either a shell variable that Terraform will try to interpolate, or prose in a comment. Rewrite shell variables as `$VAR`; reword comments to describe the syntax in words instead of showing it.

- [x] **Step 4: Confirm the required behaviours are present**

Run:
```bash
grep -q 'set -euo pipefail' terraform/templates/user-data.sh.tftpl
grep -q "trap 'on_failure \$LINENO' ERR" terraform/templates/user-data.sh.tftpl
grep -q 'trap - ERR' terraform/templates/user-data.sh.tftpl
grep -q 'lifecycle-action-result ABANDON' terraform/templates/user-data.sh.tftpl
grep -q 'lifecycle-action-result CONTINUE' terraform/templates/user-data.sh.tftpl
grep -q 'WARN: self-tagging failed' terraform/templates/user-data.sh.tftpl
grep -q 'Secrets Manager or SSM Parameter Store' terraform/templates/user-data.sh.tftpl
grep -q 'tail -c 5' terraform/templates/user-data.sh.tftpl
grep -q '/opt/demo/html/name.txt' terraform/templates/user-data.sh.tftpl
grep -q 'X-aws-ec2-metadata-token' terraform/templates/user-data.sh.tftpl
echo OK
```

Expected: prints `OK`.

- [x] **Step 5: Confirm ABANDON is sent before notifying**

Run:
```bash
awk '/^on_failure\(\)/,/^}/' terraform/templates/user-data.sh.tftpl \
  | grep -n -e '--lifecycle-action-result ABANDON' -e '^  notify_failure "'
```

Expected: exactly two matching lines, with `--lifecycle-action-result ABANDON` on the **lower** line number. Notification is best effort; a hanging webhook must not delay instance replacement.

The patterns are deliberately narrow — matching bare `ABANDON` also hits the explanatory comments in that function, which would make the check pass for the wrong reason.

- [x] **Step 6: Commit**

```bash
git add terraform/templates/user-data.sh.tftpl
git commit -m "Add instance bootstrap script with failure handler"
```

---

### Task 7: AMI lookup and launch template

**Files:**
- Create: `terraform/launch-template.tf`

**Interfaces:**
- Consumes: `aws_security_group.instance.id`, `aws_iam_instance_profile.instance.arn`, `local.asg_name`, `local.launch_hook_name`, `local.tags`, `var.instance_types`, `var.key_name`, `var.region`, `var.name_prefix`, and `terraform/templates/user-data.sh.tftpl`.
- Produces: `aws_launch_template.demo`, consumed by Task 9 via `.id` and `.latest_version`.

Two things not to add here. Do **not** set `instance_market_options` — Spot purchasing belongs to the ASG's mixed instances policy, and setting it in both places conflicts. Do **not** add a `Name` tag to the instance `tag_specifications` — instances name themselves in user-data, and propagating a Name here would mean writing one value only to overwrite it seconds later.

- [x] **Step 1: Write `terraform/launch-template.tf`**

```hcl
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
```

- [x] **Step 2: Validate and check formatting**

Run:
```bash
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
```

Expected: `fmt -check` silent; `validate` prints `Success! The configuration is valid.`

This step also proves the Task 6 template renders: `validate` evaluates `templatefile()` and fails if the template references a variable that is not passed in.

- [x] **Step 3: Confirm required settings and forbidden ones**

Run:
```bash
grep -q 'cpu_credits = "unlimited"' terraform/launch-template.tf
grep -q 'http_tokens                 = "required"' terraform/launch-template.tf
grep -q 'templatefile("${path.module}/templates/user-data.sh.tftpl"' terraform/launch-template.tf
! grep -q 'instance_market_options' terraform/launch-template.tf
! grep -q 'cpu_credits = "standard"' terraform/launch-template.tf
echo OK
```

Expected: prints `OK`. The two negative checks guard the traps called out above.

- [x] **Step 4: Commit**

```bash
git add terraform/launch-template.tf
git commit -m "Add launch template and AMI lookup"
```

---

### Task 8: Application Load Balancer

**Files:**
- Create: `terraform/alb.tf`

**Interfaces:**
- Consumes: `aws_subnet.public[*].id`, `aws_security_group.alb.id`, `aws_vpc.main.id`, `var.name_prefix`, `local.tags`.
- Produces: `aws_lb.demo` (`.dns_name`, `.arn_suffix`) and `aws_lb_target_group.demo` (`.arn`, `.arn_suffix`), consumed by Tasks 9, 10 and 11.

`deregistration_delay = 30` is coupled to the 60s terminate lifecycle hook in Task 9: draining finishes inside the hold, so in-flight requests complete instead of being cut. Do not raise one without the other.

- [x] **Step 1: Write `terraform/alb.tf`**

```hcl
resource "aws_lb" "demo" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = merge(local.tags, { Name = "${var.name_prefix}-alb" })
}

resource "aws_lb_target_group" "demo" {
  name     = "${var.name_prefix}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  # Coupled to the 60s terminate lifecycle hook in asg.tf: draining completes
  # inside that hold, so connections finish rather than being cut. Raising this
  # above 60 breaks that property.
  deregistration_delay = 30

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-tg" })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.demo.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.demo.arn
  }

  tags = local.tags
}
```

- [x] **Step 2: Validate and check formatting**

Run:
```bash
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
```

Expected: `fmt -check` silent; `validate` prints `Success! The configuration is valid.`

- [x] **Step 3: Confirm health check and drain values**

Run:
```bash
grep -q 'deregistration_delay = 30' terraform/alb.tf
grep -q 'interval            = 15' terraform/alb.tf
grep -q 'timeout             = 5' terraform/alb.tf
grep -q 'healthy_threshold   = 2' terraform/alb.tf
grep -q 'path                = "/"' terraform/alb.tf
echo OK
```

Expected: prints `OK`.

- [x] **Step 4: Commit**

```bash
git add terraform/alb.tf
git commit -m "Add ALB, target group and listener"
```

---

### Task 9: Auto Scaling group, lifecycle hooks and scaling policy

**Files:**
- Create: `terraform/asg.tf`

**Interfaces:**
- Consumes: `aws_launch_template.demo.id` / `.latest_version`, `aws_subnet.public[*].id`, `aws_lb_target_group.demo.arn`, `local.asg_name`, `local.launch_hook_name`, `local.terminate_hook_name`, and the capacity/type/target variables.
- Produces: `aws_autoscaling_group.demo` (`.name`), consumed by Task 11's outputs.

**The single most important detail in this task:** both lifecycle hooks are declared as `initial_lifecycle_hook` blocks **inside** `aws_autoscaling_group`, not as separate `aws_autoscaling_lifecycle_hook` resources. A separate resource is created *after* the ASG, which means the first instances launch before the launch hook exists — they would sail straight to `InService` without waiting for nginx, silently defeating the hook on the very first apply. `initial_lifecycle_hook` exists precisely to close that race.

- [x] **Step 1: Write `terraform/asg.tf`**

```hcl
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
```

- [x] **Step 2: Validate and check formatting**

Run:
```bash
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
```

Expected: `fmt -check` silent; `validate` prints `Success! The configuration is valid.`

- [x] **Step 3: Confirm every mixed-instances and hook value**

Run:
```bash
grep -q 'capacity_rebalance = true' terraform/asg.tf
grep -q 'spot_allocation_strategy = "capacity-optimized-prioritized"' terraform/asg.tf
grep -q 'on_demand_allocation_strategy            = "prioritized"' terraform/asg.tf
grep -q 'on_demand_base_capacity                  = 1' terraform/asg.tf
grep -q 'on_demand_percentage_above_base_capacity = 0' terraform/asg.tf
grep -q 'capacity_distribution_strategy = "balanced-best-effort"' terraform/asg.tf
grep -q 'health_check_type         = "ELB"' terraform/asg.tf
grep -q 'health_check_grace_period = 300' terraform/asg.tf
grep -q '"ASGAverageCPUUtilization"' terraform/asg.tf
echo OK
```

Expected: prints `OK`.

- [x] **Step 4: Confirm hooks are declared as initial hooks, with the right timeouts**

Run:
```bash
test "$(grep -c 'initial_lifecycle_hook' terraform/asg.tf)" -eq 2
! grep -q 'resource "aws_autoscaling_lifecycle_hook"' terraform/asg.tf
grep -q 'heartbeat_timeout    = 300' terraform/asg.tf
grep -q 'heartbeat_timeout    = 60' terraform/asg.tf
grep -q 'default_result = "ABANDON"' terraform/asg.tf
grep -q 'default_result       = "CONTINUE"' terraform/asg.tf
echo OK
```

Expected: prints `OK`. If the second check fails, the launch-hook race described above is present.

- [x] **Step 5: Confirm `price-capacity-optimized` was not used**

Run:
```bash
! grep -q '"price-capacity-optimized"' terraform/asg.tf && echo OK
```

Expected: prints `OK`. That strategy ignores override order for Spot, which would discard the instance type prioritisation.

- [x] **Step 6: Commit**

```bash
git add terraform/asg.tf
git commit -m "Add Auto Scaling group with mixed instances policy and lifecycle hooks"
```

---

### Task 10: CloudWatch alarm and FIS experiment template

**Files:**
- Create: `terraform/fis.tf`

**Interfaces:**
- Consumes: `aws_lb.demo.arn_suffix`, `aws_lb_target_group.demo.arn_suffix`, `aws_iam_role.fis.arn`, `local.asg_name`, `local.tags`, `var.name_prefix`, `var.fis_duration_before_interruption`.
- Produces: `aws_fis_experiment_template.spot_interruption` (`.id`), consumed by Task 11's outputs.

Every field name here was verified against the AWS FIS actions reference and the Spot-interruption tutorial. They are easy to get subtly wrong and static validation cannot catch a wrong-but-well-formed key. In particular the action's target key is the literal string `SpotInstances` — it is **not** the name of your target block.

Unlike the AWS tutorial, which uses `stop_condition { source = "none" }`, this template stops on a CloudWatch alarm. This runs in front of an audience; an experiment that keeps going while healthy hosts hit zero is worse than one that aborts.

- [x] **Step 1: Write `terraform/fis.tf`**

```hcl
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
```

- [x] **Step 2: Validate and check formatting**

Run:
```bash
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
```

Expected: `fmt -check` silent; `validate` prints `Success! The configuration is valid.`

- [x] **Step 3: Confirm every FIS field matches the verified values**

Run:
```bash
grep -q '"aws:ec2:send-spot-instance-interruptions"' terraform/fis.tf
grep -q 'key   = "SpotInstances"' terraform/fis.tf
grep -q 'key   = "durationBeforeInterruption"' terraform/fis.tf
grep -q 'resource_type  = "aws:ec2:spot-instance"' terraform/fis.tf
grep -q 'selection_mode = "COUNT(1)"' terraform/fis.tf
grep -q 'path   = "State.Name"' terraform/fis.tf
grep -q 'values = \["running"\]' terraform/fis.tf
grep -q 'source = "aws:cloudwatch:alarm"' terraform/fis.tf
! grep -q 'source = "none"' terraform/fis.tf
echo OK
```

Expected: prints `OK`. A wrong-but-well-formed key here fails only at experiment start, in front of an audience.

- [x] **Step 4: Commit**

```bash
git add terraform/fis.tf
git commit -m "Add FIS Spot interruption experiment and its stop-condition alarm"
```

---

### Task 11: Outputs and Makefile

**Files:**
- Create: `terraform/outputs.tf`
- Create: `Makefile`

**Interfaces:**
- Consumes: `aws_lb.demo.dns_name`, `aws_autoscaling_group.demo.name`, `aws_lb_target_group.demo.arn`, `aws_fis_experiment_template.spot_interruption.id`, `var.region`; and the `/opt/demo/html/name.txt` contract from Task 6.
- Produces: outputs `alb_dns_name`, `asg_name`, `target_group_arn`, `fis_experiment_template_id`, `region` — the Makefile reads all five, so these names are a contract.

Outputs and the Makefile ship together because the Makefile is the only consumer of the outputs; reviewing one without the other is meaningless.

**Two Makefile format rules.** Recipe lines must be indented with a literal **TAB**, not spaces — spaces produce `missing separator`. A literal shell `$` must be written `$$`, because make expands `$` first.

Demo recipes are deliberately **not** silenced with `@`. On stage the audience should see the real AWS CLI call scroll past while the presenter typed three words. Only `help` and multi-line shell loops are silenced, because echoing those is noise rather than information.

- [x] **Step 1: Write `terraform/outputs.tf`**

```hcl
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
```

- [x] **Step 2: Write the `Makefile`** (remember: TABs, and `$$` for shell `$`)

```make
# Command surface for the AWS UG Auto Scaling / Spot demo.
#
# Targets are grouped by who may run them. Agents may run the "checks" group.
# Everything under "stack lifecycle" and "demo" touches real, billable AWS
# resources and is run by a human.
#
# Recipes are intentionally not silenced with @: on stage the audience should
# see the real AWS CLI command scroll past.

SHELL := /usr/bin/env bash
TF    := terraform -chdir=terraform

# Recursive (=, not :=) so terraform output only runs when a target needs it.
REGION       = $(shell $(TF) output -raw region 2>/dev/null || echo ap-southeast-1)
ASG_NAME     = $(shell $(TF) output -raw asg_name)
TG_ARN       = $(shell $(TF) output -raw target_group_arn)
FIS_TEMPLATE = $(shell $(TF) output -raw fis_experiment_template_id)
ALB_URL      = http://$(shell $(TF) output -raw alb_dns_name)

.DEFAULT_GOAL := help
.PHONY: help fmt validate ami init plan apply destroy clean-ami \
        url poll status activity targets stress unstress interrupt session

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

# --- Checks (safe for agents; no AWS credentials required) -------------------

fmt: ## Format Terraform files
	$(TF) fmt -recursive

validate: ## Validate Terraform and Packer
	$(TF) init -backend=false
	$(TF) fmt -check -recursive
	$(TF) validate
	cd packer && packer init . && packer validate .

# --- Stack lifecycle (human only; creates billable resources) ---------------

ami: ## Build the AMI with Packer
	cd packer && packer init . && packer build .

init: ## terraform init
	$(TF) init

plan: ## terraform plan
	$(TF) plan

apply: ## terraform apply
	$(TF) apply

destroy: ## terraform destroy (prompts for confirmation)
	$(TF) destroy

clean-ami: ## Deregister demo AMIs and delete their snapshots (terraform does not own these)
	@for ami in $$(aws ec2 describe-images --region $(REGION) --owners self \
	    --filters 'Name=tag:Project,Values=Demo' \
	    --query 'Images[].ImageId' --output text); do \
	  snap=$$(aws ec2 describe-images --region $(REGION) --image-ids $$ami \
	    --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' --output text); \
	  echo "deregistering $$ami (snapshot $$snap)"; \
	  aws ec2 deregister-image --region $(REGION) --image-id $$ami; \
	  aws ec2 delete-snapshot --region $(REGION) --snapshot-id $$snap; \
	done

# --- Demo drivers -----------------------------------------------------------

url: ## Print the ALB URL
	@echo "$(ALB_URL)"

poll: ## curl the ALB every second, printing which instance served (Ctrl-C to stop)
	@echo "polling $(ALB_URL)/name.txt -- Ctrl-C to stop"
	@while true; do \
	  printf '%s  ' "$$(date -u +%H:%M:%S)"; \
	  curl -s --max-time 3 "$(ALB_URL)/name.txt" || echo "REQUEST FAILED"; \
	  sleep 1; \
	done

status: ## ASG instances: name, id, AZ, purchase option, type, state
	aws ec2 describe-instances \
	  --region $(REGION) \
	  --filters 'Name=tag:Project,Values=Demo' \
	            'Name=instance-state-name,Values=pending,running,shutting-down' \
	  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,Id:InstanceId,AZ:Placement.AvailabilityZone,Purchase:InstanceLifecycle,Type:InstanceType,State:State.Name}' \
	  --output table

activity: ## Recent ASG scaling activity and lifecycle hook results
	aws autoscaling describe-scaling-activities \
	  --region $(REGION) \
	  --auto-scaling-group-name $(ASG_NAME) \
	  --max-items 15 \
	  --query 'Activities[].[StartTime,StatusCode,Description]' \
	  --output table

targets: ## ALB target group health
	aws elbv2 describe-target-health \
	  --region $(REGION) \
	  --target-group-arn $(TG_ARN) \
	  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' \
	  --output table

stress: ## Drive CPU to 100% on every demo instance via SSM (triggers scale-out)
	aws ssm send-command \
	  --region $(REGION) \
	  --document-name AWS-RunShellScript \
	  --targets 'Key=tag:Project,Values=Demo' \
	  --comment 'AWS UG demo: CPU load' \
	  --parameters 'commands=["nohup stress-ng --cpu 0 --timeout 900s >/dev/null 2>&1 &"]' \
	  --query 'Command.CommandId' --output text

unstress: ## Stop the CPU load, so scale-in can be shown
	aws ssm send-command \
	  --region $(REGION) \
	  --document-name AWS-RunShellScript \
	  --targets 'Key=tag:Project,Values=Demo' \
	  --comment 'AWS UG demo: stop CPU load' \
	  --parameters 'commands=["pkill -f stress-ng || true"]' \
	  --query 'Command.CommandId' --output text

interrupt: ## Inject a real Spot interruption via AWS FIS
	aws fis start-experiment \
	  --region $(REGION) \
	  --experiment-template-id $(FIS_TEMPLATE) \
	  --query 'experiment.[id,state.status]' --output text

session: ## Shell on an instance via SSM. Usage: make session INSTANCE=i-0abc123
	@test -n "$(INSTANCE)" || { echo "usage: make session INSTANCE=i-0abc123"; exit 1; }
	aws ssm start-session --region $(REGION) --target $(INSTANCE)
```

Note on `make status`: the `Purchase` column shows `spot` for Spot instances and is **empty** for On-Demand ones — `InstanceLifecycle` is absent on On-Demand instances. An empty cell there is the On-Demand base instance, not a bug.

- [x] **Step 3: Validate Terraform and check formatting**

Run:
```bash
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
```

Expected: `fmt -check` silent; `validate` prints `Success! The configuration is valid.`

- [x] **Step 4: Prove the Makefile parses and every target exists**

Run:
```bash
make -n help >/dev/null
for t in help fmt validate ami init plan apply destroy clean-ami \
         url poll status activity targets stress unstress interrupt session; do
  make -n "$t" >/dev/null 2>&1 || echo "BROKEN TARGET: $t"
done
echo "target check done"
```

Expected: prints only `target check done`. Any `BROKEN TARGET` line means that recipe does not parse.

`make -n` prints commands without running them, so this is safe. Note that `-n` still expands `$(shell ...)`, so `terraform output` may print a "no outputs" warning to stderr — harmless, since nothing is applied yet.

- [x] **Step 5: Prove recipes use tabs, not spaces**

Run:
```bash
! grep -nP '^    [a-z]' Makefile && echo OK
```

Expected: prints `OK`. A recipe indented with spaces would fail with `missing separator`.

- [x] **Step 6: Confirm the demo drivers are not silenced and outputs line up**

Run:
```bash
grep -q '^	aws ssm send-command' Makefile
grep -q '^	aws fis start-experiment' Makefile
grep -q 'name.txt' Makefile
for o in alb_dns_name asg_name target_group_arn fis_experiment_template_id region; do
  grep -q "output \"$o\"" terraform/outputs.tf || echo "MISSING OUTPUT: $o"
done
echo OK
```

Expected: prints `OK` with no `MISSING OUTPUT` lines. The first two greps require a literal TAB before `aws` and prove those recipes are unsilenced, so the audience sees the real command.

- [x] **Step 7: Commit**

```bash
git add terraform/outputs.tf Makefile
git commit -m "Add Terraform outputs and the Makefile command surface"
```

---

### Task 12: Runbook and Spot strategy documentation

**Files:**
- Create: `docs/runbook.md`
- Create: `docs/spot-strategy.md`

**Interfaces:**
- Consumes: the `make` target names from Task 11. Every command in these docs must be a real target from that Makefile — no raw CLI invocations that duplicate a target, since drift between doc and Makefile is exactly what the Makefile exists to prevent.
- Produces: nothing other tasks consume.

Both files end with a `## References` section of links to official AWS documentation. The audience should leave able to check the claims against AWS, not just against this repo.

- [x] **Step 1: Write `docs/runbook.md`**

Required structure and content. Write real prose, not an outline.

- **Title and one-line purpose:** the stage script for the demo.
- **Prerequisites:** AWS credentials, Terraform, Packer, AWS CLI v2, `make`, and the Session Manager plugin. State that the AMI must be built before `terraform plan` will work, because `data.aws_ami.demo` has nothing to find until then.
- **Timeline table** with these phases and rough durations, totalling roughly 25 minutes: AMI build (`make ami`, ~5 min, do this *before* the talk), `make init` + `make apply` (~4 min), first look (`make url`, `make status`, ~2 min), scale-out (`make stress`, ~5 min), scale-in (`make unstress`, ~3 min), Spot interruption (`make interrupt`, ~6 min at `PT5M`), teardown (`make destroy` + `make clean-ami`, ~4 min).
- **Setup, before the audience arrives:** `make ami`, then `make init`, then `make apply`. Say explicitly that `make apply` is not a live-demo step — waiting for three instances to bootstrap on stage is dead air.
- **Beat 1 — the stack exists.** `make url` in a browser; `make status` to show three instances, one with an empty `Purchase` column (On-Demand) and two showing `spot`, spread across three AZs. Note that instance names follow `asg-demo-<5 chars>`, Kubernetes-pod style, and that each instance named *itself* in user-data.
- **Beat 2 — start `make poll` in a second terminal** and leave it running for the rest of the demo. This is the single most useful window on screen.
- **Beat 3 — scale-out.** `make stress`, then `make activity` and `make targets` while waiting. Explain while it runs that the 10% CPU target is the `t4g.micro` credit baseline (12 credits/hour ÷ 2 vCPU ÷ 60 min), not an arbitrarily low number, and that instances run in `unlimited` credit mode so the metric is never distorted by throttling. Watch new instance names appear in `poll`.
- **Beat 4 — scale-in.** `make unstress`, watch the group shrink. Point out an instance sitting in `Terminating:Wait` in `make status` for about 60 seconds — the terminate lifecycle hook — and that `poll` shows no failed requests, because the 30s deregistration delay completes inside the 60s hold.
- **Beat 5 — Spot interruption.** `make interrupt`. Give the sequence: rebalance recommendation immediately, Capacity Rebalance starts a replacement, interruption notice about two minutes before termination, terminate hook holds, ALB routes only to healthy targets. Keep `poll` visible; the point is that it never fails.
- **Beat 6 — teardown.** `make destroy`, then `make clean-ami`. State plainly that `make destroy` alone leaves the AMI and its snapshot behind, quietly costing money.
- **What this demo does not show:** it does not measure availability. There is no dashboard and no uptime number. The 99.95% in the talk title is an architectural argument — On-Demand floor, multi-AZ spread, ALB health checks, Capacity Rebalance — not a figure this demo produces. Say so on stage rather than implying otherwise.
- **Troubleshooting:** `terraform plan` failing with "Your query returned no results" means `make ami` has not run. Instances cycling through `ABANDON` in `make activity` means user-data is failing — get the reason from `/var/log/user-data.log` via `make session INSTANCE=...`. `make interrupt` failing means either no Spot instance is currently running or the region lacks FIS.
- **References:** links to [Lifecycle hooks](https://docs.aws.amazon.com/autoscaling/ec2/userguide/lifecycle-hooks.html), [Target tracking scaling policies](https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-target-tracking.html), [Test Spot interruptions with AWS FIS](https://docs.aws.amazon.com/fis/latest/userguide/fis-tutorial-spot-interruptions.html), [Run Command](https://docs.aws.amazon.com/systems-manager/latest/userguide/run-command.html).

- [x] **Step 2: Write `docs/spot-strategy.md`**

Required structure and content:

- **Title and purpose:** why this stack is cheap without being fragile — the argument behind the talk title.
- **The shape of the policy**, as a table: `on_demand_base_capacity = 1`, `on_demand_percentage_above_base_capacity = 0`, `on_demand_allocation_strategy = prioritized`, `spot_allocation_strategy = capacity-optimized-prioritized`, with one sentence each on what it does.
- **The On-Demand floor.** One instance is always On-Demand. Spot capacity can be reclaimed; that one cannot, so the service has a floor no interruption can remove. At desired capacity 3, that is 1 On-Demand plus 2 Spot.
- **Why `capacity-optimized-prioritized`, and what was rejected.** It honours the override order as best-effort while preferring the deepest capacity pools, which are the least likely to be reclaimed. `price-capacity-optimized` was considered and rejected: it ignores override order for Spot, which would silently discard the instance type prioritisation. State this explicitly — it looks like the obvious cheaper choice.
- **Four instance types, one architecture.** `t4g.micro`, `t4g.small`, `c6g.medium`, `c6g.large`, in priority order, all arm64 Graviton to match the AMI. More types means more distinct Spot capacity pools, and fewer pools means more interruptions.
- **Multi-AZ, best effort.** `balanced-best-effort` spreads capacity across three AZs but will not block a launch when one AZ has no Spot capacity. Note this is already the provider default and is set explicitly so it is visible in the code.
- **Capacity Rebalance.** EC2 emits a rebalance recommendation when an instance is at elevated risk, earlier than the two-minute notice; with `capacity_rebalance = true` the ASG launches a replacement on that earlier signal. This is the mechanism that makes Spot compatible with an availability claim.
- **The burstable-credit angle.** The 10% CPU target is the `t4g.micro` baseline: 12 credits/hour ÷ 2 vCPU ÷ 60 min. Targeting the baseline adds capacity before any instance draws down its credit balance. Instances run in `unlimited` mode, where bursting is never throttled — under `standard`, a credit-depleted instance is throttled to baseline and `CPUUtilization` would flatten at exactly the target, quietly lying to the policy reading it. Add that `standard` is actively unsafe here: launch credits are a T2-only feature, so a `standard`-mode t4g starts with zero credits and is throttled from boot. Note that `c6g` types are fixed-performance with no baseline, so the calibration is aimed at the burstable members of the fleet.
- **The trap worth naming.** Never set `instance_market_options` on the launch template. Spot purchasing belongs to the ASG's mixed instances policy; setting it in both places conflicts. It is a common mistake and the error message is not obvious.
- **The cost argument**, briefly: Spot is heavily discounted against On-Demand for the same capacity, the fleet keeps an On-Demand floor for availability, and Graviton is cheaper again per unit of work. Do not invent specific percentages or dollar figures — point at the [Spot Instance pricing page](https://aws.amazon.com/ec2/spot/pricing/) and let the reader check current numbers.
- **References:** links to [mixed instance types and purchase options](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-mixed-instances-groups.html), [Allocation strategies](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-az-instance-type-distribution.html), [Capacity Rebalancing](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-capacity-rebalancing.html), [Burstable performance instances](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-performance-instances.html).

- [x] **Step 3: Confirm both docs carry the required facts and links**

Run:
```bash
grep -q 'capacity-optimized-prioritized' docs/spot-strategy.md
grep -q 'price-capacity-optimized' docs/spot-strategy.md
grep -q 'instance_market_options' docs/spot-strategy.md
grep -q 'unlimited' docs/spot-strategy.md
grep -q '## References' docs/spot-strategy.md
grep -q 'docs.aws.amazon.com' docs/spot-strategy.md

grep -q 'make interrupt' docs/runbook.md
grep -q 'make clean-ami' docs/runbook.md
grep -q 'make poll' docs/runbook.md
grep -q '## References' docs/runbook.md
grep -q 'docs.aws.amazon.com' docs/runbook.md
echo OK
```

Expected: prints `OK`.

- [x] **Step 4: Confirm the runbook makes no availability-measurement claim**

Run:
```bash
grep -qi 'architectural argument' docs/runbook.md && echo OK
```

Expected: prints `OK`. The runbook must state that the 99.95% figure is not measured by this demo. Overclaiming in front of an audience is the failure mode being guarded against.

- [x] **Step 5: Commit**

```bash
git add docs/runbook.md docs/spot-strategy.md
git commit -m "Add runbook and Spot strategy documentation"
```

---

### Task 13: Remaining documentation and index

**Files:**
- Create: `docs/lifecycle-hooks.md`
- Create: `docs/fis.md`
- Create: `docs/packer.md`
- Create: `docs/instance-refresh.md`
- Create: `docs/README.md`

**Interfaces:**
- Consumes: file paths and values from Tasks 2, 6, 9, 10, 11.
- Produces: nothing other tasks consume.

Every file ends with a `## References` section of official AWS links.

- [x] **Step 1: Write `docs/lifecycle-hooks.md`**

Required content:

- **Both hooks, as a table:** launch — `autoscaling:EC2_INSTANCE_LAUNCHING`, heartbeat 300s, default `ABANDON`, completed by the instance itself from user-data. Terminate — `autoscaling:EC2_INSTANCE_TERMINATING`, heartbeat 60s, default `CONTINUE`, completed by nobody, times out.
- **How the launch hook self-completes:** the numbered user-data sequence — read IMDSv2 metadata, self-name, write the document root, start nginx, poll port 80, then `complete-lifecycle-action --lifecycle-action-result CONTINUE`. The point is that an instance joins the load balancer when the application is ready, not when EC2 finished booting.
- **Why `ABANDON` is the launch default:** an instance whose bootstrap never finishes is replaced rather than joining the ALB half-built.
- **Why both hooks are `initial_lifecycle_hook` blocks inside the ASG** rather than separate `aws_autoscaling_lifecycle_hook` resources: a separate resource is created after the ASG, so the first instances would launch before the hook existed and reach `InService` without waiting for nginx — defeating the hook exactly once, on the first apply, which is the hardest case to notice.
- **Why the terminate hook is a plain wait**, and why 60s is not arbitrary: it exceeds the target group's 30s `deregistration_delay`, so draining finishes inside the hold and in-flight requests complete. At these numbers the plain wait *is* a graceful drain, achieved by arithmetic rather than by a Lambda. Warn that raising `deregistration_delay` above 60 without raising the heartbeat starts cutting connections.
- **The production alternative, documented but not built.** An EventBridge rule on the terminate lifecycle event invokes a Lambda that deregisters the instance from the target group, waits for drain, then calls `complete-lifecycle-action`. Explain *why* an external trigger is required: a terminating instance — especially a reclaimed Spot instance — cannot be relied on to complete its own hook, which is why the launch hook can self-complete but the terminate hook cannot. Say plainly that this repo does not build it, and why: fewer moving parts to fail on stage.
- **The failure handler.** `set -euo pipefail` plus an `ERR` trap routing into `on_failure`, which drops the trap, sends `ABANDON`, then calls the `notify_failure` stub. `ABANDON` goes first because notification is best effort and a hanging webhook must not delay replacement. Note that `create-tags` is deliberately guarded with `|| log` so a cosmetic failure cannot trip the trap and abandon a healthy instance.
- **References:** [Lifecycle hooks](https://docs.aws.amazon.com/autoscaling/ec2/userguide/lifecycle-hooks.html), [`CompleteLifecycleAction`](https://docs.aws.amazon.com/autoscaling/ec2/APIReference/API_CompleteLifecycleAction.html), [Target group deregistration delay](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/edit-target-group-attributes.html).

- [x] **Step 2: Write `docs/fis.md`**

Required content:

- **What the experiment does:** interrupts exactly one running Spot instance tagged `Project=Demo`, for real — not a simulation, not a manual termination.
- **The template, as a table** of verified values: action `aws:ec2:send-spot-instance-interruptions`, action target key `SpotInstances`, parameter `durationBeforeInterruption = PT5M` (valid range 2–15 minutes), target resource type `aws:ec2:spot-instance`, `selection_mode = COUNT(1)`, resource tag `Project=Demo`, filter `State.Name = running`.
- **How to trigger it:** `make interrupt`. Include what the command prints (experiment ID and status) and how to follow it with `make status`, `make activity`, `make targets` and `make poll`.
- **The sequence it produces:** rebalance recommendation immediately on start; Capacity Rebalance launches a replacement; interruption notice two minutes before termination; the instance enters `Terminating:Wait` where the terminate hook holds it; it drains from the target group; the ALB serves only healthy targets throughout.
- **Why `PT5M` and not `PT2M`:** at the minimum the rebalance recommendation and the interruption notice land almost together, hiding Capacity Rebalance's head start — the very thing worth demonstrating. `PT5M` separates them. Note that the precise observed gap should be confirmed by running it, since AWS documents each signal separately but not their interaction.
- **The stop condition:** a CloudWatch alarm on `HealthyHostCount < 1` aborts the experiment. Note that the AWS tutorial uses `source = "none"` and this deliberately does not, because it runs in front of an audience.
- **Quota:** the default is 5 Spot Instances per experiment when targeting by tags, so `COUNT(1)` sits well inside it.
- **Region constraint, stated prominently:** AWS FIS is not available in `ap-southeast-3` (Jakarta), which is why this demo runs in `ap-southeast-1`. FIS is regional and must run where the instances are, so there is no split-region workaround short of a second full stack.
- **References:** [FIS actions reference](https://docs.aws.amazon.com/fis/latest/userguide/fis-actions-reference.html), [Test Spot interruptions with AWS FIS](https://docs.aws.amazon.com/fis/latest/userguide/fis-tutorial-spot-interruptions.html), [Spot Instance interruptions](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-interruptions.html), [EC2 instance rebalance recommendation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/rebalance-recommendations.html).

- [x] **Step 3: Write `docs/packer.md`**

Required content:

- **What the AMI contains and why each item is baked rather than installed at boot:** Docker Engine, AWS CLI v2, `stress-ng`, and a pre-pulled `nginx:alpine` image. Pre-pulling means user-data's `docker pull` is a cache hit, so scale-out is fast in front of an audience and does not depend on venue network speed.
- **Base image:** Amazon Linux 2023, arm64, selected by `source_ami_filter` with `most_recent = true`.
- **Why `source_ami_filter` rather than an SSM-parameter data source:** Packer evaluates HCL data sources during `packer validate`, which would make validation require AWS credentials. `source_ami_filter` resolves at build time instead, keeping `make validate` credential-free.
- **How to build:** `make ami`, roughly 5 minutes. State that this must happen before `terraform plan` or `apply`, because `data.aws_ami.demo` has nothing to find until an AMI exists.
- **How Terraform selects the AMI:** newest AMI owned by self whose name starts with the `name_prefix` and which carries `Project=Demo`. Warn that changing the Packer `ami_name` prefix or dropping the `Project=Demo` tag breaks that lookup.
- **How to verify what actually landed in the AMI:** the provisioner asserts `docker --version`, `stress-ng --version`, `aws --version`, hard-fails unless the CLI reports `aws-cli/2`, and confirms `nginx:alpine` is in the local image cache. A build that succeeds has therefore already proved these.
- **The one uncertainty:** the `awscli-2` dnf package name. The script tolerates the install failing and asserts `aws-cli/2` instead, so a wrong package name produces a loud failure rather than a subtly broken AMI.
- **Cleanup:** `make clean-ami`. Terraform does not own the AMI or its snapshot, so `make destroy` leaves them behind and they keep costing money.
- **References:** [Packer Amazon EBS builder](https://developer.hashicorp.com/packer/integrations/hashicorp/amazon/latest/components/builder/ebs), [AL2023 packages formerly in EPEL](https://docs.aws.amazon.com/linux/al2023/ug/epel.html).

- [x] **Step 4: Write `docs/instance-refresh.md`**

Required content:

- **What it is:** rolling replacement of every instance in the group, used after the launch template changes — for example after a new AMI build.
- **Why it is not wired into Terraform.** A Terraform `instance_refresh` block auto-triggers whenever the launch template changes, which removes exactly the live control wanted here. It is deliberately absent, not forgotten.
- **The ready-to-run command,** with these preferences spelled out: strategy `Rolling`, `MinHealthyPercentage = 100`, `MaxHealthyPercentage = 200`, checkpoints unset. Give the actual `aws autoscaling start-instance-refresh` invocation including the `--preferences` JSON, and note the ASG name comes from `terraform output -raw asg_name`.
- **What those numbers mean:** 100% minimum healthy with 200% maximum healthy is launch-before-terminate — new instances come up and pass health checks before old ones go away, so capacity never dips. That is the setting that makes replacement invisible to users.
- **How to watch it:** `aws autoscaling describe-instance-refreshes`, plus `make status` and `make targets`.
- **State plainly that this is not part of the stage demo** — the door is open if needed, nothing fires automatically.
- **References:** [Instance refresh](https://docs.aws.amazon.com/autoscaling/ec2/userguide/asg-instance-refresh.html), [`StartInstanceRefresh`](https://docs.aws.amazon.com/autoscaling/ec2/APIReference/API_StartInstanceRefresh.html).

- [x] **Step 5: Write `docs/README.md`**

A short index, no more than a screenful: one line on what this directory is, then a table of the six docs with a one-line description each — `runbook.md`, `spot-strategy.md`, `lifecycle-hooks.md`, `fis.md`, `packer.md`, `instance-refresh.md`. Close with a pointer to `../README.md` for the overview and to `superpowers/specs/` for the full design including rejected alternatives.

- [x] **Step 6: Confirm every doc exists, carries references, and states its key facts**

Run:
```bash
for f in runbook spot-strategy lifecycle-hooks fis packer instance-refresh; do
  test -s "docs/$f.md" || echo "MISSING OR EMPTY: docs/$f.md"
  grep -q '## References' "docs/$f.md" || echo "NO REFERENCES: docs/$f.md"
  grep -q 'docs.aws.amazon.com\|developer.hashicorp.com' "docs/$f.md" \
    || echo "NO OFFICIAL LINKS: docs/$f.md"
done

grep -q 'initial_lifecycle_hook' docs/lifecycle-hooks.md
grep -q 'EventBridge' docs/lifecycle-hooks.md
grep -q 'SpotInstances' docs/fis.md
grep -q 'ap-southeast-3' docs/fis.md
grep -q 'PT5M' docs/fis.md
grep -q 'source_ami_filter' docs/packer.md
grep -q 'MinHealthyPercentage' docs/instance-refresh.md
test -s docs/README.md
echo OK
```

Expected: prints `OK` with no `MISSING`, `NO REFERENCES` or `NO OFFICIAL LINKS` lines.

- [x] **Step 7: Commit**

```bash
git add docs/lifecycle-hooks.md docs/fis.md docs/packer.md docs/instance-refresh.md docs/README.md
git commit -m "Add lifecycle hook, FIS, Packer and instance refresh documentation"
```

---

### Task 14: Final consistency sweep and README status note

**Files:**
- Modify: `README.md` — remove the status note block only

**Interfaces:**
- Consumes: everything from Tasks 1–13.
- Produces: a repository whose README no longer says the code is unwritten.

This task exists because `README.md` was written before the code and opens with a note saying so. Leaving it in tells readers a working repo is broken; removing it earlier would have claimed code that did not exist.

- [x] **Step 1: Confirm the whole repository still validates**

Run:
```bash
make validate
```

Expected: `terraform fmt -check -recursive` silent, `terraform validate` prints `Success! The configuration is valid.`, and `packer validate` prints `The configuration is valid.`

- [x] **Step 2: Confirm every file the plan promised exists**

Run:
```bash
for f in AGENTS.md Makefile README.md \
         packer/asg-demo.pkr.hcl packer/scripts/provision.sh \
         terraform/versions.tf terraform/variables.tf terraform/locals.tf \
         terraform/vpc.tf terraform/security-groups.tf terraform/iam.tf \
         terraform/launch-template.tf terraform/alb.tf terraform/asg.tf \
         terraform/fis.tf terraform/outputs.tf \
         terraform/templates/user-data.sh.tftpl \
         docs/README.md docs/runbook.md docs/spot-strategy.md \
         docs/lifecycle-hooks.md docs/fis.md docs/packer.md \
         docs/instance-refresh.md; do
  test -s "$f" || echo "MISSING OR EMPTY: $f"
done
echo "file check done"
```

Expected: prints only `file check done`.

- [x] **Step 3: Confirm no secrets and no wrong-region references**

Run:
```bash
# Key material must not appear anywhere in the tree.
git grep -nE 'BEGIN [A-Z ]*PRIVATE KEY' && echo "FAIL: key material" || echo "no key material"

# A webhook URL must not appear in code or config. Scoped to code paths on
# purpose: prose that warns against hardcoding one legitimately names the host,
# and an unscoped search also matches this very check inside the plan file.
git grep -n 'hooks.slack.com' -- terraform packer Makefile && echo "FAIL: webhook URL" || echo "no webhook URL"

# The region must never be ASSIGNED as ap-southeast-3. Naming it in a
# description is correct and wanted -- terraform/variables.tf explains that AWS
# FIS does not exist there, which is the whole reason this demo runs elsewhere.
git grep -nE '=[[:space:]]*"ap-southeast-3"' && echo "FAIL: region assigned to Jakarta" || echo "no wrong-region assignment"
```

Expected: `no key material`, `no webhook URL`, `no wrong-region assignment`.

**If you are here because an earlier version of this step failed, read this.** Two of these checks were wrong in the first version of the plan, and the fix is to the *check*, never to the code:

- The webhook search was unscoped, so it matched its own pattern inside this plan file — a tracked file. It now searches only `terraform/`, `packer/` and the `Makefile`.
- The region search matched any *mention*. But Task 1 mandates a `variables.tf` description that names `ap-southeast-3` precisely to warn the reader off it, so the old check contradicted Task 1. It now matches only an assignment, which is the actual failure mode worth guarding.

Do **not** delete that description to make a check pass. It is load-bearing documentation: it is the only place in the Terraform where a reader learns why the region cannot be Jakarta.

- [x] **Step 4: Remove the status note from `README.md`**

Delete exactly this block, including the blank line after it:

```markdown
> **Status: not yet implemented.** The design is finished (`docs/superpowers/specs/`), but the Terraform and Packer code is still being written. `make apply` will not work yet. This note disappears when the code lands.
```

Change nothing else in `README.md`.

- [x] **Step 5: Confirm the note is gone and nothing else changed**

Run:
```bash
! grep -q 'not yet implemented' README.md && echo "note removed"
git diff --stat README.md
```

Expected: prints `note removed`, and the diff shows `README.md` with 2 deletions and 0 insertions. Any insertion means something else was edited.

- [x] **Step 6: Commit**

```bash
git add README.md
git commit -m "Drop the not-yet-implemented note from the README"
```

---

## Status: complete

All 14 tasks were implemented and committed (`90d7fc3` through `962c9b5`), then
reviewed against the spec. Verification at review time: all 15 code files matched
this plan byte-for-byte, `make validate` passed, and the worktree was clean.

Three defects were found in review, all originating in this plan and the
`.gitignore` rather than in the implementation, and fixed in `2010750`:
`make validate` failed on a fresh clone because the target never ran
`terraform init`; `.terraform.lock.hcl` was gitignored so no provider version
was pinned; and the README and spec claimed surplus credits were "rarely needed"
while `make stress` spends them by design. The `validate` target in Task 11 above
has been corrected so a re-run does not reintroduce the first one.

What remains is not a task in this plan — it is the apply-gated handoff below.

## Handoff to the repository owner

Everything above is static verification. **Nothing in this plan proves the stack works** — that needs `apply` against live AWS, which no agent may run.

When the plan is complete, the owner runs the spec's Verification rehearsal, in this order:

1. `make ami` — first run also settles the `awscli-2` package-name question (Task 2).
2. `aws iam get-policy --policy-arn arn:aws:iam::aws:policy/service-role/AWSFaultInjectionSimulatorEC2Access` — confirms the one ARN static validation cannot check (Task 5).
3. `make init`, `make plan`, `make apply`.
4. The 15 numbered rehearsal checks in the spec's Verification section.
5. `make destroy` and `make clean-ami`.

Two things only a real run can settle: the observed gap between the rebalance recommendation and the interruption notice at `PT5M`, and whether the 10% CPU target trips scale-out from idle noise before you want it to.

---

## Self-Review

**1. Spec coverage.** Every numbered spec section maps to a task: §1 Packer → Task 2. §2 Network → Task 3. §3 Security groups → Task 4. §4 IAM → Task 5. §5 Launch template → Task 7. §6 User-data → Task 6. §7 ASG → Task 9. §8 Lifecycle hooks → Task 9 (as `initial_lifecycle_hook` blocks). §9 Scaling policy → Task 9, with `credit_specification` in Task 7. §10 ALB → Task 8. §11 Instance Refresh → Task 13 (documentation only, deliberately unwired). §12 FIS → Task 10. §13 Instance access → Task 4 (`ssh_ingress_cidr`) and Task 7 (`key_name`); SSM comes from the managed policy in Task 5 and `make session` in Task 11. §14 Makefile → Task 11. Documentation plan → Tasks 12 and 13. Repository layout → the File Structure table, with two flagged deviations. No gaps found.

**2. Placeholder scan.** No "TBD", "TODO", "implement later", or "similar to Task N". Every HCL and shell file is given in full. Tasks 12 and 13 specify documentation by required facts, required links and grep-checkable assertions rather than full prose — prose is the deliverable there, and the checks are objective.

**3. Type and name consistency.** Verified across tasks: `local.asg_name`, `local.launch_hook_name`, `local.terminate_hook_name`, `local.tags` defined in Task 1 and used identically thereafter. `aws_subnet.public` is a counted list, referenced as `aws_subnet.public[*].id` in Tasks 8 and 9. `aws_iam_instance_profile.instance.arn` (Task 5) matches the launch template's `iam_instance_profile { arn = ... }` (Task 7). `aws_launch_template.demo.id` / `.latest_version` (Task 7) match Task 9. `aws_lb_target_group.demo.arn` and `.arn_suffix` (Task 8) match Tasks 9, 10 and 11. `aws_iam_role.fis.arn` (Task 5) matches Task 10. The five output names in Task 11 match the five the Makefile reads. The three `templatefile()` variables in Task 7 exactly match the three `${...}` occurrences allowed in Task 6, which Task 6 Step 3 enforces. `/opt/demo/html/name.txt` is written in Task 6 and curled by `make poll` in Task 11.
