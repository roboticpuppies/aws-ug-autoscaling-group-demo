# AWS FIS Spot interruption

The experiment interrupts exactly one running Spot instance tagged
`Project=Demo`, for real. It is not a simulation and it is not a manual
termination.

## Experiment template

| Field | Value |
| --- | --- |
| Action | `aws:ec2:send-spot-instance-interruptions` |
| Action target key | `SpotInstances` |
| Parameter | `durationBeforeInterruption = PT5M` |
| Target resource type | `aws:ec2:spot-instance` |
| Selection mode | `COUNT(1)` |
| Resource tag | `Project=Demo` |
| Filter | `State.Name = running` |

The `PT5M` duration is within the documented two-to-fifteen-minute range.

## Triggering the experiment

Run `make interrupt`. It prints the experiment ID and its initial status. Follow
the run with `make status`, `make activity`, `make targets`, and the always-on
`make poll` window.

## Sequence

The expected sequence is:

1. A rebalance recommendation arrives immediately when the experiment starts.
2. Capacity Rebalance launches a replacement.
3. The interruption notice arrives about two minutes before termination.
4. The selected instance enters `Terminating:Wait` while the terminate hook
   holds it.
5. The target drains from the ALB, which serves only healthy targets.

## Why `PT5M`, not `PT2M`

At the minimum duration, the rebalance recommendation and interruption notice
land almost together, hiding Capacity Rebalance's head start — the very thing
worth demonstrating. `PT5M` separates them. The precise observed gap should be
confirmed by running the experiment, since AWS documents each signal
separately but not their interaction.

## Stop condition

The template stops on a CloudWatch alarm when `HealthyHostCount < 1`. The AWS
tutorial uses `source = "none"`; this template deliberately does not, because
it runs in front of an audience and should abort rather than deepen an outage.

The default quota is five Spot Instances per experiment when targeting by tags,
so `COUNT(1)` sits well inside it.

## Region constraint

**AWS FIS is not available in `ap-southeast-3` (Jakarta).** This demo runs in
`ap-southeast-1` for that reason. FIS is regional and must run where the
instances are; there is no split-region workaround short of a second full
stack.

## References

- [FIS actions reference](https://docs.aws.amazon.com/fis/latest/userguide/fis-actions-reference.html)
- [Test Spot interruptions with AWS FIS](https://docs.aws.amazon.com/fis/latest/userguide/fis-tutorial-spot-interruptions.html)
- [Spot Instance interruptions](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-interruptions.html)
- [EC2 instance rebalance recommendation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/rebalance-recommendations.html)
