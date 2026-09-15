# VPN Access Layer — Pritunl (free-tier variant)

Status: **NOT YET applied/tested**. Adds a Pritunl VPN server (free, open-source, OpenVPN-based) in front of the free-tier single-node ElasticSearch stack in `../../terraform`.

## Prerequisite
`../../terraform` (the free-tier ES stack) must already be `terraform apply`'d, because this module reads its `vpc_id`, `public_subnet_id`, and `es_security_group_id` directly from its local `terraform.tfstate` via `terraform_remote_state` — no manual copy/paste needed.

## What it does
- Deploys 1 EC2 instance running Pritunl + MongoDB in the same public subnet as the ES node.
- Adds a security group rule so the ES node's SG trusts port 9200 traffic **only from the Pritunl VPN server's SG**.
- After this is applied, you can tighten the ES stack's own `allowed_cidr` down (e.g. to `127.0.0.1/32`) since access is meant to go through the VPN instead.

## Usage
```bash
cd terraform
terraform init
terraform plan  -var="admin_cidr=$(curl -s https://checkip.amazonaws.com)/32"
terraform apply -var="admin_cidr=$(curl -s https://checkip.amazonaws.com)/32"

cd ../ansible
# fill in inventory.ini with the terraform output (instance_id, public_ip)
ansible-playbook -i inventory.ini pritunl.yml
```

## First-time admin setup (manual, one time — see ../../../vpn design note)
```bash
aws ssm start-session --target <instance-id>
sudo pritunl default-password
```
Browse to `https://<public-ip>/`, log in, change password, create Organization + User, download `.ovpn` profile.

## Connect with the free Pritunl Client
Download from https://client.pritunl.com, import the `.ovpn` profile, connect. Once connected you're on the VPC private network and can reach the ES node's private IP on 9200.

## Cost
- EC2 t3.micro running Pritunl: free if it's your only 24/7 instance under the free-tier hour pool; if you're already running the ES node 24/7 too, this 2nd instance is **not free** (~$7-8/month, t3.micro on-demand). See root `INSTRUCTIONS.md` cost table.
- Elastic IP: free while attached to a running instance.
