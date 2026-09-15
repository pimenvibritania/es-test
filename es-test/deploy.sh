#!/bin/bash
# One-shot, fully-automated deploy: Terraform (infra) -> auto-generated
# Ansible inventory -> Ansible (ES cluster config). No manual steps between
# stages -- run this single script start to finish.
#
# Prerequisites (one-time, idempotent, handled by setup-ansible-ssm.sh):
#   - Ansible + session-manager-plugin installed (~/vault/setup-ansible-ssm.sh)
#   - AWS credentials available in Vault at kv/aws-ft
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$REPO_ROOT/terraform"
ANSIBLE_DIR="$REPO_ROOT/ansible"
export PATH="$HOME/.local/bin:$PATH"

ALLOWED_CIDR="${1:-0.0.0.0/0}"

echo "== Fetching AWS credentials from local Vault (kv/aws-ft) =="
ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('$HOME/vault/init-output.json'))['root_token'])")
CREDS_JSON=$(docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN="$ROOT_TOKEN" hermes-vault \
  vault kv get -format=json kv/aws-ft)
export AWS_ACCESS_KEY_ID=$(echo "$CREDS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['data']['KEY'])")
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['data']['SECRET'])")
unset CREDS_JSON

echo "== 1/3: terraform apply (infra) =="
cd "$TF_DIR"
terraform init -input=false
terraform apply -auto-approve -input=false -var="allowed_cidr=${ALLOWED_CIDR}"

echo "== 2/3: generating Ansible inventory from terraform output =="
TF_OUT=$(terraform output -json)
python3 - "$TF_OUT" "$ANSIBLE_DIR/inventory.ini" <<'PYEOF'
import json, sys

tf = json.loads(sys.argv[1])
out_path = sys.argv[2]

instance_ids = tf["instance_ids"]["value"]
private_ips = tf["node_private_ips"]["value"]
secret_arn = tf["elastic_secret_arn"]["value"]
kb_secret_arn = tf["kibana_system_secret_arn"]["value"]
ca_arn = tf["ca_bundle_secret_arn"]["value"]
bucket = tf["ansible_transfer_bucket"]["value"]
region = "ap-southeast-3"

lines = ["[es_nodes]"]
for key in sorted(instance_ids.keys()):
    lines.append(
        f"es-node-{key} ansible_host={instance_ids[key]} private_ip={private_ips[key]}"
    )
lines += [
    "",
    "[es_nodes:vars]",
    "ansible_connection=community.aws.aws_ssm",
    f"ansible_aws_ssm_region={region}",
    f"ansible_aws_ssm_bucket_name={bucket}",
    "ansible_aws_ssm_timeout=180",
    "ansible_python_interpreter=/usr/bin/python3",
    f"es_aws_region={region}",
    f"es_secret_arn={secret_arn}",
    f"es_ca_bundle_arn={ca_arn}",
    f"kb_system_secret_arn={kb_secret_arn}",
    "",
]
with open(out_path, "w") as f:
    f.write("\n".join(lines))
print(f"Wrote inventory with {len(instance_ids)} node(s) to {out_path}")
PYEOF

echo "== 3/3: ansible-playbook (ES install/config) =="
cd "$ANSIBLE_DIR"
# Wait for SSM registration before handing off to Ansible (fresh instances
# take ~60-90s to register after the amazon-ssm-agent install in user_data).
echo "Waiting for all nodes to register with SSM..."
for id in $(echo "$TF_OUT" | python3 -c "import json,sys; d=json.load(sys.stdin)['instance_ids']['value']; print(' '.join(d.values()))"); do
  for i in $(seq 1 30); do
    STATUS=$(aws ssm describe-instance-information --region ap-southeast-3 \
      --filters "Key=InstanceIds,Values=$id" --query "InstanceInformationList[0].PingStatus" --output text 2>/dev/null || echo "None")
    if [ "$STATUS" = "Online" ]; then
      echo "  $id: Online"
      break
    fi
    sleep 10
  done
done
sleep 15  # SSM agent PingStatus can report Online a few seconds before
          # StartSession actually succeeds (race condition observed in testing)

for attempt in 1 2 3; do
  if ansible-playbook -i inventory.ini elasticsearch.yml; then
    break
  fi
  echo "Ansible run failed (attempt $attempt/3), retrying after SSM warm-up delay..."
  sleep 15
  if [ "$attempt" = "3" ]; then
    echo "Ansible playbook failed after 3 attempts" >&2
    exit 1
  fi
done

echo "DEPLOY_COMPLETE"
