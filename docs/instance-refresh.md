# Instance refresh

Instance refresh is a rolling replacement of every instance in the group. Use
it after a launch-template change, such as after building a new AMI.

## Why Terraform does not wire it automatically

A Terraform `instance_refresh` block auto-triggers whenever the launch template
changes. That removes the live control wanted here: a presenter should choose
when replacement starts. The block is deliberately absent, not forgotten.

## Ready-to-run command

Start a refresh with a rolling strategy, 100% minimum healthy capacity, and 200%
maximum healthy capacity:

```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name "$(terraform -chdir=terraform output -raw asg_name)" \
  --strategy Rolling \
  --preferences '{"MinHealthyPercentage":100,"MaxHealthyPercentage":200}'
```

Checkpoints are unset. The 100% minimum and 200% maximum are launch-before-
terminate: new instances come up and pass health checks before old instances go
away, so capacity never dips. That is what makes replacement invisible to users.

## Watch it

Use `aws autoscaling describe-instance-refreshes` to follow the refresh, plus
`make status` and `make targets` to watch instance and ALB health. This is not
part of the stage demo: the door is open if needed, but nothing fires
automatically.

## References

- [Instance refresh](https://docs.aws.amazon.com/autoscaling/ec2/userguide/asg-instance-refresh.html)
- [`StartInstanceRefresh`](https://docs.aws.amazon.com/autoscaling/ec2/APIReference/API_StartInstanceRefresh.html)
