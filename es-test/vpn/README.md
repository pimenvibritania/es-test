# VPN Access Layer — Pritunl (es-test variant)

Status: **Deployed and verified**. Adds a Pritunl VPN server (free, open-source, OpenVPN-based) in front of the es-test 3-node ElasticSearch cluster in `../../terraform`.

## Prerequisite
`../../terraform` (the es-test 3-node ES cluster) must already be `terraform apply`'d, because this module reads its `vpc_id`, `public_subnet_id`, and `es_security_group_id` directly from its local `terraform.tfstate` via `terraform_remote_state`. All 3 ES nodes share one security group, so a single rule here covers all of them.

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

# fully automated app-level bootstrap: fixes the mongodb_uri bug left by the
# base install, resets the admin password, enables the REST API, then
# creates the Organization/Server/User and downloads the client .ovpn
# profile via the Pritunl API -- no browser needed. Requires a reachable
# Vault (VAULT_ADDR/VAULT_TOKEN) to store the resulting credentials.
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=<vault token with write on kv/pritunl>
python3 -m pip install --break-system-packages requests  # one-time, control node only
ansible-playbook -i inventory.ini pritunl-provision.yml
```

## Fully automated bootstrap (server, organization, user, client profile)
`pritunl-provision.yml` provisions everything end-to-end via the Pritunl REST
API and Ansible's SSM connection plugin -- **no manual UI step, no SSH**:
1. Fixes an empty `mongodb_uri` in `/etc/pritunl.conf` left by the base
   install (confirmed bug: service reports "running" but the DB connection
   string is blank until this runs).
2. Resets the admin (`pritunl`) password to a fresh random value.
3. Enables REST API auth for the admin account (only reachable via a direct
   MongoDB update -- there's no CLI subcommand for it).
4. Creates the Organization, Server (UDP/1194 by default, matching the SG
   rule opened by `../terraform`), and a client User -- all idempotent, safe
   to re-run.
5. Starts the server and downloads the client `.ovpn` profile via the
   Pritunl API (using an undocumented-but-working route,
   `/data/<org_id>/<user_id>/<server_id>.key`, found by grepping the
   installed Pritunl source for its Flask routes).
6. Stores admin password, API token/secret, org/server/user IDs, and the
   base64-encoded `.ovpn` profile in Vault at `kv/pritunl`.

Retrieve the client profile after a run:
```bash
vault kv get -field=ovpn_profile_b64 kv/pritunl | base64 -d > client.ovpn
```

## Connect with the free Pritunl Client
Download from https://client.pritunl.com, import the `.ovpn` profile, connect. Once connected you're on the VPC private network and can reach any of the 3 ES node private IPs on 9200.

## Cost
- EC2 t3.micro running Pritunl: this is on top of the es-test cluster's existing costs (3 nodes + NAT Gateway etc, see root `INSTRUCTIONS.md`), so it is **not free** in this configuration (~$7-8/month, t3.micro on-demand).
- Elastic IP: free while attached to a running instance.
