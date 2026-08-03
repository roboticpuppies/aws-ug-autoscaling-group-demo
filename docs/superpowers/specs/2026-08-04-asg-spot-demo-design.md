# AWS UG Demo — Auto-Scaling & Spot Instances

Design doc for the live demo supporting the talk *"Auto-Scaling & Spot Instance: SLA 99.95% dengan Biaya Lebih Hemat"*.

- **Date:** 2026-08-04
- **Region:** `ap-southeast-3` (Jakarta)
- **IaC:** Terraform (infrastructure) + Packer (AMI)

## Status

Design approved in outline; this document is written and committed. **Not yet implemented — no Terraform or Packer code exists.**

Next steps, in order:

1. Run the AWS documentation verification pass on the four items listed under [References](#references), and fold any corrections into this document.
2. Write the implementation plan.
3. Hand off to the implementing agent.

**Who does what.** This spec and the implementation plan are authored by Claude; the code is written by a *different* AI agent that will not have seen the design conversation. Everything an implementer needs must therefore be explicit here or in the plan — file paths, resource names, and acceptance criteria that can be checked objectively. Claude reviews the resulting code against this spec afterwards.

**Human-gated commands.** No agent runs `terraform apply`, `terraform destroy`, or `packer build`. Those create real, billable AWS resources. Agents are limited to `terraform fmt`, `terraform validate`, and `packer validate`. The rehearsal under [Verification](#verification) is the author's own step, so a review can confirm spec conformance and static correctness but never runtime behavior.

## Goal

A self-contained, destroy-after-talk stack that demonstrates, live on stage:

1. Dynamic scaling driven by a CPU target-tracking policy.
2. ASG lifecycle hooks on both launch and terminate.
3. A mixed instances policy that keeps a 1-instance On-Demand floor and runs everything above it on Spot.
4. Resilience to a Spot interruption, injected on demand with AWS FIS.

The narrative arc is *cost savings without giving up availability* — Spot for the bulk of capacity, On-Demand base plus multi-AZ spread plus ALB health checks for the SLA story.

## Non-goals

Deliberately out of scope, to keep the stack readable on a projector and cheap to run:

- Production hardening: private subnets, NAT, HTTPS/ACM, WAF, access logs.
- Instance Refresh as a live demo beat — configured-by-documentation only (see below).
- EventBridge + Lambda driven graceful drain — documented as an alternative, not built.
- Application-level tests. This is infrastructure demo code.
- SSH key material of any kind in version control. See §13 for the access design.

## Architecture

```
                     Internet
                        │
                   ┌────▼────┐
                   │   ALB   │  :80, 3 public subnets
                   └────┬────┘
                        │  target group, health check /
        ┌───────────────┼───────────────┐
   ┌────▼────┐     ┌────▼────┐     ┌────▼────┐
   │  AZ a   │     │  AZ b   │     │  AZ c   │
   │ nginx   │     │ nginx   │     │ nginx   │   docker, from Packer AMI
   └─────────┘     └─────────┘     └─────────┘
        └───────────────┴───────────────┘
                  ASG: min 1 / desired 3 / max 5
                  1 On-Demand base + 100% Spot above it
```

### 1. Packer AMI

`packer/asg-demo.pkr.hcl`, HCL2 template.

- **Base:** Amazon Linux 2023, `arm64`, resolved via SSM public parameter (not a hardcoded AMI ID).
- **Build instance:** `t4g.micro` in `ap-southeast-3`.
- **Installed:**
  - Docker Engine (`dnf install -y docker`), enabled and started via systemd.
  - AWS CLI v2 (`dnf install -y awscli-2`). AL2023 ships a v2 CLI already; the build installs explicitly and asserts `aws --version` so the AMI's contents are not left to base-image drift.
  - `stress-ng`, for the CPU-trigger demo.
  - `nginx:alpine` pre-pulled into the local Docker image cache, so user-data's `docker pull` is a fast cache hit and scale-out looks snappy on stage.
- **Tags:** `Project=Demo`, plus `Name` and a build-version tag so Terraform can select the newest build.

**Verify during implementation:** `stress-ng` is not guaranteed to be present in AL2023's default repos. Attempt `dnf install -y stress-ng` first. If it is unavailable, fall back to pre-pulling a stress-ng container image into the AMI cache (Docker is already there) and adjust `docs/runbook.md` to invoke it via `docker run`. Do not leave the AMI without a working CPU load generator.

### 2. Network

- VPC `10.0.0.0/16`.
- Three public subnets, `/24` each, one per AZ across the three AZs of `ap-southeast-3`, with `map_public_ip_on_launch = true`.
- One Internet Gateway, one public route table, three associations.

Public subnets only — instances need outbound reach for `docker pull`, SSM, and the Autoscaling API, and a NAT gateway would add cost and explanation for no demo value.

### 3. Security groups

| SG | Ingress | Egress |
| --- | --- | --- |
| `alb_sg` | TCP 80 from `0.0.0.0/0` | all |
| `instance_sg` | TCP 80 from `alb_sg` only | all |

Instance egress stays open: outbound is required for Docker Hub, SSM, and `complete-lifecycle-action`. One optional port-22 ingress rule exists but is disabled by default — see §13.

### 4. IAM

**Instance role** (+ instance profile):

- Managed policy `AmazonSSMManagedInstanceCore` — enables SSM Run Command, so the demo needs no SSH key and no port 22.
- Inline policy: `autoscaling:CompleteLifecycleAction` and `autoscaling:RecordLifecycleActionHeartbeat`, scoped to this ASG's ARN.

To scope that inline policy without a Terraform dependency cycle (the ASG needs the instance profile, the profile's policy needs the ASG ARN), the ASG name is set explicitly from a variable and the ARN is constructed from known account/region/name rather than read off the ASG resource.

**FIS role:** trusted by `fis.amazonaws.com`; grants `ec2:SendSpotInstanceInterruptions` plus the EC2 describe calls FIS needs for target resolution, and CloudWatch read for the stop condition. See [IAM roles for FIS experiments](https://docs.aws.amazon.com/fis/latest/userguide/getting-started-iam-service-role.html).

Reference: [Session Manager prerequisites / instance permissions](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-prerequisites.html), [`CompleteLifecycleAction`](https://docs.aws.amazon.com/autoscaling/ec2/APIReference/API_CompleteLifecycleAction.html).

### 5. Launch template

- `image_id` from a `data.aws_ami` lookup: most recent, owned by self, filtered on the Packer `Project=Demo` tag and name prefix.
- IMDSv2 required (`http_tokens = "required"`).
- Instance profile and `instance_sg` attached.
- Default `instance_type = t4g.micro` — overridden per-type by the mixed instances policy, but set so the template is valid standalone.
- `user_data` = base64 of the rendered bootstrap script.
- Tag specifications: `Project=Demo`.
- `key_name` attached only when the optional variable is set (§13); unset by default.

**Gotcha to encode:** do **not** set `instance_market_options` on the launch template. Spot purchasing is owned by the ASG's mixed instances policy; setting it in both places conflicts. Worth calling out in `docs/spot-strategy.md` — it's a common trap.

### 6. User-data bootstrap

Rendered from `terraform/templates/user-data.sh.tftpl`. Logs everything to `/var/log/user-data.log`.

1. Fetch an IMDSv2 token, then read instance ID, AZ, instance type, and `instance-life-cycle` (`spot` vs `on-demand`).
2. Write `/opt/demo/html/index.html` showing all four values — so a browser refresh against the ALB visibly proves which instance served the request, and whether it was Spot.
3. `docker pull nginx:alpine` (cache hit from the AMI), then `docker run -d --name web -p 80:80 -v /opt/demo/html:/usr/share/nginx/html:ro nginx:alpine`.
4. Poll `curl -fs localhost:80` until it returns 200, with a bounded retry count.
5. On success: `aws autoscaling complete-lifecycle-action --lifecycle-action-result CONTINUE` for the launch hook, passing the instance ID, hook name, and ASG name (hook and ASG names injected by Terraform at render time).
6. On failure: complete with `ABANDON` so a broken instance is replaced promptly instead of waiting out the heartbeat timeout.

This is the point of the launch hook: the instance is not `InService` and takes no ALB traffic until nginx is actually answering. Not merely "EC2 booted".

### 7. Auto Scaling group

- Name set explicitly (needed by the IAM policy ARN and by FIS targeting).
- `vpc_zone_identifier` = all three subnets.
- **Capacity:** min 1, desired 3, max 5. Desired 3 means 1 On-Demand + 2 Spot, so FIS always has a Spot instance to interrupt and the ASG still shows healthy capacity afterwards.
- **Health check:** type `ELB`, grace period 300s. One field covers both — `ELB` includes EC2 status checks; there is no separate EC2 toggle. Note the grace period only starts once an instance reaches `InService`, which the launch hook already gates on nginx answering — so it is headroom against a container dying immediately after bootstrap, not cover for boot time. 300s is generous on purpose; it costs nothing in a demo.
- **Mixed instances policy:**
  - Overrides, in priority order: `t4g.micro`, `t4g.small`, `c6g.medium`, `c6g.large`. All arm64, matching the AMI.
  - `on_demand_base_capacity = 1`
  - `on_demand_percentage_above_base_capacity = 0` → everything above the base is Spot.
  - `on_demand_allocation_strategy = prioritized`
  - `spot_allocation_strategy = capacity-optimized-prioritized` — honors the override order as best-effort while still favoring the deepest capacity pools. `price-capacity-optimized` was considered and rejected: it ignores override order for Spot, which would silently discard the requested type prioritization.
- **Capacity Rebalance:** `capacity_rebalance = true`. EC2 emits a *rebalance recommendation* when a Spot instance is at elevated risk of interruption — earlier than the two-minute interruption notice. With this enabled the ASG proactively launches a replacement on that earlier signal instead of waiting for the reclaim. This is the core mechanism behind the talk's claim that Spot need not cost you availability, so it gets explicit stage time. See [Capacity Rebalancing](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-capacity-rebalancing.html).
- **AZ distribution:** `balanced-best-effort` — spreads across AZs but will not block a launch when one AZ has no Spot capacity. Note this is already the provider default; it is set explicitly so the behavior is visible in the code on screen rather than implied.
- **Tags:** `Project=Demo` and `Name`, both propagating at launch. `Project=Demo` is also what FIS targets on.

Reference: [Auto Scaling groups with multiple instance types and purchase options](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-mixed-instances-groups.html), [Allocation strategies](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-az-instance-type-distribution.html), [`aws_autoscaling_group`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/autoscaling_group).

### 8. Lifecycle hooks

| Hook | Transition | Heartbeat | Default result | Completed by |
| --- | --- | --- | --- | --- |
| Launch | `autoscaling:EC2_INSTANCE_LAUNCHING` | 300s | `ABANDON` | the instance itself, from user-data |
| Terminate | `autoscaling:EC2_INSTANCE_TERMINATING` | 900s | `CONTINUE` | nobody — it times out |

The launch hook's `ABANDON` default is the safe failure mode: an instance whose bootstrap never finishes gets replaced rather than joining the ALB half-built.

The terminate hook deliberately does nothing but hold the instance in `Terminating:Wait` for up to 900s, then proceed on timeout. This is the mechanism-demonstration route, chosen on purpose: it shows the hook exists and holds, with no extra moving parts to fail on stage. `docs/lifecycle-hooks.md` documents the cleaner production alternative (EventBridge rule on the terminate lifecycle event → Lambda → deregister from target group, wait for drain → `complete-lifecycle-action`) and explains why an external trigger is required there — a terminating instance, especially a reclaimed Spot instance, cannot be relied on to complete its own hook.

### 9. Scaling policy

Target tracking on `ASGAverageCPUUtilization`, target **10%**.

10% is intentionally far below any real-world setting. It makes scale-out fire within a couple of minutes of applying load, which is what a live audience needs to see. The trade-off is that idle and boot-time CPU noise can trigger scale-out unprompted — so rehearse the timing, and be ready to explain the number as a demo artifact rather than a recommendation.

### 10. ALB

- ALB across the three public subnets, `alb_sg`.
- Target group: HTTP 80, health check path `/`, healthy threshold 2, interval 15s, timeout 5s.
- `deregistration_delay = 30` — keeps drain visibly quick during the demo.
- Listener on 80, forwarding to the target group.

### 11. Instance Refresh

**Not** declared as a Terraform `instance_refresh` block. That block auto-triggers a refresh whenever the launch template changes, which is exactly the loss of live control we don't want.

Instead, `docs/instance-refresh.md` documents the ready-to-run CLI invocation with the intended preferences:

- Strategy: `Rolling`
- `MinHealthyPercentage = 100`, `MaxHealthyPercentage = 200` → launch-before-terminate replacement
- Checkpoints left unset

Door open if it's ever needed; nothing fires on stage.

### 12. AWS FIS

- **Experiment template action:** `aws:ec2:send-spot-instance-interruptions`, with `durationBeforeInterruption = PT2M` so the real 2-minute interruption notice is delivered.
- **Target:** resource type `aws:ec2:spot-instance`, selected by tag `Project=Demo`, filtered to running instances, selection mode `COUNT(1)`.
- **Stop condition:** CloudWatch alarm on the ALB's `HealthyHostCount` dropping below 1 — aborts the experiment rather than deepening an outage.
- **Role:** the FIS role above.

`docs/fis.md` covers how to start the experiment, the sequence it triggers (rebalance recommendation and interruption notice → instance goes to `Terminating:Wait` and the terminate hook holds it → ASG launches a replacement, best-effort in another AZ → ALB routes only to healthy targets), and how to verify each step.

Reference: [`aws:ec2:send-spot-instance-interruptions`](https://docs.aws.amazon.com/fis/latest/userguide/fis-actions-reference.html#ec2-actions-send-spot-instance-interruptions), [Test Spot interruptions with FIS](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-interruptions.html), [`aws_fis_experiment_template`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/fis_experiment_template).

### 13. Instance access — no keys in this repository

**No private key is committed to this repository, ever.** Not a throwaway key, not a real one. A committed key is permanent in git history, and paired with an open port 22 it makes the instance shell-accessible to anyone on the internet for as long as it runs. It also would not achieve the goal: an audience member cannot reach these instances without AWS credentials for this account, and someone cloning the repo to run it in their own account needs their own key regardless.

**Primary access path: SSM Session Manager.** The instance role already carries `AmazonSSMManagedInstanceCore`, so:

```
aws ssm start-session --target <instance-id>
```

No key material, no port 22, no inbound SG rule, and every session is audited in CloudTrail. This is also the mechanism the CPU-load step already uses via Run Command, so the demo gains nothing extra to explain.

**Optional SSH, for people cloning the repo:** two variables, both inert by default.

| Variable | Default | Effect |
| --- | --- | --- |
| `key_name` | `null` | When set to an existing EC2 key pair name, attaches it to the launch template |
| `ssh_ingress_cidr` | `null` | When set, adds one port-22 ingress rule to `instance_sg` for that CIDR only |

Both default to unset, so the stack has no SSH surface unless someone deliberately opts in with their own key and their own IP. `docs/runbook.md` documents Session Manager as the way in; `README.md` notes the two variables for anyone who insists on SSH, with a warning against `0.0.0.0/0`.

## Repository layout

```
packer/
  asg-demo.pkr.hcl
  scripts/                  # provisioner scripts
terraform/
  versions.tf               # provider + version constraints
  variables.tf
  vpc.tf
  security-groups.tf
  iam.tf
  alb.tf
  asg.tf                    # launch template, ASG, hooks, scaling policy
  fis.tf
  outputs.tf                # ALB DNS name, ASG name, FIS template ID
  templates/user-data.sh.tftpl
docs/
  README.md                 # index
  packer.md
  runbook.md                # the talk script
  lifecycle-hooks.md        # incl. EventBridge+Lambda alternative
  spot-strategy.md          # mixed policy, prioritization, cost story
  fis.md
  instance-refresh.md
README.md
```

## Documentation plan

Everything lives in `docs/`, per requirement. **Every doc links out to the official AWS documentation for the features it describes** — the audience should be able to leave the talk with authoritative sources, not just this repo's paraphrase. A `References` section at the end of each doc collects them.

- **`runbook.md`** — the stage script, in order: Packer build → `terraform apply` → curl/browse the ALB → SSM Run Command to apply CPU load → what to watch (CloudWatch CPU, ASG activity history, target group health, browser refresh showing new instance IDs) → FIS experiment → observe replacement → `terraform destroy`. Includes rough timings so the talk can be paced.
- **`packer.md`** — what goes into the AMI and why, how to build, how to verify contents, how Terraform selects the newest build.
- **`lifecycle-hooks.md`** — both hooks, how the launch hook self-completes, why the terminate hook is a plain wait here, and the EventBridge + Lambda alternative for production.
- **`spot-strategy.md`** — mixed instances policy explained: On-Demand base as the availability floor, allocation strategies, type prioritization, Capacity Rebalance, the AZ distribution setting, the `instance_market_options` trap, and the cost comparison that backs the talk title.
- **`fis.md`** — triggering and interpreting the Spot interruption experiment.
- **`instance-refresh.md`** — the documented-but-unwired replacement path.

## Verification

No application tests. Verification is static checks plus one full rehearsal.

**Static:** `packer validate`, `terraform fmt -check`, `terraform validate`, `terraform plan`.

**Rehearsal — apply → demo → destroy, at least once before the talk, confirming:**

1. Packer build succeeds and the AMI contains Docker, AWS CLI v2, and a working CPU load generator.
2. `terraform apply` converges; ALB returns the instance-ID page.
3. Exactly 1 instance is On-Demand and the rest are Spot (check `instance-life-cycle` on the page, or `describe-auto-scaling-instances`).
4. Instances spread across AZs.
5. Launch hooks complete as `CONTINUE` — ASG activity history shows no `ABANDON`, and instances reach `InService` promptly rather than after a 300s timeout.
6. CPU load triggers scale-out toward max 5.
7. Terminate hook visibly holds an instance in `Terminating:Wait`.
8. FIS interrupts one Spot instance; a replacement launches; `HealthyHostCount` never reaches 0 and the ALB keeps serving.
9. Capacity Rebalance is active on the ASG (`describe-auto-scaling-groups` shows `CapacityRebalance: true`), and the FIS run shows a replacement launching off the rebalance signal rather than only after the reclaim.
10. `git grep` finds no key material, and no port-22 rule exists with the default variable values.
11. `terraform destroy` leaves nothing behind. Delete the Packer AMI and its snapshot separately — Terraform does not own them.

## Risks and open verifications

| Risk | Mitigation |
| --- | --- |
| 10% CPU target scales out from idle noise, mid-sentence | Rehearse; be ready to explain it as a deliberate demo setting |
| `stress-ng` may not be in AL2023 default repos | Verify at build time; container-image fallback (see §1) |
| Spot capacity for `t4g`/`c6g` in `ap-southeast-3` | Four instance types plus best-effort AZ spread; confirm each type is actually offered in this region before the talk |
| `availability_zone_distribution` is a recent ASG feature | Pin a recent AWS provider version in `versions.tf` |
| FIS action requires a genuinely Spot instance | Desired 3 with On-Demand base 1 guarantees 2 Spot instances |
| Demo network is slow | `nginx:alpine` pre-baked into the AMI so bootstrap does not depend on a full pull |

## Cost

Roughly three `t4g.micro` instances (mostly Spot) plus one ALB — cents per hour, dominated by the ALB's hourly charge. Run it for the rehearsal and the talk, then destroy. `docs/runbook.md` ends with the teardown step, including the AMI and snapshot cleanup that Terraform will not do.

## References

Provider behavior below was confirmed against the Terraform AWS provider source (v6.x); `versions.tf` pins `~> 6.0`.

- [EC2 Auto Scaling — mixed instance types and purchase options](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-mixed-instances-groups.html)
- [Allocation strategies and AZ distribution](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-az-instance-type-distribution.html)
- [Capacity Rebalancing](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-capacity-rebalancing.html)
- [Lifecycle hooks](https://docs.aws.amazon.com/autoscaling/ec2/userguide/lifecycle-hooks.html) · [`CompleteLifecycleAction`](https://docs.aws.amazon.com/autoscaling/ec2/APIReference/API_CompleteLifecycleAction.html)
- [Target tracking scaling policies](https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-target-tracking.html)
- [Instance Refresh](https://docs.aws.amazon.com/autoscaling/ec2/userguide/asg-instance-refresh.html)
- [Health checks for instances in an Auto Scaling group](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-health-checks.html)
- [Spot Instance interruptions](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-interruptions.html)
- [AWS FIS actions reference](https://docs.aws.amazon.com/fis/latest/userguide/fis-actions-reference.html)
- [Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html) · [Run Command](https://docs.aws.amazon.com/systems-manager/latest/userguide/run-command.html)
- [Instance metadata (IMDSv2)](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html)
- [Packer Amazon EBS builder](https://developer.hashicorp.com/packer/integrations/hashicorp/amazon/latest/components/builder/ebs)

**Pending verification pass:** the AWS Documentation MCP server was connected mid-design but requires a session restart to become available. Before implementation, re-check against it:

- Exact FIS action parameter and target-key names for `aws:ec2:send-spot-instance-interruptions`.
- Whether that FIS action emits a *rebalance recommendation* in addition to the interruption notice. Verification step 9 assumes it does; if not, Capacity Rebalance still belongs in the stack but cannot be demonstrated through FIS and the runbook should say so.
- `stress-ng` availability in the AL2023 repos.
- Whether `t4g` and `c6g` are both offered in `ap-southeast-3`.

The first three are also flagged in the risks table.
