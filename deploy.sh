#!/bin/bash
set -e

echo "=== РАЗВЁРТЫВАНИЕ ДИПЛОМА: Прогнозный мониторинг ==="

# ==========================================
# 1. ПЕРЕМЕННЫЕ
# ==========================================
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_NAME=$(whoami)
cd "$PROJECT_DIR"

echo "Папка проекта: $PROJECT_DIR"
echo "Пользователь: $USER_NAME"

# ==========================================
# 2. DOCKER И DOCKER COMPOSE
# ==========================================
if ! command -v docker &> /dev/null; then
    echo "Установка Docker..."
    sudo apt update
    sudo apt install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo usermod -aG docker $USER_NAME
    echo "Перезапустите сессию и запустите скрипт заново."
    exit 0
fi

# ==========================================
# 3. РЕШАЕМ ПРОБЛЕМУ С DOCKER HUB
# ==========================================
echo "Настройка Docker для надёжной работы..."

sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "registry-mirrors": [
    "https://dockerhub.timeweb.cloud",
    "https://mirror.gcr.io",
    "https://hub.docker.com"
  ],
  "max-concurrent-downloads": 10,
  "max-concurrent-uploads": 5,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

sudo systemctl restart docker
sleep 3

# ==========================================
# 4. PYTHON
# ==========================================
if ! command -v python3 &> /dev/null; then
    echo "Установка Python..."
    sudo apt install -y python3 python3-venv python3-pip
fi

if ! dpkg -s python3-venv &> /dev/null; then
    sudo apt install -y python3-venv
fi

if [ ! -d "venv" ]; then
    python3 -m venv venv
fi
source venv/bin/activate
pip install requests

# ==========================================
# 5. SYSTEMD
# ==========================================
echo "Настройка systemd-сервиса..."

if [ ! -f ml-service/predictor.py ]; then
    echo "Ошибка: ml-service/predictor.py не найден!"
    exit 1
fi

sudo tee /etc/systemd/system/ml-predictor.service > /dev/null <<EOF
[Unit]
Description=ML Predictor for Auto-scaling
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=$USER_NAME
WorkingDirectory=$PROJECT_DIR
ExecStart=$PROJECT_DIR/venv/bin/python3 $PROJECT_DIR/ml-service/predictor.py
Restart=always
RestartSec=10
StandardOutput=append:/var/log/ml-predictor.log
StandardError=append:/var/log/ml-predictor.log

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable ml-predictor
sudo systemctl restart ml-predictor

# ==========================================
# 6. ЗАПУСК КОНТЕЙНЕРОВ (С ПОВТОРАМИ)
# ==========================================
echo "Запуск Docker-контейнеров..."

if [ ! -f docker-compose.yml ]; then
    echo "Ошибка: docker-compose.yml не найден!"
    exit 1
fi

# Подготовка: скачиваем образы по одному с повторными попытками
echo "Скачивание образов (может занять несколько минут)..."
IMAGES=(
    "nginx:alpine"
    "prom/prometheus:latest"
    "grafana/grafana:latest"
    "nginx/nginx-prometheus-exporter:latest"
    "d3vilh/cadvisor:latest"
)

for IMAGE in "${IMAGES[@]}"; do
    RETRY=0
    MAX_RETRY=5
    echo "Скачивание: $IMAGE"
    while [ $RETRY -lt $MAX_RETRY ]; do
        if docker pull "$IMAGE" 2>/dev/null; then
            echo "✓ $IMAGE успешно скачан"
            break
        fi
        RETRY=$((RETRY+1))
        echo "Попытка $RETRY/$MAX_RETRY не удалась. Повтор через 10 секунд..."
        sleep 10
        # Обновляем DNS на всякий случай
        echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf > /dev/null
    done
    if [ $RETRY -eq $MAX_RETRY ]; then
        echo "Не удалось скачать $IMAGE после $MAX_RETRY попыток."
        echo "Проверь интернет: ping 8.8.8.8"
        exit 1
    fi
done

# Запускаем контейнеры
docker compose up -d

# ==========================================
# 7. ИТОГИ
# ==========================================
echo ""
echo "=== РАЗВЁРТЫВАНИЕ ЗАВЕРШЕНО! ==="
IP=$(hostname -I | awk '{print $1}')
echo "Сайт: http://$IP"
echo "Grafana: http://$IP:3000 (admin/admin)"
echo "Prometheus: http://$IP:9090"
echo ""
echo "Логи: tail -f /var/log/ml-predictor.log"
echo "Контейнеры: docker compose ps"
