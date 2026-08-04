# The Packer AMI

The AMI bakes in Docker Engine, AWS CLI v2, `stress-ng`, and a pre-pulled
`nginx:alpine` image. Baking them avoids package installation at boot. The
pre-pulled image makes user-data's `docker pull` a cache hit, so scale-out is
fast in front of an audience and does not depend on venue network speed.

## Base image

The source is Amazon Linux 2023 arm64, selected by `source_ami_filter` with
`most_recent = true`. The build uses a `t4g.micro`, matching the architecture
and the burstable instance family used by the fleet.

`source_ami_filter` is used instead of an SSM-parameter data source because
Packer evaluates HCL data sources during `packer validate`. A data source would
make validation require AWS credentials. The source filter resolves at build
time, keeping `make validate` credential-free.

## Build it

Run `make ami`; it takes roughly five minutes. This must happen before `make
plan` or `make apply`, because `data.aws_ami.demo` has nothing to find until an
AMI exists.

Terraform selects the newest AMI owned by the account whose name starts with
the `name_prefix` and which carries `Project=Demo`. Changing the Packer
`ami_name` prefix or dropping the `Project=Demo` tag breaks that lookup.

## What the build proves

The provisioner asserts `docker --version`, `stress-ng --version`, and
`aws --version`. It hard-fails unless the AWS CLI reports `aws-cli/2`, and it
confirms that `nginx:alpine` is in the local Docker image cache. A successful
build has therefore already proved that these ingredients landed in the AMI.

The one uncertainty is the `awscli-2` dnf package name. The script tolerates
that install failing and asserts `aws-cli/2` instead, so a wrong package name
produces a loud failure rather than a subtly broken AMI.

## Cleanup

Run `make clean-ami` after `make destroy`. Terraform does not own the AMI or
its snapshot, so `make destroy` leaves them behind and they keep costing money.

## References

- [Packer Amazon EBS builder](https://developer.hashicorp.com/packer/integrations/hashicorp/amazon/latest/components/builder/ebs)
- [AL2023 packages formerly in EPEL](https://docs.aws.amazon.com/linux/al2023/ug/epel.html)
