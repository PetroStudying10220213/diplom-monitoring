#!/bin/bash
set -e

echo "=== Развёртывание системы прогнозного мониторинга ==="

# 1. Проверка и установка Docker
if ! command -v docker &> /dev/null; then
    echo "Установка Docker..."
    sudo apt update
    sudo apt install -y docker.io docker-compose
    sudo usermod -aG docker $USER
    echo "Docker установлен. Перезапустите сессию и запустите скрипт заново."
    exit 0
fi

# 2. Проверка Python
if ! command -v python3 &> /dev/null; then
    echo "Установка Python..."
    sudo apt install -y python3 python3-venv python3-pip
fi

# 3. Создание виртуального окружения
cd ~/diploma
if [ ! -d "venv" ]; then
    echo "Создание виртуального окружения Python..."
    python3 -m venv venv
fi
source venv/bin/activate
pip install requests

# 4. Настройка systemd-сервиса
echo "Настройка systemd-сервиса..."
sudo tee /etc/systemd/system/ml-predictor.service > /dev/null <<EOF
[Unit]
Description=ML Predictor for Auto-scaling
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=$USER
WorkingDirectory=/home/$USER/diploma
ExecStart=/home/$USER/diploma/venv/bin/python3 /home/$USER/diploma/ml-service/predictor.py
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

# 5. Запуск Docker-контейнеров
echo "Запуск Docker-контейнеров..."
docker compose up -d

# 6. Проверка
echo "=== Развёртывание завершено ==="
echo "Сайт: http://$(hostname -I | awk '{print $1}')"
echo "Grafana: http://$(hostname -I | awk '{print $1}'):3000 (admin/admin)"
echo "Prometheus: http://$(hostname -I | awk '{print $1}'):9090"
echo "Логи ML-сервиса: tail -f /var/log/ml-predictor.log"
