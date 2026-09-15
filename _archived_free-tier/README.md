# Free Tier — Secure Single-Node ElasticSearch (AWS Free Tier, $0/month)

Status: **NOT YET applied/tested** (`terraform plan/apply` belum dijalankan di environment ini — tidak ada AWS credentials/terraform binary tersedia saat kode ini ditulis). Review kode dan jalankan sendiri di akun AWS kamu.

## Apa yang di-provision
- 1x VPC dengan 1 public subnet (no NAT Gateway — traffic keluar lewat Internet Gateway langsung, $0)
- 1x EC2 `t3.micro` (free-tier eligible) menjalankan ElasticSearch single-node
- Security Group: port 9200 (HTTPS) hanya dari `var.allowed_cidr` (default: IP kamu sendiri), TIDAK ada port 22 terbuka
- IAM Role + instance profile untuk **SSM Session Manager** (akses admin tanpa SSH/bastion)
- SSM Parameter Store `SecureString` (AWS-managed KMS key, gratis) untuk password `elastic`
- EBS gp3 10GB, encrypted dengan AWS-managed key (gratis)
- Bootstrap script (`scripts/bootstrap-elasticsearch.sh`) via user-data: install ES, generate self-signed TLS cert, enable X-Pack security, set password dari SSM Parameter Store

## Cara pakai
```bash
cd terraform
terraform init
terraform plan -var="allowed_cidr=$(curl -s https://checkip.amazonaws.com)/32"
terraform apply -var="allowed_cidr=$(curl -s https://checkip.amazonaws.com)/32"
```

## Cara akses (tanpa SSH)
```bash
aws ssm start-session --target $(terraform output -raw instance_id)
```

## Cara verifikasi ES jalan & aman
Dari dalam sesi SSM, atau dari IP yang di-whitelist:
```bash
PASS=$(aws ssm get-parameter --name /elasticsearch/free-tier/elastic-password --with-decryption --query Parameter.Value --output text)
curl -k -u elastic:$PASS https://<public-ip>:9200/_cluster/health?pretty
```
Harus dapat response JSON `"status":"green"` — via HTTPS (bukan HTTP) dan wajib auth (coba tanpa `-u` harus dapat 401).

## Cost reality
- EC2 t3.micro: 750 jam/bulan gratis (12 bulan pertama akun baru) → $0 kalau cuma 1 instance nyala.
- No NAT Gateway → $0 (vs ~$32/bulan kalau pakai private subnet).
- SSM Parameter Store SecureString standard tier → $0.
- KMS AWS-managed key → $0.
- EBS 10GB gp3 → dalam batas 30GB gratis.
- **Estimasi total: $0/bulan** dalam window free-tier.

## Trade-off vs paid-tier
- Single node → **tidak ada HA**, kalau instance down, ES down (no failover).
- Public subnet (bukan private+NAT) → permukaan serang sedikit lebih besar, dimitigasi dengan SG strict + TLS + auth wajib.
- Tidak ada transport-layer TLS (karena cuma 1 node, tidak ada inter-node traffic yang perlu diamankan).
