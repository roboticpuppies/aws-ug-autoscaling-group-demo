# AWS UG Demo — Auto-Scaling & Spot Instances

Design doc for the live demo supporting the talk *"Auto-Scaling & Spot Instance: SLA 99.95% dengan Biaya Lebih Hemat"*.

- **Date:** 2026-08-04
- **Region:** `ap-southeast-1` (Singapore)
- **IaC:** Terraform (infrastructure) + Packer (AMI)

> **Why not Jakarta.** `ap-southeast-3` was the first choice for latency, but AWS FIS does not exist there — it is absent from the [FIS endpoints list](https://docs.aws.amazon.com/general/latest/gr/fis.html), and the EC2 guide names Asia Pacific (Jakarta) explicitly among the Regions where initiating a Spot interruption is unsupported. FIS is regional, so it must run where the instances are; there is no split-region workaround short of a second full stack. Singapore is the nearest Region with FIS, and offers all four chosen instance types in all three of its AZs.

## Status

Design approved in outline, and the AWS documentation verification pass is complete — its results are folded in throughout and summarised under [References](#references). **Not yet implemented — no Terraform or Packer code exists.**

Next steps, in order:

1. Write the implementation plan.
2. Hand off to the implementing agent.

**Who does what.** This spec and the implementation plan are authored by Claude; the code is written by a *different* AI agent that will not have seen the design conversation. Everything an implementer needs must therefore be explicit here or in the plan — file paths, resource names, and acceptance criteria that can be checked objectively. Claude reviews the resulting code against this spec afterwards.

**Human-gated commands.** No agent runs `terraform apply`, `terraform destroy`, or `packer build`. Those create real, billable AWS resources. Agents are limited to `make fmt` and `make validate`; the Makefile in §14 groups its targets by exactly this boundary. The rehearsal under [Verification](#verification) is the author's own step, so a review can confirm spec conformance and static correctness but never runtime behavior.

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
- Availability measurement. Nothing in this stack measures uptime, and no CloudWatch dashboard is built. The talk's 99.95% figure is an architectural argument — On-Demand floor, multi-AZ spread, ALB health checks, Capacity Rebalance — not a number this demo produces. The demo shows the *mechanisms* that support the claim. Worth being straight about that on stage rather than implying the graph proves it, because there is no graph.

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
- **Build instance:** `t4g.micro` in `ap-southeast-1`.
- **Installed:**
  - Docker Engine (`dnf install -y docker`), enabled and started via systemd.
  - AWS CLI v2 (`dnf install -y awscli-2`). AL2023 ships a v2 CLI already; the build installs explicitly and asserts `aws --version` so the AMI's contents are not left to base-image drift.
  - `stress-ng` (`dnf install -y stress-ng`), for the CPU-trigger demo. Confirmed present in the AL2023 repos — see [Packages formerly in EPEL](https://docs.aws.amazon.com/linux/al2023/ug/epel.html). No EPEL or SPAL repo needs enabling.
  - `nginx:alpine` pre-pulled into the local Docker image cache, so user-data's `docker pull` is a fast cache hit and scale-out looks snappy on stage.
- **Tags:** `Project=Demo`, plus `Name` and a build-version tag so Terraform can select the newest build.

### 2. Network

- VPC `10.0.0.0/16`.
- Three public subnets, `/24` each, one per AZ across the three AZs of `ap-southeast-1` (`ap-southeast-1a`, `1b`, `1c`), with `map_public_ip_on_launch = true`. Discover them with a `data.aws_availability_zones` lookup rather than hardcoding names.
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
- Inline policy: `ec2:CreateTags`, so the instance can name itself (§6). Scope it tightly — this is the one permission here that could otherwise reach beyond the demo:

  | Element | Value |
  | --- | --- |
  | Action | `ec2:CreateTags` |
  | Resource | `arn:aws:ec2:<region>:<account>:instance/*` |
  | Condition | `StringEquals` on `aws:ResourceTag/Project` = `Demo` |
  | Condition | `ForAllValues:StringEquals` on `aws:TagKeys` = `["Name"]` |

  The two conditions together mean an instance can write only the `Name` tag, and only onto instances already carrying `Project=Demo`. It cannot touch unrelated instances in the account, and cannot alter any other tag — including the `Project` tag that gates its own access.

  **Ordering dependency, worth stating because it is easy to break:** the `aws:ResourceTag/Project` condition is evaluated against tags the instance *already has*. It works only because the ASG propagates `Project=Demo` at launch (§7), before user-data runs. If that propagation is ever removed, self-tagging silently starts failing with `UnauthorizedOperation`.

To scope the autoscaling policy without a Terraform dependency cycle (the ASG needs the instance profile, the profile's policy needs the ASG ARN), the ASG name is set explicitly from a variable and the ARN is constructed from known account/region/name rather than read off the ASG resource. Use `data.aws_caller_identity` and `data.aws_region` for the account and region in both policies.

**FIS role:** trusted by `fis.amazonaws.com`. Attach the AWS managed policy [`AWSFaultInjectionSimulatorEC2Access`](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AWSFaultInjectionSimulatorEC2Access.html), which the actions reference names as the managed policy for this action — it already covers `ec2:SendSpotInstanceInterruptions` and `ec2:DescribeInstances`, the only two permissions the action requires. Prefer it over a hand-rolled policy: one line instead of a custom document, and it tracks AWS's own changes. Add CloudWatch read separately for the stop-condition alarm. See [IAM roles for FIS experiments](https://docs.aws.amazon.com/fis/latest/userguide/getting-started-iam-service-role.html).

Reference: [Session Manager prerequisites / instance permissions](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-prerequisites.html), [`CompleteLifecycleAction`](https://docs.aws.amazon.com/autoscaling/ec2/APIReference/API_CompleteLifecycleAction.html).

### 5. Launch template

- `image_id` from a `data.aws_ami` lookup: most recent, owned by self, filtered on the Packer `Project=Demo` tag and name prefix.
- IMDSv2 required (`http_tokens = "required"`).
- Instance profile and `instance_sg` attached.
- Default `instance_type = t4g.micro` — overridden per-type by the mixed instances policy, but set so the template is valid standalone.
- `credit_specification { cpu_credits = "unlimited" }` — matches the T4g default, but pinned deliberately. See §9 for why `standard` would break bootstrap. Harmless on the non-burstable `c6g` overrides, which ignore it.
- `user_data` = base64 of the rendered bootstrap script.
- Tag specifications: `Project=Demo`. No `Name` — instances set their own (§6).
- `key_name` attached only when the optional variable is set (§13); unset by default.

**Gotcha to encode:** do **not** set `instance_market_options` on the launch template. Spot purchasing is owned by the ASG's mixed instances policy; setting it in both places conflicts. Worth calling out in `docs/spot-strategy.md` — it's a common trap.

### 6. User-data bootstrap

Rendered from `terraform/templates/user-data.sh.tftpl`. Logs everything to `/var/log/user-data.log`.

1. Fetch an IMDSv2 token, then read instance ID, AZ, instance type, and `instance-life-cycle` (`spot` vs `on-demand`).
2. **Name itself.** Compute `<asg-name>-<last 5 characters of the instance ID>` and apply it as the `Name` tag on its own instance via `aws ec2 create-tags`. The ASG name is already injected by Terraform for step 6, so reuse it.
3. Write `/opt/demo/html/index.html` showing the computed name plus all four metadata values — so a browser refresh against the ALB visibly proves which instance served the request, and whether it was Spot.
4. `docker pull nginx:alpine` (cache hit from the AMI), then `docker run -d --name web -p 80:80 -v /opt/demo/html:/usr/share/nginx/html:ro nginx:alpine`.
5. Poll `curl -fs localhost:80` until it returns 200, with a bounded retry count.
6. On success: `aws autoscaling complete-lifecycle-action --lifecycle-action-result CONTINUE` for the launch hook, passing the instance ID, hook name, and ASG name (hook and ASG names injected by Terraform at render time).
7. On any failure: the `on_failure` handler completes with `ABANDON`, so a broken instance is replaced promptly instead of waiting out the heartbeat timeout.

This is the point of the launch hook: the instance is not `InService` and takes no ALB traffic until nginx is actually answering. Not merely "EC2 booted".

**Failure handling.** The script runs under `set -euo pipefail` with `trap 'on_failure $LINENO' ERR`, so any unhandled command failure routes through a single `on_failure` handler rather than dying silently halfway through bootstrap.

`on_failure` does two things, in this order:

1. `trap - ERR` immediately, so a failure inside the handler cannot recurse.
2. Call `complete-lifecycle-action` with `ABANDON`, then invoke the notification hook below. **`ABANDON` goes first, deliberately** — it is the time-sensitive part. Notification is best-effort, and a hanging webhook call must not delay the ASG replacing a dead instance.

**Notification hook — a documented stub, not an implementation.** `on_failure` calls a `notify_failure` function whose body in this repo is *only a comment*. The comment explains what it would do in a real deployment and is part of the deliverable — the point is to show where operational alerting belongs in a bootstrap script, without adding a Slack dependency to a demo. The comment must cover:

- What it would send: instance ID, self-assigned `Name`, AZ, instance type, Spot vs On-Demand, the failing line number, and the tail of `/var/log/user-data.log`.
- Where it would send it: an incoming webhook (Slack or equivalent).
- **Where the webhook URL must come from: Secrets Manager or SSM Parameter Store, fetched at runtime — never hardcoded in user-data.** User-data is readable through the instance metadata service by any process or user on the instance, and is visible in the launch template to anyone with `ec2:DescribeLaunchTemplateVersions`. A webhook URL is a credential: anyone holding it can post into the channel. This is the single most important line in the comment, because inlining the URL is the obvious-looking shortcut and it leaks the secret two different ways.

**Guard the non-fatal calls.** Because `set -e` plus the `ERR` trap makes *any* failure fatal by default, the deliberately non-fatal steps must be explicit about it — `aws ec2 create-tags ... || log "WARN: self-tagging failed"`. Without that guard a failed cosmetic tag would trip the trap and abandon a perfectly healthy instance, which is precisely the behavior ruled out above.

**On the self-naming step.** The pattern deliberately echoes Kubernetes pod names — `asg-demo-4f7a2` — so instances are identifiable at a glance in the console, in `make status`, and on the served page, instead of appearing as a wall of identical blank-named rows.

Two properties to be aware of:

- **Uniqueness is probabilistic, not guaranteed.** Five hex characters is about a million combinations; with at most 5 instances a collision is vanishingly unlikely but not impossible. Kubernetes pod suffixes have the same property. Do not build anything that depends on the name being unique — the instance ID remains the identifier.
- **Tagging failure must not fail the bootstrap.** The `Name` tag is cosmetic. If `create-tags` errors, log it and carry on to start nginx; do not abandon an otherwise healthy instance over a label. Only nginx failing to answer triggers `ABANDON`.

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
- **Tags:**
  - `Project=Demo` with `propagate_at_launch = true`. This is what FIS targets on, and what the `ec2:CreateTags` condition in §4 checks — so it must reach instances at launch.
  - `Name` on the ASG resource itself with **`propagate_at_launch = false`**. Instances name themselves in user-data (§6); propagating a `Name` here too would mean the ASG writes one value and user-data immediately overwrites it, which is confusing to watch on stage and pointless. The ASG still gets its own `Name` for the console.

Reference: [Auto Scaling groups with multiple instance types and purchase options](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-mixed-instances-groups.html), [Allocation strategies](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-az-instance-type-distribution.html), [`aws_autoscaling_group`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/autoscaling_group).

### 8. Lifecycle hooks

| Hook | Transition | Heartbeat | Default result | Completed by |
| --- | --- | --- | --- | --- |
| Launch | `autoscaling:EC2_INSTANCE_LAUNCHING` | 300s | `ABANDON` | the instance itself, from user-data |
| Terminate | `autoscaling:EC2_INSTANCE_TERMINATING` | 60s | `CONTINUE` | nobody — it times out |

The launch hook's `ABANDON` default is the safe failure mode: an instance whose bootstrap never finishes gets replaced rather than joining the ALB half-built.

The terminate hook deliberately does nothing but hold the instance in `Terminating:Wait` for 60s, then proceed on timeout. This is the mechanism-demonstration route, chosen on purpose: it shows the hook exists and holds, with no extra moving parts to fail on stage.

**Why 60s is enough, and not arbitrary.** The hook fires before the instance is terminated, and the ALB begins deregistering it at the same time. With the target group's `deregistration_delay = 30` (§10), draining finishes well inside the 60s hold — so by the time the hook releases, in-flight requests have already completed. The plain wait is therefore not merely a demonstration of the mechanism; at these numbers it *is* a graceful drain, achieved by arithmetic rather than by a Lambda. Keep the hook's heartbeat comfortably above the deregistration delay: if someone later raises `deregistration_delay` past 60s without raising this, connections start getting cut.

60s also keeps the demo watchable. A longer hold (the earlier draft used 900s) would strand an instance in `Terminating:Wait` for a quarter of an hour, long past the point the audience has moved on. `docs/lifecycle-hooks.md` documents the cleaner production alternative (EventBridge rule on the terminate lifecycle event → Lambda → deregister from target group, wait for drain → `complete-lifecycle-action`) and explains why an external trigger is required there — a terminating instance, especially a reclaimed Spot instance, cannot be relied on to complete its own hook.

### 9. Scaling policy

Target tracking on `ASGAverageCPUUtilization`, target **10%**.

**10% is the t4g.micro baseline, and that is the whole point.** It is not an arbitrarily low demo number. `t4g.micro` earns 12 CPU credits per hour across 2 vCPUs, giving a baseline utilization of 12 ÷ 2 ÷ 60 = **10%** — the level at which credits earned exactly matches credits spent. CloudWatch's `CPUUtilization` is measured per instance, not per core, and the baseline specification uses the same basis, so the two are directly comparable: a 10% target sits precisely on the break-even line.

Setting the target there means the group scales out *before* instances need to draw down credit balance at all. Capacity is added while every instance is still running at or under baseline, so the CPU signal driving the policy stays linear and trustworthy rather than being distorted by credit exhaustion.

**Credit mode: `unlimited`, set explicitly.** This matters enough to pin rather than inherit:

- `T4g` **defaults to `unlimited`**, in which an instance bursts above baseline for as long as it likes and AWS bills [surplus credits](https://aws.amazon.com/ec2/pricing/on-demand/#T2.2FT3.2FT4g_Unlimited_Mode_Pricing) at a flat per-vCPU-hour rate. No throttling ever occurs. Under `standard` mode, by contrast, an instance that depletes its credits *is* throttled to baseline — which would flatten `CPUUtilization` at 10% and make the metric lie to the scaling policy.
- **Do not "optimize" this to `standard`.** Launch credits are a **T2-only** feature; a `standard`-mode `t4g` starts with zero accrued credits and is throttled to baseline from the moment it boots. `docker pull` plus container start would then crawl, risk exceeding the launch hook's 300s heartbeat, and get the instance `ABANDON`ed — producing continuous launch-and-replace churn that looks like a broken stack. AWS [recommends `unlimited` specifically for ASG-launched T instances](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-performance-instances-how-to.html) for this reason.
- Declaring it in the launch template also puts it on screen during the talk, where the burstable-credit point is worth making out loud.

So the two settings do different jobs: `unlimited` guarantees the metric never lies, and the 10% target keeps *steady-state* utilization at or below baseline.

**The surplus-credit trade-off, stated honestly.** During `make stress` every instance bursts to 100% for up to 900s, which does spend surplus credits — this is not a rare event, it is the centrepiece of the demo. AWS in fact [recommends `standard` mode](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/how-spot-instances-work.html) for burstable Spot instances used immediately and for a short duration, precisely because they never idle long enough to pay the surplus down. We keep `unlimited` regardless, for the launch-credit reason above: the bootstrap risk under `standard` is a broken demo, whereas the surplus over a 25-minute run is cents. Worth knowing so the choice is not mistaken for a cost optimisation.

**Known trade-off with the mixed fleet.** `c6g.medium` and `c6g.large` are fixed-performance instances — no credits, no baseline. The 10% target is calibrated to the burstable members of the fleet, so on a `c6g` instance it simply means scaling out early and over-provisioning slightly. That is an accepted cost of calibrating to the weakest member, not an oversight.

**Demo consequence to rehearse:** because the target sits at baseline, ordinary idle and boot-time CPU can nudge the group into scaling out unprompted. Rehearse the timing so it does not fire mid-sentence.

### 10. ALB

- ALB across the three public subnets, `alb_sg`.
- Target group: HTTP 80, health check path `/`, healthy threshold 2, interval 15s, timeout 5s.
- `deregistration_delay = 30` — keeps drain visibly quick during the demo, and sits deliberately below the terminate hook's 60s hold (§8) so draining always completes before termination proceeds. These two numbers are coupled; change one and check the other.
- Listener on 80, forwarding to the target group.

### 11. Instance Refresh

**Not** declared as a Terraform `instance_refresh` block. That block auto-triggers a refresh whenever the launch template changes, which is exactly the loss of live control we don't want.

Instead, `docs/instance-refresh.md` documents the ready-to-run CLI invocation with the intended preferences:

- Strategy: `Rolling`
- `MinHealthyPercentage = 100`, `MaxHealthyPercentage = 200` → launch-before-terminate replacement
- Checkpoints left unset

Door open if it's ever needed; nothing fires on stage.

### 12. AWS FIS

Field names below are verified against the [FIS actions reference](https://docs.aws.amazon.com/fis/latest/userguide/fis-actions-reference.html) and the [Spot interruption tutorial](https://docs.aws.amazon.com/fis/latest/userguide/fis-tutorial-spot-interruptions.html). Use them exactly; they are easy to get subtly wrong.

| Element | Value |
| --- | --- |
| Action ID | `aws:ec2:send-spot-instance-interruptions` |
| Action target key | `SpotInstances` (this exact key — it is not the target's own name) |
| Action parameter | `durationBeforeInterruption`, ISO 8601, valid range 2–15 minutes |
| Target resource type | `aws:ec2:spot-instance` |
| Target resource tag | `Project=Demo` |
| Target filter | path `State.Name`, value `running` |
| Selection mode | `COUNT(1)` |
| Role | the FIS role above |

**Stop condition:** CloudWatch alarm on the ALB's `HealthyHostCount` dropping below 1 — aborts the experiment rather than deepening an outage. (The AWS tutorial uses `source = "none"`; we deliberately do not, because this runs in front of an audience.)

**`durationBeforeInterruption` is a stage-timing knob, and `PT2M` is probably the wrong choice.** Per the docs, the rebalance recommendation arrives *immediately* when the action starts, while the interruption notice arrives two minutes before the actual interruption. So at the `PT2M` minimum the two signals land almost together and Capacity Rebalance's head start is invisible — the very thing worth showing. A larger value (`PT5M`, say) separates them: rebalance recommendation at t=0, interruption notice around t=3m, termination at t=5m, leaving a visible window where the ASG has already launched a replacement while the doomed instance is still serving. Set `PT5M`, and confirm the observed timeline during rehearsal — this reading of the interaction between the two signals is inferred from the documentation, not something AWS spells out end to end.

**Quota:** the default is 5 Spot Instances per experiment when targeting by tags, which `COUNT(1)` sits well inside.

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

### 14. Makefile

A root `Makefile` is the demo's command surface. Two reasons it exists: typing long `aws ssm send-command` and `aws fis start-experiment` invocations live is error-prone and dull to watch, and it keeps the runbook from drifting — the doc references `make stress`, and the Makefile holds the one real definition of what that means.

**Recipes must not be silenced with `@`.** Let make echo each command before running it. On stage the audience then sees the actual AWS CLI call scroll past while the presenter typed three words. Hiding the command would defeat the point of demoing it.

Every target derives region, ASG name, target group ARN, and FIS experiment template ID from `terraform output` — never hardcoded, so the Makefile cannot drift from the deployed stack. `make help` is the default target. All targets are `.PHONY`.

**Agent-safe** — the implementing agent may run these:

| Target | Does |
| --- | --- |
| `help` | Lists targets. Default goal |
| `fmt` | `terraform fmt` |
| `validate` | `terraform validate` and `packer validate` |

**Human-only** — creates, changes, or destroys billable resources. Per the Status section no agent runs these:

| Target | Does |
| --- | --- |
| `ami` | `packer build` |
| `init`, `plan`, `apply` | Terraform lifecycle |
| `destroy` | `terraform destroy`, prompting for confirmation. Never `-auto-approve` |
| `clean-ami` | Deregisters the Packer AMI and deletes its snapshot — Terraform does not own them, so `destroy` leaves them behind |

**Demo drivers** — what the talk actually runs:

| Target | Does |
| --- | --- |
| `url` | Prints the ALB DNS name |
| `poll` | curl loop against the ALB, printing the serving instance ID each second. Makes scale-out and instance replacement visible rather than asserted |
| `status` | ASG instances: `Name` tag, instance ID, AZ, lifecycle (`spot` / `on-demand`), health, lifecycle state. The Spot-vs-On-Demand split becomes concrete here. Show `Name` first — it is the readable handle (§6) |
| `activity` | ASG activity history — scaling events and lifecycle hook results |
| `targets` | Target group health |
| `stress` | SSM Run Command running `stress-ng` on all in-service instances |
| `unstress` | Kills `stress-ng`, so scale-in can be shown too |
| `interrupt` | Starts the FIS experiment |
| `session` | `aws ssm start-session --target $(INSTANCE)` — requires `INSTANCE=i-...` |

`poll` and `status` carry the most weight: without them, scale-out and the Spot split are claims rather than observations.

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
Makefile                    # command surface — see §14
README.md
```

## Documentation plan

Everything lives in `docs/`, per requirement. **Every doc links out to the official AWS documentation for the features it describes** — the audience should be able to leave the talk with authoritative sources, not just this repo's paraphrase. A `References` section at the end of each doc collects them.

- **`runbook.md`** — the stage script, written as a sequence of `make` targets (§14) rather than raw commands, so the doc cannot drift from what the Makefile does: `make ami` → `make apply` → `make url` and `make status` → `make poll` in a second pane → `make stress` → what to watch (CloudWatch CPU, `make activity`, `make targets`, instance IDs rotating in `poll`) → `make unstress` to show scale-in → `make interrupt` → observe replacement → `make destroy` and `make clean-ami`. Includes rough timings so the talk can be paced, and states plainly that the 99.95% figure is an architectural argument rather than something measured here.
- **`packer.md`** — what goes into the AMI and why, how to build, how to verify contents, how Terraform selects the newest build.
- **`lifecycle-hooks.md`** — both hooks, how the launch hook self-completes, why the terminate hook is a plain wait here, and the EventBridge + Lambda alternative for production.
- **`spot-strategy.md`** — mixed instances policy explained: On-Demand base as the availability floor, allocation strategies, type prioritization, Capacity Rebalance, the AZ distribution setting, the `instance_market_options` trap, and the cost comparison that backs the talk title.
- **`fis.md`** — triggering and interpreting the Spot interruption experiment.
- **`instance-refresh.md`** — the documented-but-unwired replacement path.

The root **`README.md`** is separate from all of these: it is written for the *talk's audience*, not for an implementer. It covers what the repo is, how the mechanisms work in prose, the architecture diagram, goals and non-goals, and the `make` commands needed to run the demo — and it links into `docs/` for depth. It is already written and committed, describing the target state ahead of the code.

**Task for the implementing agent:** `README.md` currently opens with a *"Status: not yet implemented"* note. Remove that block as the final step, once `make apply` actually works. Leaving it in would tell readers the repo is broken; removing it early would claim the code exists before it does.

## Verification

No application tests. Verification is static checks plus one full rehearsal.

**Static:** `make fmt` and `make validate` (which wrap `terraform fmt`, `terraform validate`, and `packer validate`), plus `terraform plan`.

**Rehearsal — apply → demo → destroy, at least once before the talk, confirming:**

1. Packer build succeeds and the AMI contains Docker, AWS CLI v2, and a working CPU load generator.
2. `terraform apply` converges; ALB returns the instance-ID page.
3. Exactly 1 instance is On-Demand and the rest are Spot (check `instance-life-cycle` on the page, or `describe-auto-scaling-instances`).
4. Instances spread across AZs.
5. Launch hooks complete as `CONTINUE` — ASG activity history shows no `ABANDON`, and instances reach `InService` promptly rather than after a 300s timeout.
6. CPU load triggers scale-out toward max 5.
7. Terminate hook visibly holds an instance in `Terminating:Wait` for roughly 60s, and `make poll` shows no failed requests while it drains.
8. FIS interrupts one Spot instance; a replacement launches; `HealthyHostCount` never reaches 0 and the ALB keeps serving.
9. Capacity Rebalance is active on the ASG (`describe-auto-scaling-groups` shows `CapacityRebalance: true`), and the FIS run shows a replacement launching off the rebalance signal rather than only after the reclaim.
10. Every instance carries a `Name` tag matching `<asg-name>-<5 chars>`, set by itself, and no instance is left with the ASG-propagated name or no name at all. The served page shows the same value.
11. Removing the `ec2:CreateTags` permission makes self-naming fail *without* failing the bootstrap — instances still reach `InService`. Confirms the tag is genuinely non-fatal and that the `ERR` trap is correctly guarded (§6). Worth checking once, since the failure mode is silent by design.
12. Breaking the bootstrap on purpose (for example, pointing at a nonexistent image tag) makes `on_failure` fire: the ASG activity history shows an `ABANDON` result promptly rather than after the 300s heartbeat timeout, and `/var/log/user-data.log` records the failing line.
13. `git grep` finds no key material and no hardcoded webhook URL, and no port-22 rule exists with the default variable values.
14. Every `make` target in §14 runs against the live stack without error, and each demo driver prints what it claims to.
15. `make destroy` followed by `make clean-ami` leaves nothing behind — including the AMI and its snapshot, which Terraform does not own.

## Risks and open verifications

| Risk | Mitigation |
| --- | --- |
| 10% CPU target scales out from idle noise, mid-sentence | Rehearse; explain it as the deliberate t4g.micro baseline calibration (§9), not a low number picked for effect |
| Someone switches credit mode to `standard` as a cost "optimization" | §9 documents why this throttles from boot and causes launch-hook churn. `unlimited` is pinned explicitly in the launch template rather than inherited |
| Spot capacity shortfall at demo time | Four instance types, all confirmed offered in all three `ap-southeast-1` AZs, plus best-effort AZ spread |
| `availability_zone_distribution` is a recent ASG feature | Pin a recent AWS provider version in `versions.tf` (`~> 6.0`) |
| FIS action requires a genuinely Spot instance | Desired 3 with On-Demand base 1 guarantees 2 Spot instances |
| Rebalance recommendation and interruption notice arrive too close together to show separately | Use `durationBeforeInterruption = PT5M`, not the `PT2M` minimum — see §12 |
| Demo network is slow | `nginx:alpine` pre-baked into the AMI so bootstrap does not depend on a full pull |

Resolved during the verification pass, kept here so they are not re-litigated: `stress-ng` **is** in the AL2023 repos; all four instance types **are** offered in `ap-southeast-1`; the FIS action **does** emit a rebalance recommendation. Region moved off `ap-southeast-3` because FIS does not exist there.

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

**Verification pass — complete (2026-08-04).** Checked against the AWS documentation and, for Region-specific facts, the EC2 API:

| Item | Result |
| --- | --- |
| FIS action ID, target key, parameter name, filter, selection mode | Confirmed; recorded verbatim in §12 |
| Does the FIS action emit a rebalance recommendation? | **Yes** — immediately on action start. Capacity Rebalance is demonstrable; verification step 9 stands |
| `stress-ng` in AL2023 default repos | **Yes** — `dnf install stress-ng`, no EPEL/SPAL needed. The container fallback was removed from §1 |
| `t4g.micro`, `t4g.small`, `c6g.medium`, `c6g.large` offered in the target Region | **Yes**, all four, in all three `ap-southeast-1` AZs (`describe-instance-type-offerings`) |
| FIS available in `ap-southeast-3` | **No** — the reason the Region changed. See the note at the top |
| FIS managed policy | `AWSFaultInjectionSimulatorEC2Access` covers the action's permissions; adopted in §4 |

One item remains open and can only be settled by running it: the exact observed gap between the rebalance recommendation and the interruption notice at `durationBeforeInterruption = PT5M`. Confirm during rehearsal (§12).
