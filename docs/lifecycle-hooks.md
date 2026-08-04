# Lifecycle hooks

The demo uses one hook to hold a new instance until the application is ready
and another to let the ALB drain before termination.

## Both hooks

| Hook | Transition | Heartbeat | Default | Completion |
| --- | --- | ---: | --- | --- |
| Launch | `autoscaling:EC2_INSTANCE_LAUNCHING` | 300s | `ABANDON` | The instance completes it from user-data. |
| Terminate | `autoscaling:EC2_INSTANCE_TERMINATING` | 60s | `CONTINUE` | Nobody completes it; it times out. |

## How the launch hook self-completes

User-data performs this sequence:

1. Read instance identity and lifecycle metadata through IMDSv2.
2. Derive the instance name from the ASG name and the last five characters of
   the instance ID, then tag itself.
3. Write `/opt/demo/html/index.html` and the machine-readable `name.txt` file.
4. Start nginx in Docker.
5. Poll port 80 until nginx answers.
6. Run `complete-lifecycle-action` with
   `--lifecycle-action-result CONTINUE`.

The point is that an instance joins the load balancer when the application is
ready, not when EC2 merely finished booting.

## Why the launch default is `ABANDON`

An instance whose bootstrap never finishes is replaced rather than joining the
ALB half-built. The failure handler sends `ABANDON` while the instance is still
in the launch wait state.

## Why both hooks are initial hooks inside the ASG

Both are `initial_lifecycle_hook` blocks inside `aws_autoscaling_group`. A
separate `aws_autoscaling_lifecycle_hook` resource is created after the ASG, so
the first instances could launch before the hook existed and reach `InService`
without waiting for nginx. That defeats the hook exactly once, on the first
apply, which is the hardest case to notice.

## Why the terminate hook is a plain wait

The terminate hook deliberately completes by timeout. Its 60-second heartbeat
exceeds the target group's 30-second `deregistration_delay`, so draining
finishes inside the hold and in-flight requests complete. At these numbers the
plain wait is a graceful drain achieved by arithmetic rather than by a Lambda.

Do not raise `deregistration_delay` above 60 without also raising the terminate
heartbeat; doing so starts cutting connections before the hold ends.

## Production alternative: an external trigger

A production implementation could use an EventBridge rule on the terminate
lifecycle event to invoke a Lambda. The Lambda would deregister the instance
from the target group, wait for drain, and call `complete-lifecycle-action`.

An external trigger is required because a terminating instance — especially a
reclaimed Spot instance — cannot be relied on to complete its own hook. That is
why the launch hook can self-complete but the terminate hook cannot. This repo
does not build the EventBridge/Lambda path: it has fewer moving parts to fail on
stage.

## The failure handler

`set -euo pipefail` plus an `ERR` trap routes failures into `on_failure`. The
handler drops the trap, sends `ABANDON`, and then calls the `notify_failure`
stub. `ABANDON` goes first because notification is best effort and a hanging
webhook must not delay replacement.

The `create-tags` call is deliberately guarded with `|| log`. Self-naming is
cosmetic, so a tag failure cannot trip the trap and abandon an otherwise healthy
instance. The notification stub documents how a real deployment could fetch a
webhook credential from Secrets Manager or SSM Parameter Store without putting a
secret in user-data.

## References

- [Lifecycle hooks](https://docs.aws.amazon.com/autoscaling/ec2/userguide/lifecycle-hooks.html)
- [`CompleteLifecycleAction`](https://docs.aws.amazon.com/autoscaling/ec2/APIReference/API_CompleteLifecycleAction.html)
- [Target group deregistration delay](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/edit-target-group-attributes.html)
