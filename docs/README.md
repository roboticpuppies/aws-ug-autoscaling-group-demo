# Documentation index

This directory contains the stage runbook and the focused design notes behind
the AWS UG Auto Scaling and Spot demo.

| Document | Description |
| --- | --- |
| [`runbook.md`](runbook.md) | Stage timeline, beats, and troubleshooting. |
| [`spot-strategy.md`](spot-strategy.md) | Mixed instances and cost/availability tradeoffs. |
| [`lifecycle-hooks.md`](lifecycle-hooks.md) | Launch and terminate hook behavior. |
| [`fis.md`](fis.md) | The real Spot interruption experiment. |
| [`packer.md`](packer.md) | AMI contents, build, lookup, and cleanup. |
| [`instance-refresh.md`](instance-refresh.md) | Optional controlled rolling replacement. |

See [`../README.md`](../README.md) for the overview and `superpowers/specs/`
for the full design, including rejected alternatives.
