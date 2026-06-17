#!/bin/bash
set -e

echo "=== РАЗВЁРТЫВАНИЕ ДИПЛОМА: Прогнозный мониторинг ==="

# ==========================================
# 1. ПЕРЕМЕННЫЕ И ПУТИ
# ==========================================
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_NAME=$(whoami)
cd "$PROJECT_DIR"

echo "Папка проекта: $PROJECT_DIR"
echo "Пользователь: $USER_NAME"

# ==========================================
# 2. УСТАНОВКА DOCKER
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
    echo "Docker установлен. Перезапустите сессию и запустите скрипт заново."
    exit 0
fi

# ==========================================
# 3. НАСТРОЙКА ЗЕРКАЛА DOCKER (ЕСЛИ НУЖНО)
# ==========================================
# Проверяем доступность Docker Hub
if ! docker pull hello-world &> /dev/null; then
    echo "Docker Hub недоступен. Настраиваю зеркало..."
    sudo mkdir -p /etc/docker
    sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "registry-mirrors": ["https://dockerhub.timeweb.cloud", "https://mirror.gcr.io"]
}
EOF
    sudo systemctl restart docker
    echo "Зеркало настроено. Повторная попытка..."
fi

# ==========================================
# 4. PYTHON И ВИРТУАЛЬНОЕ ОКРУЖЕНИЕ
# ==========================================
if ! command -v python3 &> /dev/null; then
    echo "Установка Python..."
    sudo apt install -y python3 python3-venv python3-pip
fi

if ! dpkg -s python3-venv &> /dev/null; then
    sudo apt install -y python3-venv
fi

if [ ! -d "venv" ]; then
    echo "Создание виртуального окружения Python..."
    python3 -m venv venv
fi

source venv/bin/activate
pip install requests

# ==========================================
# 5. SYSTEMD-СЕРВИС
# ==========================================
echo "Настройка systemd-сервиса..."

if [ ! -f ml-service/predictor.py ]; then
    echo "Ошибка: файл ml-service/predictor.py не найден!"
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
# 6. ЗАПУСК КОНТЕЙНЕРОВ
# ==========================================
echo "Запуск Docker-контейнеров..."

if [ ! -f docker-compose.yml ]; then
    echo "Ошибка: файл docker-compose.yml не найден!"
    exit 1
fi

# Пытаемся запустить до 3 раз (на случай временных сетевых проблем)
MAX_RETRIES=3
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if docker compose up -d; then
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT+1))
    echo "Попытка $RETRY_COUNT не удалась. Повтор через 10 секунд..."
    sleep 10
    # Очищаем зависшие контейнеры
    docker compose down 2>/dev/null || true
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "⚠️  Не удалось запустить контейнеры после $MAX_RETRIES попыток."
    echo "Проверь интернет: ping 8.8.8.8"
    echo "Или запусти вручную: docker compose up -d"
    exit 1
fi

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
echo ""
echo "=== ДЛЯ ТЕСТА МАСШТАБИРОВАНИЯ ==="
echo "1. Запусти нагрузку: while true; do curl -s http://localhost; done"
echo "2. Смотри логи: tail -f /var/log/ml-predictor.log"
echo "3. Проверяй контейнеры: docker compose ps | grep web"
