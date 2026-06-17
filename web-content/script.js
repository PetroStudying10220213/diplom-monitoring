// Функция для получения данных из Prometheus
async function fetchMetric(query) {
    try {
        const response = await fetch(`http://192.168.1.13:9090/api/v1/query?query=${encodeURIComponent(query)}`);
        const data = await response.json();
        if (data.status === 'success' && data.data.result.length > 0) {
            return parseFloat(data.data.result[0].value[1]);
        }
        return 0;
    } catch (error) {
        console.error('Ошибка запроса к Prometheus:', error);
        return 0;
    }
}

// Обновление данных на странице
async function updateStats() {
    // Получаем RPS
    const rps = await fetchMetric('rate(nginx_http_requests_total[1m])');
    document.getElementById('rps-value').textContent = rps.toFixed(2);
    
    // Получаем количество контейнеров (через API Docker, но для простоты оставим статику)
    // В реальности нужно вызывать API, но для диплома достаточно такого варианта
    try {
        const statusResp = await fetch('http://192.168.1.13:80/status');
        if (statusResp.ok) {
            document.getElementById('status-value').innerHTML = '✅ Работает';
            document.getElementById('status-value').className = 'stat-value ok';
        } else {
            document.getElementById('status-value').innerHTML = '⚠️ Перегрузка';
            document.getElementById('status-value').className = 'stat-value';
        }
    } catch (e) {
        document.getElementById('status-value').innerHTML = '❌ Недоступен';
        document.getElementById('status-value').className = 'stat-value';
    }
    
    // Получаем количество контейнеров
    const containers = await fetchMetric('count(container_last_seen{name=~".*web.*"})');
    if (containers > 0) {
        document.getElementById('replicas-value').textContent = Math.round(containers);
    }
}

// Обновляем каждые 5 секунд
updateStats();
setInterval(updateStats, 5000);
