# Spot strategy

This stack is cheap without being fragile: Spot supplies most of the fleet,
while an On-Demand floor, multiple capacity pools, multi-AZ placement, health
checks, and Capacity Rebalance keep the service from depending on one reclaimable
instance.

## The shape of the policy

| Setting | Value | What it does |
| --- | --- | --- |
| `on_demand_base_capacity` | `1` | Keeps one instance On-Demand before Spot capacity is considered. |
| `on_demand_percentage_above_base_capacity` | `0` | Makes every unit above the floor Spot when capacity is available. |
| `on_demand_allocation_strategy` | `prioritized` | Uses the override order for the On-Demand instance types. |
| `spot_allocation_strategy` | `capacity-optimized-prioritized` | Prefers deep Spot capacity pools while honouring the override order as best effort. |

## The On-Demand floor

One instance is always On-Demand. Spot capacity can be reclaimed; that one
cannot, so one interruption cannot remove the service floor. At desired
capacity 3, the group is 1 On-Demand plus 2 Spot.

## Why `capacity-optimized-prioritized`, and what was rejected

`capacity-optimized-prioritized` honours the override order as best effort while
preferring the deepest capacity pools, which are the least likely to be
reclaimed. `price-capacity-optimized` was considered and rejected: it ignores
override order for Spot and would silently discard the instance type
prioritisation. It looks like the obvious cheaper choice, but it is the wrong
tradeoff for this demonstration.

## Four instance types, one architecture

The overrides are `t4g.micro`, `t4g.small`, `c6g.medium`, and `c6g.large`, in
that priority order. They are all arm64 Graviton types to match the AMI. More
types mean more distinct Spot capacity pools; fewer pools mean more exposure to
interruption.

## Multi-AZ, best effort

`balanced-best-effort` spreads capacity across three Availability Zones but does
not block a launch when one AZ has no Spot capacity. It is already the provider
default and is set explicitly so the placement intent is visible in the code.

## Capacity Rebalance

EC2 emits a rebalance recommendation when an instance is at elevated risk,
earlier than the two-minute interruption notice. With `capacity_rebalance =
true`, the ASG launches a replacement on that earlier signal. This is the
mechanism that makes Spot compatible with an availability claim.

## The burstable-credit angle

The 10% CPU target is the `t4g.micro` baseline: 12 credits/hour ÷ 2 vCPU ÷ 60
min. Targeting the baseline adds capacity before any instance draws down its
credit balance. Instances run in `unlimited` mode, where bursting is never
throttled. Under `standard`, a credit-depleted instance is throttled to baseline
and `CPUUtilization` would flatten at exactly the target, quietly lying to the
policy reading it.

`standard` is actively unsafe here: launch credits are a T2-only feature, so a
`standard`-mode t4g starts with zero credits and is throttled from boot. The
`c6g` types are fixed-performance instances with no baseline, so this
calibration is aimed at the burstable members of the fleet.

## The trap worth naming

Never set `instance_market_options` on the launch template. Spot purchasing
belongs to the ASG's mixed instances policy; setting it in both places conflicts.
It is a common mistake and the error message is not obvious.

## The cost argument

Spot is heavily discounted against On-Demand for the same capacity, the fleet
keeps an On-Demand floor for availability, and Graviton is cheaper again per
unit of work. Do not rely on invented percentages or dollar figures; check the
current [Spot Instance pricing page](https://aws.amazon.com/ec2/spot/pricing/).

## References

- [Mixed instance types and purchase options](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-mixed-instances-groups.html)
- [Allocation strategies](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-az-instance-type-distribution.html)
- [Capacity Rebalancing](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-capacity-rebalancing.html)
- [Burstable performance instances](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-performance-instances.html)
