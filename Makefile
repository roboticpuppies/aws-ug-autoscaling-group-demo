# Command surface for the AWS UG Auto Scaling / Spot demo.
#
# Targets are grouped by who may run them. Agents may run the "checks" group.
# Everything under "stack lifecycle" and "demo" touches real, billable AWS
# resources and is run by a human.
#
# Recipes are intentionally not silenced with @: on stage the audience should
# see the real AWS CLI command scroll past.

SHELL := /usr/bin/env bash
TF    := terraform -chdir=terraform

# Recursive (=, not :=) so terraform output only runs when a target needs it.
REGION       = $(shell $(TF) output -raw region 2>/dev/null || echo ap-southeast-1)
ASG_NAME     = $(shell $(TF) output -raw asg_name)
TG_ARN       = $(shell $(TF) output -raw target_group_arn)
FIS_TEMPLATE = $(shell $(TF) output -raw fis_experiment_template_id)
ALB_URL      = http://$(shell $(TF) output -raw alb_dns_name)

.DEFAULT_GOAL := help
.PHONY: help fmt validate ami init plan apply destroy clean-ami \
        url poll status activity targets stress unstress interrupt session

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

# --- Checks (safe for agents; no AWS credentials required) -------------------

fmt: ## Format Terraform files
	$(TF) fmt -recursive

validate: ## Validate Terraform and Packer
	$(TF) fmt -check -recursive
	$(TF) validate
	cd packer && packer init . && packer validate .

# --- Stack lifecycle (human only; creates billable resources) ---------------

ami: ## Build the AMI with Packer
	cd packer && packer init . && packer build .

init: ## terraform init
	$(TF) init

plan: ## terraform plan
	$(TF) plan

apply: ## terraform apply
	$(TF) apply

destroy: ## terraform destroy (prompts for confirmation)
	$(TF) destroy

clean-ami: ## Deregister demo AMIs and delete their snapshots (terraform does not own these)
	@for ami in $$(aws ec2 describe-images --region $(REGION) --owners self \
	    --filters 'Name=tag:Project,Values=Demo' \
	    --query 'Images[].ImageId' --output text); do \
	  snap=$$(aws ec2 describe-images --region $(REGION) --image-ids $$ami \
	    --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' --output text); \
	  echo "deregistering $$ami (snapshot $$snap)"; \
	  aws ec2 deregister-image --region $(REGION) --image-id $$ami; \
	  aws ec2 delete-snapshot --region $(REGION) --snapshot-id $$snap; \
	done

# --- Demo drivers -----------------------------------------------------------

url: ## Print the ALB URL
	@echo "$(ALB_URL)"

poll: ## curl the ALB every second, printing which instance served (Ctrl-C to stop)
	@echo "polling $(ALB_URL)/name.txt -- Ctrl-C to stop"
	@while true; do \
	  printf '%s  ' "$$(date -u +%H:%M:%S)"; \
	  curl -s --max-time 3 "$(ALB_URL)/name.txt" || echo "REQUEST FAILED"; \
	  sleep 1; \
	done

status: ## ASG instances: name, id, AZ, purchase option, type, state
	aws ec2 describe-instances \
	  --region $(REGION) \
	  --filters 'Name=tag:Project,Values=Demo' \
	            'Name=instance-state-name,Values=pending,running,shutting-down' \
	  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,Id:InstanceId,AZ:Placement.AvailabilityZone,Purchase:InstanceLifecycle,Type:InstanceType,State:State.Name}' \
	  --output table

activity: ## Recent ASG scaling activity and lifecycle hook results
	aws autoscaling describe-scaling-activities \
	  --region $(REGION) \
	  --auto-scaling-group-name $(ASG_NAME) \
	  --max-items 15 \
	  --query 'Activities[].[StartTime,StatusCode,Description]' \
	  --output table

targets: ## ALB target group health
	aws elbv2 describe-target-health \
	  --region $(REGION) \
	  --target-group-arn $(TG_ARN) \
	  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' \
	  --output table

stress: ## Drive CPU to 100% on every demo instance via SSM (triggers scale-out)
	aws ssm send-command \
	  --region $(REGION) \
	  --document-name AWS-RunShellScript \
	  --targets 'Key=tag:Project,Values=Demo' \
	  --comment 'AWS UG demo: CPU load' \
	  --parameters 'commands=["nohup stress-ng --cpu 0 --timeout 900s >/dev/null 2>&1 &"]' \
	  --query 'Command.CommandId' --output text

unstress: ## Stop the CPU load, so scale-in can be shown
	aws ssm send-command \
	  --region $(REGION) \
	  --document-name AWS-RunShellScript \
	  --targets 'Key=tag:Project,Values=Demo' \
	  --comment 'AWS UG demo: stop CPU load' \
	  --parameters 'commands=["pkill -f stress-ng || true"]' \
	  --query 'Command.CommandId' --output text

interrupt: ## Inject a real Spot interruption via AWS FIS
	aws fis start-experiment \
	  --region $(REGION) \
	  --experiment-template-id $(FIS_TEMPLATE) \
	  --query 'experiment.[id,state.status]' --output text

session: ## Shell on an instance via SSM. Usage: make session INSTANCE=i-0abc123
	@test -n "$(INSTANCE)" || { echo "usage: make session INSTANCE=i-0abc123"; exit 1; }
	aws ssm start-session --region $(REGION) --target $(INSTANCE)
