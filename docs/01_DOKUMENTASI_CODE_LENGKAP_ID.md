# Dokumentasi Lengkap Code — es-test (3-Node ElasticSearch Cluster + VPN + Monitoring + Alerting)

Dokumen ini menjelaskan **seluruh kode**, baris per baris (per-blok logika), dari proyek take-home test Infrastructure Engineer. Nama folder proyek adalah `es-test/`. Struktur proyek dibagi menjadi 4 stack independen yang saling bergantung secara berurutan:

## Ringkasan Free vs Paid (penting untuk reviewer)

Task instruksi minta "must use free tier, mention any additional paid services used". Implementasi `es-test/` ini **sengaja melebihi free tier** untuk memenuhi bonus 3-node cluster + hardening production-grade. Berikut rincian resource mana yang gratis dan mana yang berbayar:

| Resource | Gratis (Free Tier)? | Catatan |
|---|---|---|
| EC2 `t3.small` × 5 (3 node ES + Kibana + Pritunl VPN) | ❌ Tidak | Free tier cuma cover `t2.micro`/`t3.micro` (750 jam/bulan); `t3.small` dikenakan biaya dari jam pertama |
| NAT Gateway | ❌ Tidak | Tidak pernah gratis di tier apapun |
| AWS Secrets Manager (3 secret: elastic, kibana_system, CA bundle) | ❌ Tidak | ~$0.40/secret/bulan flat |
| KMS customer-managed CMK | ⚠️ Sebagian | 20.000 request/bulan selalu gratis, tapi biaya flat ~$1/bulan/key tidak masuk free tier |
| Elastic IP (terpasang ke instance running) | ✅ Ya | Gratis selama attached |
| CloudWatch Alarm (7 alarm) | ✅ Ya (kuota s.d. 10) | Masuk kuota gratis |
| SNS Email | ✅ Ya | Masuk kuota gratis untuk volume ini |

**Cara resource paid ini dibayar**: akun AWS yang dipakai punya 2 kredit promo aktif — **AWS Free Tier credit ($100)** dan **"Explore AWS: Launch an instance using EC2" credit ($20)**, total **$120**, exp 09/14/2027. AWS otomatis pakai kredit ini untuk menutup invoice bulanan sebelum menyentuh kartu debit/kredit. Terpakai sejauh ini: **$2.09**, sisa **$117.91**. Kalau dibiarkan jalan 24/7 terus, estimasi ~$56-58/bulan (lihat dokumen pendukung EN section 8) akan menghabiskan sisa kredit dalam ~2 bulan sebelum baru kena charge sungguhan.

## Struktur Proyek

```
es-test/
├── terraform/          # Stage 1: VPC + 3x EC2 ES node + KMS + Secrets Manager + S3 relay
├── ansible/            # Stage 1: install & configure ElasticSearch di 3 node
├── vpn/                # Stage 2: Pritunl VPN server (akses ke ES tanpa expose publik)
├── monitoring/          # Stage 3: Kibana (dashboard, hanya bisa diakses via VPN)
├── alerting/            # Stage 4: CloudWatch Alarm + SNS Email + custom health metric
└── deploy.sh (x4)       # 1 script per stack: Terraform → generate inventory → Ansible
```

Urutan **deploy**: ES → VPN → Monitoring → Alerting.
Urutan **destroy**: Alerting → Monitoring → VPN → ES (kebalikan, karena dependency Terraform remote state).

---

## STAGE 1 — ElasticSearch Cluster (`es-test/terraform/main.tf`)

### 1. Provider & AMI
```hcl
provider "aws" { region = var.aws_region }
data "aws_ami" "amazon_linux" { ... filter name = "al2023-ami-*-x86_64" }
```
Menggunakan Amazon Linux 2023 terbaru, region `ap-southeast-3` (Jakarta).

### 2. Networking (baris 32–100)
- `aws_vpc.main` — VPC baru `10.1.0.0/16`, DNS support aktif.
- `aws_subnet.public` — 1 subnet publik untuk NAT Gateway & VPN server.
- `aws_subnet.private` (count=2) — 2 subnet privat di 2 Availability Zone berbeda, tempat node ES ditaruh (tidak punya IP publik).
- `aws_nat_gateway.nat` + `aws_eip.nat` — NAT Gateway berbayar (~$32/bulan) agar node privat tetap bisa akses internet keluar (download package, akses AWS API) tanpa IP publik masuk.
- Route table publik → Internet Gateway; Route table privat → NAT Gateway.

**Kegunaan**: Memisahkan node ES dari akses internet langsung — prinsip *defense in depth*. Node ES hanya bisa dijangkau dari dalam VPC (via VPN) atau via SSM (AWS API, bukan network path publik).

### 3. Security Groups (baris 106–152)
- `aws_security_group.es` — dibuat **tanpa** blok ingress/egress inline. Ini sengaja: mixing inline block dengan resource `aws_security_group_rule` terpisah adalah anti-pattern yang pernah menyebabkan bug nyata (rule transport self-reference terhapus otomatis tiap kali `allowed_cidr` diubah, karena Terraform meng-overwrite semua rule inline di setiap apply).
- `aws_security_group_rule.es_http_ingress` — port 9200 (HTTPS API) hanya dari `var.allowed_cidr`.
- `aws_security_group_rule.es_egress_all` — semua outbound diizinkan (untuk akses NAT/AWS API).
- `aws_security_group_rule.transport_self` — port 9300 (transport layer antar-node) **hanya bisa diakses oleh member SG yang sama** (self-referencing) — tidak pernah terekspos keluar sama sekali.

**Kegunaan**: Port 9200 (API klien) dan 9300 (komunikasi internal cluster) dipisah level akses secara ketat — prinsip least privilege di layer jaringan.

### 4. KMS Customer-Managed Key (baris 154–169)
```hcl
resource "aws_kms_key" "es_cmk" {
  deletion_window_in_days = 7
  enable_key_rotation     = true
}
```
CMK sendiri (bukan AWS-managed key default) untuk enkripsi EBS volume + Secrets Manager. Kelebihan: rotasi kunci otomatis + audit trail CloudTrail granular per-key.

### 5. IAM Role & Policy (baris 171–219)
- `aws_iam_role.es_role` — trust policy: hanya EC2 service yang bisa assume role ini.
- `aws_iam_role_policy_attachment.ssm_core` — attach managed policy `AmazonSSMManagedInstanceCore`, syarat wajib agar SSM Session Manager bisa connect ke instance (mekanisme "no SSH" project ini).
- `aws_iam_role_policy.read_secret` — izin scoped HANYA untuk baca 2 secret spesifik (elastic password + kibana_system password) + `kms:Decrypt` pada CMK terkait. Tidak ada wildcard `*` pada resource secret.

**Kegunaan**: IAM role ini adalah satu-satunya jalan node mengakses password — tidak ada credential hardcoded di manapun.

### 6. Secrets Manager — password generation (baris 220–261)
```hcl
resource "random_password" "elastic_password" { length = 20; special = true }
resource "random_password" "kibana_system_password" { length = 20; special = true }
```
Password acak 20 karakter (termasuk karakter spesial) di-generate Terraform, disimpan di Secrets Manager, dienkripsi CMK.

Catatan penting `recovery_window_in_days = 0`: default AWS adalah 30 hari recovery window sebelum secret benar-benar terhapus — ini akan menghalangi `terraform apply` ulang dengan nama secret yang sama setelah `destroy` (error "already scheduled for deletion"). Untuk exercise iteratif seperti ini, force-delete langsung (`0`) adalah trade-off yang tepat (bukan untuk production yang butuh audit/compliance).

### 7. Shared CA untuk TLS transport (baris 263–316)
```hcl
resource "tls_private_key" "ca_key" { algorithm = "RSA"; rsa_bits = 2048 }
resource "tls_self_signed_cert" "ca_cert" { is_ca_certificate = true; ... }
```
Terraform men-generate 1 CA self-signed, dipakai bersama oleh SEMUA node (bukan CA per-node) — supaya setiap node bisa saling verifikasi sertifikat masing-masing (mutual TLS transport layer). CA cert+key disimpan sebagai JSON tunggal di Secrets Manager, dapat diambil node manapun via IAM role saat boot.

### 8. S3 Bucket untuk SSM Ansible relay (baris 318–345)
```hcl
resource "aws_s3_bucket" "ansible_ssm_transfer" { force_destroy = true }
```
Ansible tidak connect SSH — dia pakai plugin `community.aws.aws_ssm` yang butuh bucket S3 sebagai media transfer file sementara antara controller dan target instance via API SSM (bukan network path langsung). Public access diblokir total (`aws_s3_bucket_public_access_block`).

### 9. EC2 Instance — ES Node x3 (baris 349–401)
```hcl
resource "aws_instance" "es_node" {
  for_each = toset([for i in range(var.node_count) : tostring(i)])
  ...
  root_block_device { encrypted = true; kms_key_id = aws_kms_key.es_cmk.arn }
}
```
`for_each` membuat 3 instance sekaligus (jumlah dikontrol `var.node_count`, default 3) — tersebar di 2 subnet privat (2 AZ) via modulo `each.key % 2`.

`user_data` HANYA minimal: set hostname + install `amazon-ssm-agent` (AMI base ini tidak menyertakannya default — ditemukan lewat trial-and-error saat instance pertama gagal ter-registrasi SSM). **Tidak ada instalasi ElasticSearch di sini** — semua provisioning aplikasi didelegasikan ke Ansible di stage berikutnya, karena Terraform user_data tidak tahu IP privat node lain saat boot (chicken-and-egg problem untuk discovery cluster).

---

## STAGE 1 (lanjutan) — Ansible: `es-test/ansible/elasticsearch.yml`

File ini yang benar-benar menginstall dan mengonfigurasi ElasticSearch, dijalankan via SSM Session Manager (tanpa SSH key sama sekali).

1. **Raise `vm.max_map_count`** → wajib untuk ES bootstrap check, default OS terlalu rendah.
2. **Add Elasticsearch yum repo + install** `elasticsearch` + `jq`.
3. **Fetch shared CA bundle dari Secrets Manager** → simpan sementara di `/tmp`, lalu **shred** (hapus permanen) setelah dipakai — tidak ada rahasia tertinggal di disk.
4. **Cek idempotency sertifikat** — cek apakah cert node yang ada sudah punya SAN entry benar (`DNS:localhost`); kalau belum, hapus & regenerate. Ini mencegah rebuild cert (dan restart ES) tiap kali playbook dijalankan ulang tanpa perubahan nyata.
5. **Generate CA p12 keystore + node cert** ditandatangani oleh CA bersama via `elasticsearch-certutil`.
6. **Fix ownership** cert & direktori ES (ditemukan bug: RPM scriptlet tidak selalu jalan penuh di environment ini, jadi permission harus dipaksa manual).
7. **Simpan password p12 keystore ke ES keystore terenkripsi** (bukan plaintext di `elasticsearch.yml`) via `elasticsearch-keystore add -x`.
8. **Populate `unicast_hosts.txt`** dengan IP privat SEMUA node (loop `groups['es_nodes']`) — inilah **fix kunci** untuk discovery cluster: script user_data lama tidak bisa tahu IP node lain saat boot, tapi Ansible tahu semuanya dari inventory di awal, jadi bisa menulis peer list yang benar sekaligus ke semua node.
9. **Rewrite `elasticsearch.yml` bersih** (hapus auto-config RPM bawaan yang konflik dengan setup security manual kita), lalu tulis blok managed:
   ```yaml
   cluster.name: es-paidtier-cluster
   node.roles: [ master, data ]
   discovery.seed_providers: file
   cluster.initial_master_nodes: [semua node]
   xpack.security.enabled: true
   xpack.security.http.ssl.enabled: true
   xpack.security.transport.ssl.enabled: true
   ```
   TLS diaktifkan di **kedua** layer: HTTP (klien) dan transport (antar-node) — syarat wajib task PDF ("provides encrypted communication").
10. **Restart ES hanya jika ada perubahan config/cert** (bukan restart buta tiap run) — cek `es_config_result.changed or node_cert_has_san.rc != 0`.
11. **Tunggu API HTTPS lokal siap** (retry 24x, delay 5s = max 2 menit).
12. **Set password `elastic` superuser** — **INI BAGIAN YANG PERNAH BUG (root cause 401)**:
    ```yaml
    shell: |
      printf 'y\n%s\n%s\n' "$ELASTIC_PW" "$ELASTIC_PW" | elasticsearch-reset-password -u elastic -i ...
    environment:
      ELASTIC_PW: "{{ elastic_pw.stdout }}"
    ```
    Password **tidak** ditulis langsung sebagai literal string Jinja di dalam script bash — kalau begitu, karakter `$` diikuti huruf/angka (contoh: `...$a4...`) akan disalahartikan bash sebagai variable expansion, sehingga password yang benar-benar tersubmit BUKAN password asli, sementara command tetap melaporkan sukses. Fix: password dilewatkan via `environment:` Ansible, direferensikan sebagai `"$ELASTIC_PW"` — bash melakukan substitusi variabel yang sah, bukan string literal.
13. **Report cluster health** (sanity check, tidak print password).
14. **Fetch & set password `kibana_system`** — pola identik dengan poin 12, karena bug yang sama juga terjadi di sini (ini penyebab asli Kibana 503).
15. **Pause 8 detik** — beri waktu propagasi index security internal ES sebelum verifikasi.
16. **Verify password `kibana_system` benar-benar berfungsi** (fail loud):
    ```yaml
    uri: { url: https://localhost:9200/_cluster/health, user: kibana_system, status_code: 200 }
    retries: 10; delay: 5
    ```
    Task ini KHUSUS ditambahkan sebagai *safety net* permanen: kalau password reset melaporkan sukses tapi ternyata salah (skenario yang justru terjadi di masa lalu), playbook akan **gagal secara eksplisit di sini**, bukan lolos diam-diam dan baru ketahuan belakangan lewat Kibana yang error 503.

---

## STAGE 2 — VPN (`es-test/vpn/`)

### Terraform (`vpn/terraform/main.tf`)
- Baca state ES cluster via `terraform_remote_state` (`backend = "local"`, path relatif ke `terraform.tfstate` stage 1) — dependency antar-stack tanpa perlu remote backend (S3/DynamoDB), cocok untuk exercise single-operator ini.
- `aws_security_group.vpn` — ingress 443 (web admin Pritunl) dari `admin_cidr` (IP operator), ingress UDP 1194 (OpenVPN tunnel) dari `0.0.0.0/0` (autentikasi terjadi di layer VPN client-profile, bukan network ACL — pola standar VPN).
- `aws_security_group_rule.vpn_to_es` — menambahkan rule ke SG ES yang SUDAH ADA (dari stage 1) agar node ES percaya SG VPN pada port 9200. Ini **satu-satunya** jalur user manusia bisa akses ES API secara langsung.
- 1x EC2 instance Pritunl di subnet publik + Elastic IP.

### Ansible (`vpn/ansible/pritunl.yml`)
1. Import GPG key MongoDB, install repo, install `mongodb-org` (database Pritunl).
2. Install repo Pritunl — **catatan risiko**: `gpgcheck: false` karena GPG key resmi Pritunl sudah tidak ter-publish di lokasi manapun yang dicoba (404 di semua mirror). Mitigasi: repo tetap via HTTPS (transport aman), tapi tidak ada package-level signature verification. Diterima sebagai risiko untuk environment demo, TIDAK untuk production tanpa perbaikan lebih lanjut.
3. Start MongoDB + Pritunl service.
4. Tunggu web UI Pritunl merespon (`/` bukan `/ping` — endpoint lama sudah 404 di versi terbaru).
5. Setup admin awal, organisasi, server VPN, user, dan download profil `.ovpn` — **fully automated**, tidak ada langkah manual UI: `vpn/ansible/pritunl-provision.yml` menyalakan API Pritunl langsung via injeksi MongoDB (`auth_api: true` pada admin user), lalu memanggil REST API Pritunl (helper `vpn/ansible/files/pritunl_provision.py`, HMAC-signed) untuk membuat Organization + Server + User, start server, download profile `.ovpn` (endpoint tersembunyi `/data/<org_id>/<user_id>/<server_id>.key`, tidak ada di dokumentasi resmi Pritunl — ditemukan via trace source code langsung di instance), dan menyimpan semuanya (admin password, API token/secret, profile `.ovpn` base64) ke HashiCorp Vault (`kv/pritunl`). Jalankan setelah `pritunl.yml`:
   ```bash
   ansible-playbook -i inventory.ini pritunl-provision.yml
   ```


---

## STAGE 3 — Monitoring / Kibana (`es-test/monitoring/`)

### Terraform (`monitoring/terraform/main.tf`)
- Baca 2 remote state: ES (stage 1) dan VPN (stage 2).
- `aws_security_group.kibana` — port 5601 **hanya** dari SG VPN (`source_security_group_id`, bukan CIDR publik) — akses Kibana hanya via VPN tunnel.
- `aws_security_group_rule.es_from_kibana` — tambah rule ke SG ES agar Kibana bisa reach port 9200.
- IAM role Kibana dengan izin baca 2 secret (kibana_system password + CA bundle) + `kms:Decrypt`.
- 1x EC2 di subnet **privat** (sama seperti node ES) — Kibana TIDAK butuh IP publik sama sekali karena hanya diakses via VPN tunnel internal.

### Ansible (`monitoring/ansible/kibana.yml`)
1. Install Kibana + jq dari repo Elastic yang sama.
2. Fetch CA bundle → tulis `es_ca.crt` agar Kibana percaya sertifikat self-signed ES.
3. Fetch password `kibana_system` (BUKAN password `elastic` — Kibana 8.x menolak keras user superuser `elastic` untuk koneksi service-to-service).
4. Tulis `kibana.yml`:
   ```yaml
   elasticsearch.hosts: [https://<ip-node-1>:9200, https://<ip-node-2>:9200, https://<ip-node-3>:9200]
   elasticsearch.username: kibana_system
   elasticsearch.ssl.certificateAuthorities: [/etc/kibana/certs/es_ca.crt]
   ```
5. **Wait for Kibana ready — INI BAGIAN YANG PERNAH BUG (503 masking)**:
   ```yaml
   uri: { url: http://localhost:5601/api/status, status_code: 200 }
   retries: 30; delay: 5
   ```
   Versi lama task ini menerima `[200, 503]` sebagai "sukses" — niatnya toleransi Kibana yang masih initializing. Efek sampingnya: kalau Kibana STUCK permanen di 503 (misal karena auth `kibana_system` rusak), playbook tetap lapor sukses, dan baru diketahui error belakangan saat manual curl. Fix: hanya terima 200, gagal loud kalau tidak pernah tercapai dalam 30×5=150 detik.

---

## STAGE 4 — Alerting (`es-test/alerting/`)

### Terraform (`alerting/terraform/main.tf`)
1. `aws_sns_topic.alerts` — 1 topic tunggal, dipakai semua alarm.
2. `aws_sns_topic_subscription.email` — subscribe email `alert_email` ke topic. **Ini satu-satunya langkah manual di seluruh proyek**: AWS mengirim email konfirmasi link yang harus diklik manual — limitasi API AWS, bukan sesuatu yang bisa diautomasi Terraform.
3. `aws_cloudwatch_metric_alarm.es_node_cpu_high` (per node, `for_each`) — alarm CPU > 80% selama 15 menit (3×5menit).
4. `aws_cloudwatch_metric_alarm.es_node_status_check_failed` (per node) — alarm AWS instance/system status check gagal (deteksi hardware/network failure level EC2).
5. `aws_cloudwatch_metric_alarm.es_cluster_health_not_green` — alarm berbasis **custom metric** (CloudWatch tidak tahu apa-apa soal health internal ES secara native).
6. `aws_iam_role_policy.es_cloudwatch_put_metric` — tambah izin `cloudwatch:PutMetricData` ke role ES yang sudah ada, dibatasi hanya untuk namespace `EsTest/Custom` (least privilege, tidak wildcard semua namespace).

Semua alarm pakai `treat_missing_data = "breaching"` — kalau metric tidak ada sama sekali (node mati, cron berhenti, dsb), dianggap kondisi BURUK dan alarm tetap trigger. Ini mencegah kegagalan monitoring itu sendiri jadi silent.

### Ansible (`alerting/ansible/es-metrics-cron.yml`)
1. Fetch password `elastic`.
2. Tulis script `/usr/local/bin/es-health-metric.sh`: curl `_cluster/health` lokal → mapping status ke angka (`green=0, yellow=1, red=2, unknown=2`) → `aws cloudwatch put-metric-data`.
3. Install `cronie` (paket cron tidak ada default di AMI minimal ini).
4. Jalankan setiap 1 menit via cron.
5. Jalankan sekali langsung setelah install untuk verifikasi end-to-end (bukan hanya percaya cron akan jalan nanti).

---

## Shell Script Orkestrasi (`deploy.sh` — 4 varian, 1 per stack)

Pola sama di semua 4 file:
1. **Ambil AWS credential dari Vault lokal** (`docker exec ... vault kv get kv/aws-ft`) — tidak pernah hardcode credential di file manapun.
2. `terraform init` + `terraform apply -auto-approve` (infra stage).
3. **Generate `inventory.ini` Ansible secara otomatis** dari `terraform output -json` (Python heredoc inline) — zero manual step antara Terraform dan Ansible.
4. **Tunggu instance register di SSM** (loop polling `aws ssm describe-instance-information`, max 30×10s=300s) + `sleep 15` tambahan — fix race condition: status SSM bisa "Online" beberapa detik SEBELUM `StartSession` benar-benar bisa connect (ditemukan lewat testing berulang).
5. **Retry Ansible run 3x** kalau gagal (delay 15s antar-retry) — menoleransi flakiness SSM tanpa gagal permanen di percobaan pertama.
6. Print token sukses (`DEPLOY_COMPLETE`, dst.) agar bisa dideteksi programatis.

---

## Ringkasan Alur Bug yang Ditemukan & Diperbaiki (kronologis)

1. **Security group rule ter-overwrite** — inline block vs separate rule resource, fixed dengan full separate `aws_security_group_rule`.
2. **SSM race condition** — `PingStatus=Online` tidak berarti `StartSession` langsung bisa connect, fixed dengan `sleep 15` tambahan di semua 4 `deploy.sh`.
3. **Kibana 503 "toleran"** — health check lama menerima 503 sebagai sukses, menutupi bug asli, fixed jadi strict-200 only.
4. **Root cause sebenarnya: shell-injection password** — password random mengandung `$` + alfanumerik dimangle bash saat di-splat sebagai literal Jinja string ke `shell:` block, fixed dengan `environment:` var + referensi `"$VAR"` yang aman, diterapkan ke SEMUA task set-password (elastic & kibana_system).
5. Ditambahkan **safety net permanen**: task verifikasi auth eksplisit dengan retry & fail-loud, agar kelas bug serupa di masa depan (karakter spesial apapun) langsung ketahuan saat deploy, bukan belakangan.

Semua fix di atas sudah divalidasi ulang lewat **full destroy → recreate dari nol**, bukan hanya resume idempotent — hasil akhir: ES cluster green 3/3 node, Kibana HTTP 200, verifikasi auth `kibana_system` lolos otomatis tanpa intervensi manual apapun (kecuali klik link konfirmasi email SNS, yang merupakan limitasi AWS API, bukan limitasi kode).

---

## Cara Provisioning (Setup)

### Prasyarat (sekali saja)
1. AWS credential dengan `AdministratorAccess` (atau policy least-privilege yang cover VPC/EC2/IAM/KMS/SecretsManager/CloudWatch/SNS/S3/SSM) untuk akun target.
2. `terraform`, `ansible`, `aws` CLI, dan `session-manager-plugin` (AWS SSM) sudah terinstall lokal dan ada di `PATH`.
3. **Tidak perlu SSH keypair sama sekali** — semua akses ke instance lewat AWS SSM Session Manager, port 22 tidak pernah dibuka.

### Flow Provisioning (per stack)
Keempat stack (`es-test/`, `es-test/vpn/`, `es-test/monitoring/`, `es-test/alerting/`) mengikuti **pola 3-langkah yang identik dan fully-automated**, dijalankan lewat `deploy.sh` masing-masing stack:

1. **`terraform init` + `terraform apply`** — membuat/update semua resource AWS untuk stack tersebut (VPC, EC2, IAM, KMS, Secrets Manager, CloudWatch, SNS, S3, dst., tergantung stack). Stack turunan (vpn/monitoring/alerting) membaca output stack sebelumnya lewat `terraform_remote_state`, jadi urutan apply **wajib** sesuai dependency, tidak bisa dibalik.
2. **Generate inventory Ansible otomatis** — blok Python inline membaca `terraform output -json` dari stack yang baru di-apply (plus output stack upstream yang dibutuhkan, misal monitoring butuh output VPN+ES) lalu menulis langsung `ansible/inventory.ini` — **tidak ada edit manual file inventory sama sekali**.
3. **`ansible-playbook`** — konfigurasi software di instance yang baru dibuat (install ElasticSearch/Pritunl/Kibana, generate/rotate cert & password, tulis config, install cron job, dst.), koneksi eksklusif lewat `ansible_connection=community.aws.aws_ssm` (bukan SSH). Setiap `deploy.sh` polling `aws ssm describe-instance-information` dulu (instance baru butuh ~60-90 detik untuk register ke SSM sebelum bisa dijangkau Ansible), dan retry playbook run sampai 3x untuk menoleransi race condition SSM yang ditemukan saat testing.

### Urutan Provisioning (wajib berurutan)
```
1. es-test/           deploy.sh <allowed_cidr>        (ElasticSearch, 3 node)
2. es-test/vpn/        deploy.sh <admin_cidr>          (Pritunl VPN — baca state ES)
3. es-test/monitoring/ deploy.sh                       (Kibana — baca state ES + VPN)
4. es-test/alerting/   deploy.sh <alert_email>         (CloudWatch + SNS — baca state ES)
```
Urutan **destroy** adalah kebalikan persis (alerting → monitoring → vpn → es-test), karena Terraform state setiap stack bergantung ke stack sebelumnya lewat `terraform_remote_state`.

Sebagai shortcut, `~/vault/recreate-all.sh` di sisi operator menjalankan keempat stack sekaligus dalam urutan yang benar via satu command (dipakai untuk memvalidasi full destroy→recreate dari akun AWS kosong pada sesi ini).

### Satu langkah manual (tidak terhindarkan, bukan shortcut yang disengaja)
- **Stack alerting**: setelah `deploy.sh` selesai, AWS mengirim email Subscription Confirmation link ke alamat email alert — pipeline alarm belum akan mengirim notifikasi apapun sampai link itu diklik. Tidak ada AWS API untuk auto-confirm subscription SNS email tanpa memiliki akses ke mailbox tersebut.

Ini **satu-satunya** langkah manual di seluruh proyek. Stack VPN (Pritunl) **tidak lagi manual** — `vpn/ansible/pritunl-provision.yml` mengotomasi seluruh setup admin, organisasi, server, user, dan download profile `.ovpn` via REST API (lihat detail di STAGE 2 di atas).

Selain hal di atas, **semuanya** — pembuatan infra, install software, generate cert TLS, generate/rotasi password, cron job, wiring alarm/topic, dan setup VPN — fully automated end-to-end tanpa langkah manual apapun.

---

## Cara Mengakses ES + Kibana (setelah semua stack di-deploy)

Satu-satunya jalur akses eksternal ke ES/Kibana secara by-design adalah **VPN Pritunl** — keduanya tidak pernah diexpose ke internet publik.

### 1. Connect ke VPN
```bash
# ambil profile .ovpn (base64) dari Vault operator
vault kv get -field=ovpn_profile_b64 kv/pritunl | base64 -d > client.ovpn
# import ke OpenVPN client (Tunnelblick/OpenVPN Connect/NetworkManager) dan connect
```
Setelah connect, kamu masuk ke VPC private network (`10.1.0.0/16`) dan bisa langsung menjangkau IP privat semua node.

### 2. Elasticsearch — HTTPS, TLS self-signed, port 9200, 3 node
```
https://<ip-privat-node-0>:9200
https://<ip-privat-node-1>:9200
https://<ip-privat-node-2>:9200
```
(IP privat aktual: lihat `terraform output` di `es-test/terraform/` atau `ansible/inventory.ini` hasil generate.)

Auth basic (`elastic` superuser), password di Secrets Manager:
```bash
aws secretsmanager get-secret-value --secret-id elasticsearch/es-test/elastic-password \
  --region ap-southeast-3 --query SecretString --output text
```
Contoh curl (`-k` skip verifikasi cert self-signed; download `elasticsearch/es-test/ca-bundle` dari Secrets Manager kalau mau full cert verification):
```bash
curl -k -u elastic:<password> https://<ip-privat-node-0>:9200/_cluster/health?pretty
```

**Registrasi endpoint di sisi aplikasi**: daftarkan **ketiga IP node**, bukan cuma satu — hampir semua ES client resmi (Python/Java/Node) mendukung multi-node list dan otomatis failover/round-robin ke node yang hidup kalau salah satu node down.
```python
from elasticsearch import Elasticsearch
es = Elasticsearch(
    ["https://<ip-node-0>:9200", "https://<ip-node-1>:9200", "https://<ip-node-2>:9200"],
    basic_auth=("elastic", "<password_dari_secrets_manager>"),
    verify_certs=False,
)
```
Catatan: ketiga node punya role identik (`master`, `data`) — tidak ada pemisahan node khusus read vs write. Pembagian kerja read/write terjadi di level **shard** (primary shard menangani write lalu direplikasi; primary maupun replica shard bisa melayani read), bukan di level node — client bisa connect ke node manapun dan ES otomatis routing internal ke shard yang relevan.

### 3. Kibana — HTTP plain (internal-only, aman karena hanya reachable via VPN), port 5601
```
http://<ip-privat-kibana>:5601
```
Login dengan user `elastic` + password yang sama (Kibana sendiri connect ke ES via service-account `kibana_system`, tapi login UI pakai `elastic`).

Buka browser (harus dalam koneksi VPN aktif) → `http://<ip-privat-kibana>:5601` → login. Semua traffic ini murni internal VPC, zero exposure publik.

