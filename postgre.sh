#!/bin/bash
# setup-db-node.sh
# Digunakan di NAS dan SCADA3
# Jalankan sebagai root (sudo su)

set -e

NODE_HOSTNAME=$(hostname)
NODE_IP=$(hostname -I | awk '{print $1}')
VIP=10.14.73.59
DATA_DIR=/var/lib/postgresql/14/main
ETCD_CLIENT_PORT=12379
ETCD_PEER_PORT=12380

# Install dependencies
apt update && apt install -y \
  postgresql-14 \
  python3-pip \
  etcd \
  wget curl net-tools \
  build-essential \
  libpq-dev \
  libssl-dev \
  libffi-dev \
  python3-dev \
  libsystemd-dev \
  git \
  pmm2-client

# Install Patroni
pip3 install patroni[etcd]

# Create Patroni config
mkdir -p /etc/patroni
cat <<EOF > /etc/patroni/patroni.yml
scope: pg-ha
name: $NODE_HOSTNAME

restapi:
  listen: 0.0.0.0:8008
  connect_address: $NODE_IP:8008

etcd:
  host: 10.0.0.1:$ETCD_CLIENT_PORT,10.0.0.2:$ETCD_CLIENT_PORT

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    synchronous_mode: true
    postgresql:
      use_pg_rewind: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 64

  initdb:
  - encoding: UTF8
  - data-checksums

  users:
    postgres:
      password: postgres

postgresql:
  listen: 0.0.0.0:5432
  connect_address: $NODE_IP:5432
  data_dir: $DATA_DIR
  bin_dir: /usr/lib/postgresql/14/bin
  authentication:
    superuser:
      username: postgres
      password: postgres
    replication:
      username: replicator
      password: replicator
  parameters:
    unix_socket_directories: '/var/run/postgresql'

watchdog:
  mode: automatic
  device: /dev/watchdog
  safety_margin: 5

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false

callbacks:
  on_role_change: /etc/patroni/on_role_change.sh
EOF

# Setup etcd with custom ports
cat <<EOF > /etc/default/etcd
ETCD_LISTEN_PEER_URLS="http://$NODE_IP:$ETCD_PEER_PORT"
ETCD_LISTEN_CLIENT_URLS="http://$NODE_IP:$ETCD_CLIENT_PORT"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://$NODE_IP:$ETCD_PEER_PORT"
ETCD_INITIAL_CLUSTER="nas=http://10.0.0.1:$ETCD_PEER_PORT,scada3=http://10.0.0.2:$ETCD_PEER_PORT"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster-01"
ETCD_ADVERTISE_CLIENT_URLS="http://$NODE_IP:$ETCD_CLIENT_PORT"
ETCD_NAME="$NODE_HOSTNAME"
EOF

# Patroni systemd
cat <<EOF > /etc/systemd/system/patroni.service
[Unit]
Description=RDBMS HA with Patroni
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/patroni /etc/patroni/patroni.yml
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Create on_role_change callback for VIP
mkdir -p /etc/patroni
cat <<EOF > /etc/patroni/on_role_change.sh
#!/bin/bash
VIP=$VIP
# Otomatis deteksi interface default untuk keluar jaringan
IF=$(ip route get 8.8.8.8 | awk '{print $5; exit}')

if [[ "$1" == "master" ]]; then
    ip addr add $VIP/32 dev $IF || true
else
    ip addr del $VIP/32 dev $IF || true
fi
EOF
chmod +x /etc/patroni/on_role_change.sh

# PMM Client Setup
pmm-admin config --server-insecure-tls --server-url=https://admin:admin@$VIP:443 $NODE_HOSTNAME $NODE_IP || true
pmm-admin add postgresql --username=postgres --password=postgres || true

# Enable services
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable etcd patroni
systemctl start etcd patroni

echo "✅ Setup selesai di node: $NODE_HOSTNAME"
echo "📡 VIP aktif saat role master: $VIP"
echo "📡 etcd Patroni berjalan di port $ETCD_CLIENT_PORT (client), $ETCD_PEER_PORT (peer)"
