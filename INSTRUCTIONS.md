# Infrastructure Engineer Take-Home — Secure ElasticSearch on AWS (Free Tier)

> DRAFT — brainstorm output, not yet implemented/tested at the time this was written. All cost figures are ASSUMPTIONS based on public AWS us-east-1 pricing, and may vary by region/time — check the AWS Pricing Calculator before submitting.

## 1. Solution Summary

Deploy 1x EC2 instance (t2.micro/t3.micro, free tier) running single-node ElasticSearch with:
- Mandatory authentication (X-Pack Security)
- Encrypted communication (TLS on the HTTP layer, port 9200)
- Admin access via AWS SSM Session Manager (no port 22 open)
- Least-privilege Security Group (9200 only from a specific IP, not 0.0.0.0/0)

Provisioning: Terraform (infra) + user-data/Ansible (ES config).
Designed to be **extensible to a 3-node cluster** — see Section 4.

## 2. Why these choices (take-home question answers)

### Q1: Provisioning & bootstrapping tool — why?
- **Terraform** for infra (VPC, SG, EC2, IAM role, EBS) — declarative, state-tracked, easy to cleanly destroy/recreate (important for an exercise that will be cleaned up after the demo).
- **User-data script / Ansible** for installing & configuring ES — idempotent, easy for a reviewer to read, and Ansible is more natural for "config management" than putting everything into a Terraform provisioner.

### Q2: How to secure ElasticSearch — why?
- `xpack.security.enabled: true` — built into ES, no need for an extra proxy (e.g. nginx basic-auth) that would only add attack surface & maintenance burden.
- Self-signed TLS via `elasticsearch-certutil` for the HTTP layer — sufficient for internal/demo use; production should use certs from a trusted CA/ACM Private CA (noted here, not implemented — an ASSUMPTION outside the scope of this free-tier exercise).
- The built-in user's (`elastic`) password is stored in **SSM Parameter Store SecureString** (AWS-managed KMS key), fetched by the instance via IAM role at bootstrap — not hardcoded in scripts/repo (risk area: **secrets management**).
- Security Group restricts port 9200 access to only the tester's IP (my-IP), not public (risk area: **access control**).

### Q3: Monitoring — which metrics?
See Section 3.

### Q4: Extending to a secure 3-node cluster — what changes?
See Section 4.

### Q5: Replacing a running node with zero/minimal downtime
1. `PUT _cluster/settings {"transient":{"cluster.routing.allocation.enable":"none"}}` — freeze shard allocation.
2. Stop ES on the target node, perform replace/patch/upgrade.
3. Start ES again, node rejoins the cluster.
4. `PUT _cluster/settings {"transient":{"cluster.routing.allocation.enable":"all"}}`.
5. Wait for `_cluster/health` to return to **green** before moving to the next node (rolling, one at a time, not in parallel).

### Q6: Clean/extensible/reusable code structure — priority?
Yes — Terraform is split into modules (network, compute, security) and uses variables/count so scaling from 1→3 nodes only requires changing `node_count`, not copy-pasting scripts.

### Q7: Trade-offs due to resource constraints (not time, but free-tier cost limits)
- Implemented as a **1-node** cluster for the real demo (to keep cost at $0), with the 3-node setup documented as an extension path — since 3x EC2 running 24/7 plus a NAT Gateway falls outside the free tier (see cost table).
- Used a **public subnet + strict SG** instead of a private subnet + NAT Gateway, since the NAT Gateway (~$32/month) is the largest avoidable cost without sacrificing core security (TLS+auth still mandatory, SG still restricted to my-IP).
- Used the AWS-managed KMS key (free) instead of a customer-managed CMK ($1/month), since granular per-key audit requirements aren't proportional to the needs of this exercise.

## 3. Monitoring

| Layer | Metric | Alert threshold | Tool |
|---|---|---|---|
| Cluster | health status | != green | Metricbeat / `_cluster/health` |
| Cluster | unassigned shards | > 0 sustained | Metricbeat |
| Node | JVM heap usage | > 85% | Metricbeat / CloudWatch custom metric |
| Node | GC pause time | sustained > 1s | Metricbeat |
| Node | disk usage | > 85% (watermark) | CloudWatch Agent |
| Node | CPU / memory (host) | > 80% sustained | CloudWatch (basic, free) |
| Node | open file descriptors | near ulimit | Metricbeat |
| Query | search/index latency | baseline + 2x | Metricbeat / slow log |

- Dashboard: Kibana (bundled, no extra infra) as the default; CloudWatch dashboard for OS-level metrics (free basic monitoring).
- Alerting: CloudWatch Alarm → SNS for the thresholds above (limited to the most critical metrics: heap%, disk%, cluster status — to stay within the 10 free custom metrics).
- Monitoring credentials use a restricted `remote_monitoring_collector` role, not the `elastic` superuser.

## 4. Extending to a secure 3-node cluster

- `discovery.seed_hosts` = the 3 nodes' private IPs; all nodes are master-eligible + data nodes (automatic quorum requires 2/3 votes, tolerates 1 node down).
- Spread nodes across ≥2 different AZs for AZ-level fault tolerance.
- **Transport layer (9300) must use TLS + mutual auth** between nodes — using node certs from the same CA (not just the HTTP layer like the single-node setup).
- Security Group: 9300 inbound only from the ES SG itself (self-referencing), never public.
- Terraform: change `aws_instance` to `count = 3` / `for_each` per subnet, each instance fetching a unique cert from the CA stored in Secrets Manager/Parameter Store.

## 5. Cost Breakdown (Free Tier Reality Check)

| Component | Ideal best practice | Est. cost/month | Decision made |
|---|---|---|---|
| EC2 (3 nodes) | Private subnet, 3-node HA | ~$15 (2 nodes paid) | **1 node** for the demo, extension documented |
| NAT Gateway | Private subnet internet access | ~$32 | **Public subnet + strict SG** (no NAT) |
| Secrets Manager | Automatic rotation | ~$0.5 | **SSM Parameter Store SecureString** (free) |
| KMS CMK | Custom key, granular audit | ~$1 | **AWS-managed key** (free) |
| CloudWatch custom metrics | Full observability across all metrics | could exceed free tier | Limited to 3-5 critical metrics (within the free 10) |
| EBS | gp3 per node | free ≤30GB total | Small volumes (10-15GB/node) |

**Total estimated cost of the actual implementation (1-node, all cost-saving options): $0/month** within the first 12-month free-tier window.

## 6. Resources consulted
- AWS Free Tier documentation — https://aws.amazon.com/free
- Elastic Security documentation (X-Pack Security, TLS setup) — https://www.elastic.co/guide/en/elasticsearch/reference/current/secure-cluster.html
- AWS Systems Manager Session Manager docs — https://docs.aws.amazon.com/systems-manager/

(ASSUMPTION: the links above are generic placeholders — replace with the specific sources actually consulted during the work.)

## 7. Time spent & feedback
(Fill in after execution — the candidate is asked to report actual time spent and honest feedback on the exercise.)
