# Stage runbook

This is the stage script for the AWS User Group Auto Scaling and Spot demo.

## Prerequisites

You need AWS credentials with permission to build and operate the stack,
Terraform, Packer, AWS CLI v2, GNU Make, and the Session Manager plugin. The
AMI must be built before `make plan` works: `data.aws_ami.demo` has nothing to
find until `make ami` has produced at least one tagged AMI.

## Timeline

| Phase | Command(s) | Rough duration |
| --- | --- | ---: |
| AMI build, before the talk | `make ami` | ~5 min |
| Stack creation | `make init`, then `make apply` | ~4 min |
| First look | `make url`, `make status` | ~2 min |
| Scale-out | `make stress` | ~5 min |
| Scale-in | `make unstress` | ~3 min |
| Spot interruption | `make interrupt` | ~6 min at `PT5M` |
| Teardown | `make destroy`, then `make clean-ami` | ~4 min |

That is roughly 25 minutes in total. Build the AMI before the audience arrives;
waiting for three instances to bootstrap on stage is dead air. `make apply` is
setup, not a live-demo step.

## Setup before the audience arrives

Run `make ami`, then `make init`, then `make apply`. Confirm that the ALB and
three instances are healthy before beginning the talk.

## Beat 1 — the stack exists

Run `make url` and open the printed URL in a browser. Run `make status` to show
three instances spread across three Availability Zones: one has an empty
`Purchase` column because it is the On-Demand floor, and two show `spot`.

Instance names look like `asg-demo-<5 chars>`, Kubernetes-pod style. Each
instance read its own metadata and named itself in user-data; the name was not
chosen by the launch template.

## Beat 2 — keep the poll window visible

Start `make poll` in a second terminal and leave it running for the rest of the
demo. It curls `/name.txt` once per second and is the single most useful window
on screen: it shows which instance and Availability Zone served each request.

## Beat 3 — scale-out

Run `make stress`, then use `make activity` and `make targets` while waiting.
The target is 10% CPU because that is the `t4g.micro` credit baseline: 12
credits/hour ÷ 2 vCPU ÷ 60 min. It is not an arbitrarily low number. Instances
run in `unlimited` credit mode, so the metric is not distorted by throttling.
Watch new instance names appear in `make poll` as the group scales out.

## Beat 4 — scale-in

Run `make unstress` and watch the group shrink. In `make status`, point out an
instance in `Terminating:Wait` for about 60 seconds: that is the terminate
lifecycle hook. `make poll` should show no failed requests because the target
group's 30-second deregistration delay completes inside the 60-second hold.

## Beat 5 — Spot interruption

Run `make interrupt`. The sequence is:

1. EC2 emits a rebalance recommendation immediately.
2. Capacity Rebalance starts a replacement.
3. The interruption notice arrives about two minutes before termination.
4. The instance enters `Terminating:Wait` while the terminate hook holds it.
5. The target drains and the ALB routes only to healthy targets.

Keep `make poll` visible. The point is that it never fails while a real Spot
instance is interrupted.

## Beat 6 — teardown

Run `make destroy`, then `make clean-ami`. `make destroy` alone leaves the AMI
and its snapshot behind because Terraform does not own them; those leftovers
quietly continue costing money.

## What this demo does not show

This demo does not measure availability. There is no dashboard and no uptime
number. The 99.95% figure in the talk title is an architectural argument — an
On-Demand floor, multi-AZ spread, ALB health checks, and Capacity Rebalance —
not a figure this demo produces. Say that on stage rather than implying that
the stack measured it.

## Troubleshooting

- If `make plan` fails with “Your query returned no results”, `make ami` has not
  run yet or did not leave a matching AMI.
- If instances cycle through `ABANDON` in `make activity`, user-data is failing.
  Use `make session INSTANCE=...` and inspect `/var/log/user-data.log`.
- If `make interrupt` fails, either no Spot instance is currently running or
  the region lacks AWS FIS. This stack uses `ap-southeast-1` because FIS is not
  available in `ap-southeast-3`.

## References

- [Lifecycle hooks](https://docs.aws.amazon.com/autoscaling/ec2/userguide/lifecycle-hooks.html)
- [Target tracking scaling policies](https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-target-tracking.html)
- [Test Spot interruptions with AWS FIS](https://docs.aws.amazon.com/fis/latest/userguide/fis-tutorial-spot-interruptions.html)
- [Run Command](https://docs.aws.amazon.com/systems-manager/latest/userguide/run-command.html)
