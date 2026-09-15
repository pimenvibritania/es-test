#!/bin/bash
# Bootstrap script for single-node ElasticSearch, free-tier config.
# Rendered via Terraform templatefile() -- ${ssm_param_name} and ${aws_region} are interpolated.
set -euxo pipefail

AWS_REGION="${aws_region}"
SSM_PARAM_NAME="${ssm_param_name}"

# --- Install ElasticSearch (Amazon Linux 2023) ------------------------------
cat >/etc/yum.repos.d/elasticsearch.repo <<'REPO'
[elasticsearch]
name=Elasticsearch repository
baseurl=https://artifacts.elastic.co/packages/8.x/yum
gpgcheck=1
gpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch
enabled=1
autorefresh=1
type=rpm-md
REPO

yum install -y elasticsearch

# --- Fetch the pre-generated password from SSM Parameter Store -------------
ELASTIC_PASSWORD=$(aws ssm get-parameter \
  --name "$SSM_PARAM_NAME" \
  --with-decryption \
  --region "$AWS_REGION" \
  --query Parameter.Value \
  --output text)

# --- Generate self-signed CA + node cert for HTTP layer TLS -----------------
# (single-node: only HTTP layer needs TLS, no transport-layer inter-node traffic)
/usr/share/elasticsearch/bin/elasticsearch-certutil ca \
  --out /etc/elasticsearch/certs/ca.p12 --pass "" --silent

/usr/share/elasticsearch/bin/elasticsearch-certutil cert \
  --ca /etc/elasticsearch/certs/ca.p12 --ca-pass "" \
  --out /etc/elasticsearch/certs/http.p12 --pass "" --silent

chown -R elasticsearch:elasticsearch /etc/elasticsearch/certs
chmod 660 /etc/elasticsearch/certs/*.p12

# --- Configure elasticsearch.yml --------------------------------------------
cat >>/etc/elasticsearch/elasticsearch.yml <<'YML'

# --- Security & TLS (free-tier single-node config) ---
xpack.security.enabled: true
xpack.security.http.ssl.enabled: true
xpack.security.http.ssl.keystore.path: certs/http.p12
network.host: 0.0.0.0
discovery.type: single-node
YML

systemctl daemon-reload
systemctl enable elasticsearch
systemctl start elasticsearch

# --- Set the built-in `elastic` user password to match SSM value -----------
# Wait for ES to be up before resetting password.
until curl -sk -o /dev/null https://localhost:9200; do sleep 5; done

/usr/share/elasticsearch/bin/elasticsearch-reset-password \
  -u elastic -b -a --url https://localhost:9200 <<EOF || true
$ELASTIC_PASSWORD
$ELASTIC_PASSWORD
EOF

echo "ElasticSearch bootstrap complete. Verify with:"
echo "curl -k -u elastic:<password-from-ssm> https://localhost:9200/_cluster/health?pretty"
