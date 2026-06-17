
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
# 2. УСТАНОВКА DOCKER И DOCKER COMPOSE
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

# Проверка Docker Compose (V2)
if ! docker compose version &> /dev/null; then
    echo "Установка Docker Compose V2..."
    sudo apt install -y docker-compose-plugin
fi

# ==========================================
# 3. УСТАНОВКА PYTHON И ЗАВИСИМОСТЕЙ
# ==========================================
if ! command -v python3 &> /dev/null; then
    echo "Установка Python..."
    sudo apt install -y python3 python3-venv python3-pip
fi

# Убеждаемся, что python3-venv установлен
if ! dpkg -s python3-venv &> /dev/null; then
    echo "Установка python3-venv..."
    sudo apt install -y python3-venv
fi

# Создаём виртуальное окружение (если его нет)
if [ ! -d "venv" ]; then
    echo "Создание виртуального окружения Python..."
    python3 -m venv venv
fi

source venv/bin/activate
pip install requests

# ==========================================
# 4. НАСТРОЙКА SYSTEMD-СЕРВИСА
# ==========================================
echo "Настройка systemd-сервиса..."

# Проверяем, есть ли нужные папки
mkdir -p ml-service
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
# 5. ЗАПУСК КОНТЕЙНЕРОВ
# ==========================================
echo "Запуск Docker-контейнеров..."

# Проверяем, есть ли docker-compose.yml
if [ ! -f docker-compose.yml ]; then
    echo "Ошибка: файл docker-compose.yml не найден!"
    exit 1
fi

# Запускаем контейнеры
if ! docker compose up -d; then
    echo "Ошибка при запуске контейнеров! Проверь логи: docker compose logs"
    exit 1
fi

# ==========================================
# 6. ПРОВЕРКА
# ==========================================
echo ""
echo "=== РАЗВЁРТЫВАНИЕ ЗАВЕРШЕНО! ==="
IP=$(hostname -I | awk '{print $1}')
echo "Сайт: http://$IP"
echo "Grafana: http://$IP:3000 (admin/admin)"
echo "Prometheus: http://$IP:9090"
echo ""
echo "Логи: tail -f /var/log/ml-predictor.log"
echo "Статус: sudo systemctl status ml-predictor"
echo "Контейнеры: docker compose ps"
echo ""
echo "=== ДЛЯ ТЕСТА МАСШТАБИРОВАНИЯ ==="
echo "1. Запусти нагрузку: while true; do curl -s http://localhost; done"
echo "2. Смотри логи: tail -f /var/log/ml-predictor.log"
echo "3. Проверяй контейнеры: docker compose ps | grep web"
