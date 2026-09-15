#!/bin/bash
# Bootstrap script for one node of a 3-node ElasticSearch cluster.
# Rendered via Terraform templatefile(): ${node_name}, ${secret_arn}, ${ca_bundle_arn},
# ${aws_region}, ${cluster_name}, ${all_node_names} are interpolated.
set -euxo pipefail

AWS_REGION="${aws_region}"
NODE_NAME="${node_name}"
CLUSTER_NAME="${cluster_name}"
SECRET_ARN="${secret_arn}"
CA_BUNDLE_ARN="${ca_bundle_arn}"

# --- Install ElasticSearch ---------------------------------------------------
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

yum install -y elasticsearch jq

# --- Fetch shared CA (same across all nodes) + generate this node's cert ---
mkdir -p /etc/elasticsearch/certs
CA_JSON=$(aws secretsmanager get-secret-value --secret-id "$CA_BUNDLE_ARN" \
  --region "$AWS_REGION" --query SecretString --output text)
echo "$CA_JSON" | jq -r .ca_cert > /tmp/ca.crt
echo "$CA_JSON" | jq -r .ca_key  > /tmp/ca.key

# Convert PEM CA into a p12 keystore usable by elasticsearch-certutil,
# then issue a node cert (used for BOTH http and transport layers here).
openssl pkcs12 -export -in /tmp/ca.crt -inkey /tmp/ca.key \
  -name ca -out /etc/elasticsearch/certs/ca.p12 -passout pass:

/usr/share/elasticsearch/bin/elasticsearch-certutil cert \
  --ca /etc/elasticsearch/certs/ca.p12 --ca-pass "" \
  --name "$NODE_NAME" \
  --out /etc/elasticsearch/certs/node.p12 --pass "" --silent

chown -R elasticsearch:elasticsearch /etc/elasticsearch/certs
chmod 660 /etc/elasticsearch/certs/*.p12
shred -u /tmp/ca.crt /tmp/ca.key

# --- Fetch elastic user password --------------------------------------------
ELASTIC_PASSWORD=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" \
  --region "$AWS_REGION" --query SecretString --output text)

# --- Discover other node private IPs via EC2 tags (same cluster) -----------
LOCAL_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

# --- Configure elasticsearch.yml ---------------------------------------------
cat >>/etc/elasticsearch/elasticsearch.yml <<YML

# --- Cluster identity ---
cluster.name: ${cluster_name}
node.name: ${node_name}
node.roles: [ master, data ]
network.host: 0.0.0.0
network.publish_host: $LOCAL_IP

# --- Discovery: EC2 tag-based via seed hosts resolved by Terraform/ASG in prod;
#     for this exercise we rely on all 3 instances being tagged with the same
#     cluster name and discovered via DNS/seed_hosts populated post-boot
#     (see discovery-seed-hosts.sh companion script run by a small systemd unit,
#     OR replace with the ec2 discovery plugin for production use).
discovery.seed_providers: file
cluster.initial_master_nodes: [ ${all_node_names} ]

# --- Security: auth + TLS on BOTH http and transport layers ---
xpack.security.enabled: true
xpack.security.http.ssl.enabled: true
xpack.security.http.ssl.keystore.path: certs/node.p12
xpack.security.transport.ssl.enabled: true
xpack.security.transport.ssl.verification_mode: certificate
xpack.security.transport.ssl.keystore.path: certs/node.p12
xpack.security.transport.ssl.truststore.path: certs/node.p12
YML

# NOTE: discovery.seed_providers: file requires unicast_hosts.txt populated
# with peer private IPs. In production, prefer the EC2 discovery plugin
# (discovery-ec2) with IAM DescribeInstances permission + tag-based filtering
# instead of static file, to survive node IP changes on replacement.
mkdir -p /etc/elasticsearch/discovery-file
echo "# populate with peer private IPs, one per line" > /etc/elasticsearch/discovery-file/unicast_hosts.txt

systemctl daemon-reload
systemctl enable elasticsearch
systemctl start elasticsearch

until curl -sk -o /dev/null https://localhost:9200; do sleep 5; done

/usr/share/elasticsearch/bin/elasticsearch-reset-password \
  -u elastic -b -a --url https://localhost:9200 <<EOF || true
$ELASTIC_PASSWORD
$ELASTIC_PASSWORD
EOF

echo "Node ${node_name} bootstrap complete."
