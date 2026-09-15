#!/bin/bash
# One-shot deploy for alerting: CloudWatch alarms (Terraform, reads ES
# remote state for instance IDs + IAM role) + cron-based ES cluster health
# metric pusher (Ansible, reuses ../ansible inventory pattern).
#
# PREREQUISITE: ../../terraform (es-test ES cluster) must already be applied.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$REPO_ROOT/terraform"
ANSIBLE_DIR="$REPO_ROOT/ansible"
ES_TF_DIR="$REPO_ROOT/../terraform"
export PATH="$HOME/.local/bin:$PATH"

ALERT_EMAIL="${1:?Usage: deploy.sh <alert_email>}"

echo "== Fetching AWS credentials from local Vault (kv/aws-ft) =="
ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('$HOME/vault/init-output.json'))['root_token'])")
CREDS_JSON=$(docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN="$ROOT_TOKEN" hermes-vault \
  vault kv get -format=json kv/aws-ft)
export AWS_ACCESS_KEY_ID=$(echo "$CREDS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['data']['KEY'])")
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['data']['SECRET'])")
unset CREDS_JSON

echo "== 1/3: terraform apply (SNS topic + CloudWatch alarms + IAM policy) =="
cd "$TF_DIR"
terraform init -input=false
terraform apply -auto-approve -input=false -var="alert_email=${ALERT_EMAIL}"

echo "== 2/3: reusing ES ansible inventory (already has instance IDs + creds) =="
cp "$REPO_ROOT/../ansible/inventory.ini" "$ANSIBLE_DIR/inventory.ini"

echo "== 3/3: ansible-playbook (deploy cluster-health-to-CloudWatch cron on every ES node) =="
cd "$ANSIBLE_DIR"
for attempt in 1 2 3; do
  if ansible-playbook -i inventory.ini es-metrics-cron.yml; then
    break
  fi
  echo "Ansible run failed (attempt $attempt/3), retrying after SSM warm-up delay..."
  sleep 15
  if [ "$attempt" = "3" ]; then
    echo "Ansible playbook failed after 3 attempts" >&2
    exit 1
  fi
done

SNS_ARN=$(cd "$TF_DIR" && terraform output -raw sns_topic_arn)
echo "ALERTING_DEPLOY_COMPLETE sns_topic_arn=$SNS_ARN"
echo ""
echo "IMPORTANT: AWS just emailed a Subscription Confirmation link to $ALERT_EMAIL"
echo "No alarm will actually deliver until that link is clicked -- check your inbox (and spam folder)."
