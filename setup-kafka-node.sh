#!/bin/bash

# --------------------------
# Konfigurasi
# --------------------------
KAFKA_VERSION="3.6.0"
SCALA_VERSION="2.13"
KAFKA_DIR="/opt/kafka"
ZOOKEEPER_NODES=("192.168.4.3" "192.168.4.4" "192.168.4.5" "192.168.4.6")  # GANTI sesuai IP cluster
KAFKA_USER="kafka"
ZOOKEEPER_USER="zookeeper"

# --------------------------
# Deteksi IP lokal & broker.id
# --------------------------
THIS_NODE_IP="10.14.73.59"

BROKER_ID=0
for i in "${!ZOOKEEPER_NODES[@]}"; do
    if [[ "${ZOOKEEPER_NODES[$i]}" ]]; then
        BROKER_ID=$((i + 1))
        break
    fi
done

if [[ $BROKER_ID -eq 0 ]]; then
    echo "❌ ERROR: IP $THIS_NODE_IP tidak ditemukan dalam ZOOKEEPER_NODES"
    exit 1
fi

echo "📌 Menyiapkan broker.id=$BROKER_ID untuk IP $THIS_NODE_IP"

# --------------------------
# Install Java
# --------------------------
echo "[1/8] Install Java..."
sudo apt update
sudo apt install -y openjdk-11-jdk wget

# --------------------------
# Install Kafka
# --------------------------
echo "[2/8] Download dan ekstrak Kafka..."
wget -q https://downloads.apache.org/kafka/${KAFKA_VERSION}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz -O /tmp/kafka.tgz
sudo tar -xzf /tmp/kafka.tgz -C /opt
sudo mv /opt/kafka_${SCALA_VERSION}-${KAFKA_VERSION} $KAFKA_DIR

# --------------------------
# Buat user
# --------------------------
echo "[3/8] Membuat user service..."
sudo useradd -r -m -s /bin/false $KAFKA_USER
sudo useradd -r -m -s /bin/false $ZOOKEEPER_USER
sudo chown -R $KAFKA_USER:$KAFKA_USER $KAFKA_DIR

# --------------------------
# Konfigurasi Zookeeper
# --------------------------
echo "[4/8] Konfigurasi Zookeeper..."
ZOOCFG="$KAFKA_DIR/config/zookeeper.properties"
cat <<EOF | sudo tee $ZOOCFG
dataDir=/tmp/zookeeper
clientPort=2181
tickTime=2000
initLimit=5
syncLimit=2
EOF

i=1
for ip in "${ZOOKEEPER_NODES[@]}"; do
  echo "server.$i=$ip:2888:3888" | sudo tee -a $ZOOCFG
  ((i++))
done

sudo mkdir -p /tmp/zookeeper
echo "$BROKER_ID" | sudo tee /tmp/zookeeper/myid

# --------------------------
# Konfigurasi Kafka
# --------------------------
echo "[5/8] Konfigurasi Kafka..."
KAFKACFG="$KAFKA_DIR/config/server.properties"

cat <<EOF | sudo tee $KAFKACFG
broker.id=$BROKER_ID
log.dirs=/tmp/kafka-logs
listeners=SASL_PLAINTEXT://$THIS_NODE_IP:9092
advertised.listeners=SASL_PLAINTEXT://$THIS_NODE_IP:9092
zookeeper.connect=$(IFS=, ; echo "${ZOOKEEPER_NODES[*]/%/:2181}")
num.network.threads=3
num.io.threads=8
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600
log.retention.hours=168
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000
security.inter.broker.protocol=SASL_PLAINTEXT
sasl.mechanism.inter.broker.protocol=PLAIN
sasl.enabled.mechanisms=PLAIN
EOF

# --------------------------
# JAAS Kafka
# --------------------------
echo "[6/8] Membuat JAAS config..."
JAAS_CONF="$KAFKA_DIR/config/kafka_server_jaas.conf"

cat <<EOF | sudo tee $JAAS_CONF
KafkaServer {
   org.apache.kafka.common.security.plain.PlainLoginModule required
   username="admin"
   password="admin-secret"
   user_admin="admin-secret"
   user_budi="budi-secret";
};
EOF

# --------------------------
# systemd Services
# --------------------------
echo "[7/8] Membuat file service..."

# Zookeeper
cat <<EOF | sudo tee /etc/systemd/system/zookeeper.service
[Unit]
Description=Apache Zookeeper Server
After=network.target

[Service]
Type=simple
User=$ZOOKEEPER_USER
Group=$ZOOKEEPER_USER
ExecStart=$KAFKA_DIR/bin/zookeeper-server-start.sh $ZOOCFG
ExecStop=$KAFKA_DIR/bin/zookeeper-server-stop.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Kafka
cat <<EOF | sudo tee /etc/systemd/system/kafka.service
[Unit]
Description=Apache Kafka Server
After=zookeeper.service
Requires=zookeeper.service

[Service]
Type=simple
User=$KAFKA_USER
Group=$KAFKA_USER
Environment="KAFKA_OPTS=-Djava.security.auth.login.config=$JAAS_CONF"
ExecStart=$KAFKA_DIR/bin/kafka-server-start.sh $KAFKACFG
ExecStop=$KAFKA_DIR/bin/kafka-server-stop.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo chown -R $KAFKA_USER:$KAFKA_USER $KAFKA_DIR

# --------------------------
# Jalankan Service
# --------------------------
echo "[8/8] Menjalankan services..."
sudo systemctl daemon-reload
sudo systemctl enable zookeeper
sudo systemctl start zookeeper
sleep 5
sudo systemctl enable kafka
sudo systemctl start kafka

echo "✅ Kafka dan Zookeeper berhasil dijalankan di node $THIS_NODE_IP dengan broker.id=$BROKER_ID"

#chmod +x setup-kafka-node.sh
#sudo ./setup-kafka-node.sh
#Pastikan IP dari semua node dicantumkan di array ZOOKEEPER_NODES dan dalam urutan yang konsisten.
