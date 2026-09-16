#!/bin/bash
# One-shot, fully-automated deploy for the monitoring stack (Kibana):
# terraform apply (infra, reads ES + VPN remote state) -> auto-generated
# Ansible inventory -> ansible-playbook (Kibana install/config).
#
# PREREQUISITES (must already be applied):
#   1. ../../terraform    (es-test ES cluster)
#   2. ../../vpn/terraform (Pritunl VPN)
# Both are read via terraform_remote_state from local state files.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$REPO_ROOT/terraform"
ANSIBLE_DIR="$REPO_ROOT/ansible"
ES_TF_DIR="$REPO_ROOT/../terraform"
export PATH="$HOME/.local/bin:$PATH"

echo "== Fetching AWS credentials from local Vault (kv/aws-ft) =="
ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('$HOME/vault/init-output.json'))['root_token'])")
CREDS_JSON=$(docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN="$ROOT_TOKEN" hermes-vault \
  vault kv get -format=json kv/aws-ft)
export AWS_ACCESS_KEY_ID=$(echo "$CREDS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['data']['KEY'])")
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['data']['SECRET'])")
unset CREDS_JSON

echo "== 1/3: terraform apply (Kibana infra) =="
cd "$TF_DIR"
terraform init -input=false
terraform apply -auto-approve -input=false

echo "== 2/3: generating Ansible inventory from terraform output =="
KB_OUT=$(terraform output -json)
ES_OUT=$(cd "$ES_TF_DIR" && terraform output -json)
python3 - "$KB_OUT" "$ES_OUT" "$ANSIBLE_DIR/inventory.ini" <<'PYEOF'
import json, sys

kb = json.loads(sys.argv[1])
es = json.loads(sys.argv[2])
out_path = sys.argv[3]

instance_id = kb["instance_id"]["value"]
private_ip = kb["private_ip"]["value"]
es_ips = ",".join(es["node_private_ips"]["value"].values())
kibana_system_secret_arn = es["kibana_system_secret_arn"]["value"]
elastic_secret_arn = es["elastic_secret_arn"]["value"]
ca_arn = es["ca_bundle_secret_arn"]["value"]
region = "ap-southeast-3"
bucket = es["ansible_transfer_bucket"]["value"]

lines = [
    "[kibana]",
    f"kibana-es-test ansible_host={instance_id} private_ip={private_ip}",
    "",
    "[kibana:vars]",
    "ansible_connection=community.aws.aws_ssm",
    f"ansible_aws_ssm_region={region}",
    f"ansible_aws_ssm_bucket_name={bucket}",
    "ansible_aws_ssm_timeout=180",
    "ansible_python_interpreter=/usr/bin/python3",
    f"kb_aws_region={region}",
    f"kb_kibana_system_secret_arn={kibana_system_secret_arn}",
    f"kb_elastic_secret_arn={elastic_secret_arn}",  # elastic superuser -- needed by kibana-dashboards.yml to call Kibana's own API
    f"kb_ca_bundle_arn={ca_arn}",
    f"kb_es_node_ips={es_ips}",
    "",
]
with open(out_path, "w") as f:
    f.write("\n".join(lines))
print(f"Wrote Kibana inventory to {out_path}")
PYEOF

echo "== 3/4: ansible-playbook (Kibana install/config) =="
cd "$ANSIBLE_DIR"
INSTANCE_ID=$(echo "$KB_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['instance_id']['value'])")
echo "Waiting for Kibana instance to register with SSM..."
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

# Retry the playbook run a couple of times in case the very first SSM
# session attempt still hits TargetNotConnected right after the ping-status
# race window above.
for attempt in 1 2 3; do
  if ansible-playbook -i inventory.ini kibana.yml; then
    break
  fi
  echo "Ansible run failed (attempt $attempt/3), retrying after SSM warm-up delay..."
  sleep 15
  if [ "$attempt" = "3" ]; then
    echo "Ansible playbook failed after 3 attempts" >&2
    exit 1
  fi
done

echo "== 4/4: provisioning Kibana dashboard + visualizations =="
# NOTE: run ../../alerting/deploy.sh (or ansible-playbook es-metrics-cron.yml)
# at least once BEFORE this step so es-test-metrics-* already has data --
# otherwise the dashboard imports fine but shows empty panels until the next
# cron tick on the ES nodes.
for attempt in 1 2 3; do
  if ansible-playbook -i inventory.ini kibana-dashboards.yml; then
    break
  fi
  echo "Ansible run failed (attempt $attempt/3), retrying after SSM warm-up delay..."
  sleep 15
  if [ "$attempt" = "3" ]; then
    echo "Ansible playbook failed after 3 attempts" >&2
    exit 1
  fi
done

echo "MONITORING_DEPLOY_COMPLETE"
