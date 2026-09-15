#!/bin/bash
# One-shot, fully-automated deploy for the Pritunl VPN layer:
# terraform apply (infra, reads ES remote state) -> auto-generated Ansible
# inventory -> ansible-playbook (Pritunl install/config).
#
# PREREQUISITE: ../../terraform (es-test ES cluster) must already be applied.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$REPO_ROOT/terraform"
ANSIBLE_DIR="$REPO_ROOT/ansible"
ES_TF_DIR="$REPO_ROOT/../terraform"
export PATH="$HOME/.local/bin:$PATH"

ADMIN_CIDR="${1:?Usage: deploy.sh <admin_cidr, e.g. 1.2.3.4/32>}"

echo "== Fetching AWS credentials from local Vault (kv/aws-ft) =="
ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('$HOME/vault/init-output.json'))['root_token'])")
CREDS_JSON=$(docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN="$ROOT_TOKEN" hermes-vault \
  vault kv get -format=json kv/aws-ft)
export AWS_ACCESS_KEY_ID=$(echo "$CREDS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['data']['KEY'])")
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['data']['SECRET'])")
unset CREDS_JSON

echo "== 1/3: terraform apply (Pritunl infra) =="
cd "$TF_DIR"
terraform init -input=false
terraform apply -auto-approve -input=false -var="admin_cidr=${ADMIN_CIDR}"

echo "== 2/3: generating Ansible inventory from terraform output =="
VPN_OUT=$(terraform output -json)
ES_BUCKET=$(cd "$ES_TF_DIR" && terraform output -raw ansible_transfer_bucket)
python3 - "$VPN_OUT" "$ES_BUCKET" "$ANSIBLE_DIR/inventory.ini" <<'PYEOF'
import json, sys

vpn = json.loads(sys.argv[1])
bucket = sys.argv[2]
out_path = sys.argv[3]

instance_id = vpn["instance_id"]["value"]
public_ip = vpn["public_ip"]["value"]
region = "ap-southeast-3"

lines = [
    "[vpn]",
    f"pritunl-vpn ansible_host={instance_id} public_ip={public_ip}",
    "",
    "[vpn:vars]",
    "ansible_connection=community.aws.aws_ssm",
    f"ansible_aws_ssm_region={region}",
    f"ansible_aws_ssm_bucket_name={bucket}",
    "ansible_aws_ssm_timeout=180",
    "ansible_python_interpreter=/usr/bin/python3",
    "",
]
with open(out_path, "w") as f:
    f.write("\n".join(lines))
print(f"Wrote VPN inventory to {out_path}")
PYEOF

echo "== 3/3: ansible-playbook (Pritunl install/config) =="
cd "$ANSIBLE_DIR"
INSTANCE_ID=$(echo "$VPN_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['instance_id']['value'])")
echo "Waiting for VPN instance to register with SSM..."
for i in $(seq 1 30); do
  STATUS=$(aws ssm describe-instance-information --region ap-southeast-3 \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" --query "InstanceInformationList[0].PingStatus" --output text 2>/dev/null || echo "None")
  if [ "$STATUS" = "Online" ]; then
    echo "  $INSTANCE_ID: Online"
    sleep 15  # SSM agent PingStatus can report Online a few seconds before
              # StartSession actually succeeds (race condition observed in testing)
    break
  fi
  sleep 10
done

for attempt in 1 2 3; do
  if ansible-playbook -i inventory.ini pritunl.yml; then
    break
  fi
  echo "Ansible run failed (attempt $attempt/3), retrying after SSM warm-up delay..."
  sleep 15
  if [ "$attempt" = "3" ]; then
    echo "Ansible playbook failed after 3 attempts" >&2
    exit 1
  fi
done

PUBLIC_IP=$(echo "$VPN_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['public_ip']['value'])")
echo "VPN_DEPLOY_COMPLETE public_ip=$PUBLIC_IP"
echo "Next: aws ssm start-session --target $INSTANCE_ID --region ap-southeast-3"
echo "      then run: sudo pritunl default-password"
echo "Browse to https://$PUBLIC_IP/ to finish setup."
