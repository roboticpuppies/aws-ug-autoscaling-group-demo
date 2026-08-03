# Working in this repository

Demo infrastructure for an AWS User Group talk on EC2 Auto Scaling and Spot
Instances. Terraform builds the stack, Packer builds the AMI, and a Makefile is
the command surface.

## Read this first

- `docs/superpowers/specs/2026-08-04-asg-spot-demo-design.md` is the approved
  design and the source of truth.
- `docs/superpowers/plans/2026-08-04-asg-spot-demo.md` is the implementation
  plan. Work through it task by task, in order.

Values in the spec — capacities, timeouts, scaling targets, allocation
strategies — were each chosen for a documented reason. Do not change one to make
something pass. If a value looks wrong, say so instead of editing it.

## Commands you must never run

These create real, billable AWS resources under the repository owner's
credentials. The owner runs them personally.

- `terraform apply`
- `terraform destroy`
- `terraform plan` (reaches AWS)
- `packer build`
- any `aws` CLI call that creates, modifies or deletes anything
- `make ami`, `make apply`, `make destroy`, `make plan`, `make clean-ami`, and
  any `make` target under "demo drivers" — all of them wrap the above

If a task appears to require one, stop and report rather than running it.

## Commands you should run

- `make fmt` — format Terraform
- `make validate` — Terraform and Packer validation, no credentials needed
- `terraform -chdir=terraform init -backend=false` — downloads providers, makes
  no AWS API calls
- `bash -n <file>` and `shellcheck <file>` — for shell scripts

## How work is verified here

There are no unit tests and no test framework, by design. This is declarative
infrastructure; behavioural verification requires `terraform apply`, which is
human-gated. Each plan task therefore ends in static checks: `terraform
validate`, `terraform fmt -check`, `packer validate`, `bash -n`, `shellcheck`,
and exact `grep` assertions. Run every check a task lists, and do not move to
the next task while one is failing.

Commit after each task, using the commit message the task specifies.

## Conventions

- **Region is `ap-southeast-1`.** Never `ap-southeast-3`: AWS FIS does not exist
  there, and the Spot-interruption demo is half the point of this repo.
- **Every taggable resource carries `Project = "Demo"`.** It is not decoration.
  FIS target selection, the SSM Run Command filter, and an IAM condition on
  `ec2:CreateTags` all depend on it. Take it from `local.tags`.
- **No provider `default_tags`.** Tag explicitly, so Auto Scaling group tag
  propagation stays predictable.
- **All names derive from `var.name_prefix`** (default `asg-demo`).
- **No secrets, ever** — no private keys, no webhook URLs, no credentials, in
  any file. Instance access is via SSM Session Manager.

## Two file-format traps

1. In `terraform/templates/user-data.sh.tftpl`, write shell variables as `$VAR`,
   **never** with braces. Terraform's `templatefile()` consumes dollar-brace
   sequences as its own interpolation — including ones inside comments and
   heredocs, which is a genuinely surprising failure. Keeping braces out also
   leaves the file valid Bash, so `bash -n` and `shellcheck` work on it directly.
2. In the `Makefile`, indent recipes with a literal TAB, and write a literal
   shell `$` as `$$`. Recipes are deliberately **not** silenced with `@`: on
   stage the audience should see the real AWS CLI command scroll past.

## Style

Terraform: `terraform fmt` canonical form, one resource per logical block,
comments only where a choice is non-obvious. Shell: `set -euo pipefail`,
`shellcheck`-clean.
