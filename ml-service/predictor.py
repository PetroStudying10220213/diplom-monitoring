#!/usr/bin/env python3
import time
import requests
import subprocess
import json
import threading
from datetime import datetime

PROMETHEUS_URL = "http://localhost:9090"
THRESHOLD = 30
CHECK_INTERVAL = 15
HISTORY_SIZE = 10

history = []
scaled_recently = False

def get_current_load():
    query = 'rate(nginx_http_requests_total[1m])'
    try:
        response = requests.get(f"{PROMETHEUS_URL}/api/v1/query", params={'query': query}, timeout=5)
        data = response.json()
        if data['status'] == 'success' and data['data']['result']:
            return float(data['data']['result'][0]['value'][1])
    except Exception as e:
        print(f"[!] Ошибка метрики: {e}")
    return 0

def simple_predict(history_data):
    if len(history_data) < 3:
        return history_data[-1] if history_data else 0
    if history_data[-1] > history_data[-2] > history_data[-3]:
        return history_data[-1] * 1.5
    return history_data[-1]

def get_current_replicas():
    try:
        result = subprocess.run(
            ['docker', 'compose', 'ps', '--format', 'table'],
            capture_output=True, text=True, cwd='/home/diplom/diploma'
        )
        lines = result.stdout.strip().split('\n')
        web_count = 0
        for line in lines:
            if 'web' in line and 'Up' in line:
                web_count += 1
        return web_count if web_count > 0 else 1
    except:
        return 1

def scale_up():
    global scaled_recently
    if scaled_recently:
        print("[SKIP] Уже масштабировали недавно, пропускаю")
        return
    scaled_recently = True

    current = get_current_replicas()
    if current >= 3:
        print(f"[!] Уже {current} контейнера, не масштабирую дальше")
        return

    new_count = current + 1
    print(f"[ACTION] МАСШТАБИРОВАНИЕ: {current} -> {new_count} контейнеров")
    subprocess.run(
        ['docker', 'compose', 'up', '-d', '--scale', f'web={new_count}'],
        cwd='/home/diplom/diploma'
    )

    def reset_flag():
        global scaled_recently
        time.sleep(60)
        scaled_recently = False
    threading.Thread(target=reset_flag, daemon=True).start()

def scale_down():
    global scaled_recently

    current = get_current_replicas()
    if current > 1 and all(l < 1.0 for l in history[-10:]):
        new_count = current - 1
        print(f"[ACTION] УМЕНЬШЕНИЕ: {current} -> {new_count} контейнеров (нагрузка низкая)")
        subprocess.run(
            ['docker', 'compose', 'up', '-d', '--scale', f'web={new_count}'],
            cwd='/home/diplom/diploma'
        )
        time.sleep(60)
        return

    if scaled_recently:
        return

    current = get_current_replicas()
    if current <= 1:
        return

    if len(history) >= 6 and all(l < THRESHOLD / 2 for l in history[-6:]):
        new_count = current - 1
        print(f"[ACTION] УМЕНЬШЕНИЕ: {current} -> {new_count} контейнеров (нагрузка низкая)")
        subprocess.run(
            ['docker', 'compose', 'up', '-d', '--scale', f'web={new_count}'],
            cwd='/home/diplom/diploma'
        )
        scaled_recently = True
        def reset_flag():
            global scaled_recently
            time.sleep(60)
            scaled_recently = False
        threading.Thread(target=reset_flag, daemon=True).start()

print("=" * 50)
print("ML-сервис прогнозирования нагрузки запущен")
print(f"Порог: {THRESHOLD} RPS, интервал: {CHECK_INTERVAL} сек")
print("=" * 50)

while True:
    try:
        current = get_current_load()
        history.append(current)
        if len(history) > HISTORY_SIZE:
            history.pop(0)

        predicted = simple_predict(history)
        replicas = get_current_replicas()
        print(f"[{datetime.now().strftime('%H:%M:%S')}] [LOAD] Текущая: {current:.2f} | Прогноз: {predicted:.2f} | Контейнеров: {replicas}")

        if predicted > THRESHOLD and len(history) > 3 and not scaled_recently:
            print(f"[WARN] Прогноз ({predicted:.2f}) превышает порог ({THRESHOLD})!")
            scale_up()
        else:
            scale_down()

        time.sleep(CHECK_INTERVAL)
    except KeyboardInterrupt:
        print("\n[STOP] Сервис остановлен")
        break
    except Exception as e:
        print(f"[ERROR] Ошибка: {e}")
        time.sleep(CHECK_INTERVAL)
