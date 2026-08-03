# Auto-Scaling & Spot Instances — AWS UG Demo

Demo code for the talk **"Auto-Scaling & Spot Instance: SLA 99.95% dengan Biaya Lebih Hemat."**

It stands up a small, complete stack in AWS that runs most of its capacity on Spot Instances — the cheap, interruptible kind — and stays available anyway. Then it deliberately breaks one of those instances, on purpose, in front of you.

> **Status: not yet implemented.** The design is finished (`docs/superpowers/specs/`), but the Terraform and Packer code is still being written. `make apply` will not work yet. This note disappears when the code lands.

## What this repo is

A throwaway demo, not a production template. It exists to make four things visible rather than merely asserted:

1. **Auto-scaling that reacts to real load** — CPU crosses a threshold, new instances appear.
2. **Lifecycle hooks on both ends** — an instance takes no traffic until its web server actually answers, and a terminating instance is held briefly before it disappears.
3. **Spot at 2/3 of capacity, with an On-Demand floor** — one instance is always On-Demand; everything above it is Spot, spread across four instance types.
4. **Surviving a Spot interruption** — AWS FIS injects a genuine interruption, and the site keeps serving.

Everything is destroyed after the talk. Total running cost is cents per hour.

- **Region:** `ap-southeast-1` (Singapore)
- **Tooling:** Terraform (infrastructure), Packer (AMI), Make (commands)
- **Workload:** nginx in Docker, serving a page that names the instance serving it

Jakarta (`ap-southeast-3`) would have been closer, but AWS FIS does not exist there — so the Spot-interruption demo, which is half the point, is impossible in that Region. Singapore is the nearest Region that has it.

## Goals

- Show dynamic scaling driven by a CPU target-tracking policy.
- Show ASG lifecycle hooks firing on launch and on terminate.
- Show a mixed instances policy: a 1-instance On-Demand floor, everything above it on Spot.
- Show resilience to a Spot interruption, injected on demand.
- Keep every mechanism small enough to read off a projector.

## Non-goals

Left out on purpose, to keep the stack legible and cheap:

- **Production hardening.** No private subnets, NAT, HTTPS, WAF, or access logs. This is a demo in public subnets.
- **Availability measurement.** Nothing here measures uptime, and there is no dashboard. The 99.95% in the talk title is an *architectural argument* — On-Demand floor, multi-AZ spread, ALB health checks, Capacity Rebalance — not a number this demo produces. What you will see is the mechanisms that support the claim, not a measurement of it.
- **Any private key in this repository.** Access is via SSM Session Manager instead. See [Getting a shell](#getting-a-shell-on-an-instance).
- **Application tests.** This is infrastructure code.

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

| Piece | What it is |
| --- | --- |
| VPC | `10.0.0.0/16`, three public subnets, one per AZ |
| ALB | Public on port 80, health-checking `/` |
| Auto Scaling group | min 1, desired 3, max 5, across all three AZs |
| Launch template | Points at the Packer AMI, requires IMDSv2 |
| AMI | Amazon Linux 2023 arm64 with Docker, AWS CLI v2, and `stress-ng` pre-installed |
| Instance types | `t4g.micro`, `t4g.small`, `c6g.medium`, `c6g.large` — all arm64 Graviton, in priority order |
| FIS experiment | Interrupts one Spot instance on demand |

## How it works

### An instance joining

1. The ASG launches an instance from the Packer AMI.
2. A **launch lifecycle hook** holds it in `Pending:Wait`. It is not in service, and the ALB sends it nothing.
3. User-data reads the instance's own ID, AZ, type, and whether it is Spot or On-Demand from instance metadata.
4. **The instance names itself** `asg-demo-4f7a2` — the ASG name plus the last five characters of its own instance ID, deliberately echoing the way Kubernetes names pods. It writes that as its own `Name` tag. Instances are then identifiable at a glance instead of being a wall of blank rows in the console.
5. User-data writes the name and metadata into an HTML file and starts nginx in Docker serving it.
6. User-data polls its own port 80 until nginx answers, then calls `complete-lifecycle-action` to release the hook.
7. The instance goes `InService`, passes ALB health checks, and starts taking traffic.

The point: an instance joins the load balancer when the *application* is ready, not when the *EC2 instance* has booted. If bootstrap fails, the hook times out as `ABANDON` and the instance is replaced instead of joining half-built.

Self-naming needs `ec2:CreateTags`, which the instance role grants — but narrowly. It is restricted to writing only the `Name` key, and only onto instances already tagged `Project=Demo`, so an instance cannot rename anything else in the account or edit any other tag.

### Scaling on load

A target-tracking policy keeps average CPU at **10%**. That number is absurdly low on purpose — it makes scale-out happen within a couple of minutes so it fits inside a talk. Do not copy it into production.

`make stress` runs `stress-ng` on every instance via SSM. CPU climbs, the policy adds instances toward the maximum of 5. `make unstress` releases the load and scale-in follows.

### Cheap but available

The mixed instances policy sets **On-Demand base capacity = 1** and puts **100% of everything above that on Spot**. At the default desired capacity of 3, that is 1 On-Demand + 2 Spot.

Spot capacity is requested across four instance types using the `capacity-optimized-prioritized` strategy: it respects the type priority order where it can, while preferring the deepest capacity pools — the pools least likely to be reclaimed. Instances are spread across three AZs on a best-effort basis, so no single AZ running out of Spot capacity can block a launch.

**Capacity Rebalance** is enabled. EC2 emits a *rebalance recommendation* when a Spot instance is at elevated risk of being reclaimed — earlier than the well-known two-minute warning. With Capacity Rebalance on, the ASG launches a replacement on that earlier signal, so the replacement is often already serving before the doomed instance goes away.

### Surviving an interruption

`make interrupt` starts an AWS FIS experiment that sends a real Spot interruption to one Spot instance:

1. The instance immediately receives a **rebalance recommendation**. Capacity Rebalance reacts and the ASG starts a replacement.
2. A **two-minute interruption notice** follows.
3. The instance enters `Terminating:Wait`, where the **terminate lifecycle hook** holds it.
4. It is removed from the ALB target group and drains; the replacement is already in service.
5. The site keeps answering throughout — watch `make poll` while this happens.

A CloudWatch alarm acts as a stop condition: if healthy hosts ever drop below 1, the experiment aborts rather than making things worse.

## How to run it

### Prerequisites

- AWS credentials for an account you are happy to create and destroy resources in
- [Terraform](https://developer.hashicorp.com/terraform/downloads), [Packer](https://developer.hashicorp.com/packer/downloads), [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), `make`
- The [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) for the AWS CLI, if you want a shell on an instance

Commands are not silenced — each `make` target prints the real AWS CLI or Terraform command before running it, so you can see exactly what is happening and copy it.

### Build and deploy

```bash
make help      # list every target
make ami       # build the AMI with Packer (do this first)
make init      # terraform init
make plan      # review what will be created
make apply     # create the stack
```

### Run the demo

```bash
make url       # print the ALB address
make status    # ASG instances: name, ID, AZ, spot or on-demand, health
make poll      # curl loop — prints which instance served each request

make stress    # drive CPU up via SSM, triggers scale-out
make activity  # ASG scaling events and lifecycle hook results
make targets   # ALB target group health
make unstress  # release the load, watch scale-in

make interrupt # inject a real Spot interruption via FIS
```

Run `make poll` in a second terminal and leave it there. It is the clearest view of what the stack is doing: instance IDs rotate as capacity changes, and it keeps returning 200s through the interruption.

### Tear down

```bash
make destroy    # destroy the Terraform-managed stack (asks for confirmation)
make clean-ami  # deregister the AMI and delete its snapshot
```

Both matter. Terraform does not own the Packer AMI or its snapshot, so `make destroy` alone leaves them behind, quietly costing money.

### Getting a shell on an instance

There is **no SSH key in this repository** and none is needed. Use Session Manager:

```bash
make session INSTANCE=i-0abc123...
```

No key material, no port 22 open, and every session is logged in CloudTrail.

If you clone this and genuinely want SSH, two variables let you opt in with *your own* key:

| Variable | Default | Effect |
| --- | --- | --- |
| `key_name` | unset | An existing EC2 key pair name to attach to instances |
| `ssh_ingress_cidr` | unset | Opens port 22 to this CIDR only |

Set `ssh_ingress_cidr` to your own address. Do not set it to `0.0.0.0/0`.

### Cost

Three small instances (mostly Spot) plus one ALB — cents per hour, with the ALB's hourly charge dominating. It is cheap, but not free: destroy it when you are done.

## Documentation

Deeper explanations live in [`docs/`](docs/):

| Doc | Covers |
| --- | --- |
| [`runbook.md`](docs/runbook.md) | The demo, start to finish, with timings |
| [`spot-strategy.md`](docs/spot-strategy.md) | Mixed instances policy, allocation strategies, the cost argument |
| [`lifecycle-hooks.md`](docs/lifecycle-hooks.md) | Both hooks, and the production-grade alternative to the simple one used here |
| [`fis.md`](docs/fis.md) | Running and reading the Spot interruption experiment |
| [`packer.md`](docs/packer.md) | What is in the AMI and how it is built |
| [`instance-refresh.md`](docs/instance-refresh.md) | Rolling instance replacement — available, not wired up |

The full design, including decisions that were considered and rejected, is in [`docs/superpowers/specs/`](docs/superpowers/specs/).

## References

- [EC2 Auto Scaling — multiple instance types and purchase options](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-mixed-instances-groups.html)
- [Capacity Rebalancing](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-capacity-rebalancing.html)
- [Auto Scaling lifecycle hooks](https://docs.aws.amazon.com/autoscaling/ec2/userguide/lifecycle-hooks.html)
- [Target tracking scaling policies](https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-target-tracking.html)
- [Spot Instance interruptions](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-interruptions.html)
- [Test Spot interruptions with AWS FIS](https://docs.aws.amazon.com/fis/latest/userguide/fis-tutorial-spot-interruptions.html)
- [AWS Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
