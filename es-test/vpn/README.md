# VPN Access Layer — Pritunl (paid-tier variant)

Status: **NOT YET applied/tested**. Adds a Pritunl VPN server (free, open-source, OpenVPN-based) in front of the paid-tier 3-node ElasticSearch cluster in `../../terraform`.

## Prerequisite
`../../terraform` (the paid-tier 3-node ES cluster) must already be `terraform apply`'d, because this module reads its `vpc_id`, `public_subnet_id`, and `es_security_group_id` directly from its local `terraform.tfstate` via `terraform_remote_state`. All 3 ES nodes share one security group, so a single rule here covers all of them.

## What it does
- Deploys 1 EC2 instance running Pritunl + MongoDB in the cluster's public subnet.
- Adds a security group rule so the ES cluster's shared SG trusts port 9200 traffic **only from the Pritunl VPN server's SG**.
- Combined with the cluster's existing private-subnet placement, this means the ES nodes are reachable *only* via VPN (or SSM) — never directly from the internet, on either HTTP (9200) or transport (9300) layers.

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

## First-time admin setup (manual, one time)
```bash
aws ssm start-session --target <instance-id>
sudo pritunl default-password
```
Browse to `https://<public-ip>/`, log in, change password, create Organization + User, download `.ovpn` profile.

## Connect with the free Pritunl Client
Download from https://client.pritunl.com, import the `.ovpn` profile, connect. Once connected you're on the VPC private network and can reach any of the 3 ES node private IPs on 9200.

## Cost
- EC2 t3.micro running Pritunl: this is on top of the paid-tier cluster's existing costs (3 nodes + NAT Gateway etc, see root `INSTRUCTIONS.md`), so it is **not free** in this configuration (~$7-8/month, t3.micro on-demand).
- Elastic IP: free while attached to a running instance.
