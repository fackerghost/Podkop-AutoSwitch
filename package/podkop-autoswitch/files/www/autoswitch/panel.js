'use strict';
(() => {
    const api = '/cgi-bin/pas-panel', byId = id => document.getElementById(id);
    let timer, busy = false;
    byId('address').textContent = location.origin + '/autoswitch/';
    const states = { healthy: 'Автоматический режим работает', awaiting_pool: 'Автоматическое подключение пула…',
        scanning: 'Ищем рабочий резерв…', no_healthy_backup: 'Поиск продолжается. Подписки обновляются автоматически.',
        wan_unavailable: 'Прямой интернет недоступен. Выбор сервера сохранён.', applying: 'Обновляем состав пула…',
        api_unavailable: 'Нет связи с sing-box', selector_missing: 'Группа серверов изменена в Podkop. Восстанавливаем пул…', integration_error: 'Недоступен локальный proxy Podkop',
        wait: 'Проверяем отказ текущего сервера…', cooldown: 'Пауза между переключениями',
        switched: 'Работа выбранного сервера подтверждена', manual: 'Сервер выбран', manual_failed: 'Проверка выбранного сервера не прошла. Прежний выбор сохранён.' };
    const errors = { lan_only: 'Эта панель доступна только из LAN-подсети роутера по его локальному адресу.',
        not_ready: 'Смена сейчас недоступна: проверьте автоматический режим и состояние подключения.',
        no_pool: 'Сначала добавьте подписки в настройках LuCI.', worker_unavailable: 'Не удалось запустить службу.',
        origin_denied: 'Откройте панель непосредственно по локальному адресу роутера.' };
    async function request(data) {
        const controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 15000);
        try {
            const response = await fetch(api, { method: data ? 'POST' : 'GET', cache: 'no-store', signal: controller.signal,
                headers: data ? { 'Content-Type': 'application/json', 'X-PAS-Panel': '1' } : {}, body: data ? JSON.stringify(data) : undefined });
            const result = await response.json();
            if (!response.ok || result.ok === false) throw new Error(errors[result.code] || 'Запрос не выполнен. Проверьте состояние службы.');
            return result;
        } finally { clearTimeout(timeout); }
    }
    async function act(action, tag) {
        if (busy) return;
        busy = true;
        document.querySelectorAll('button').forEach(b => { b.disabled = true; });
        try { await request({ action, tag }); byId('notice').textContent = 'Запрос принят. Результат появится автоматически.'; }
        catch (e) { byId('notice').textContent = e.message; }
        finally { busy = false; await refresh(); }
    }
    function render(d) {
        const nodes = d.available || [], health = new Map((d.servers || []).map(r => [r.tag, r]));
        const current = nodes.find(n => n.tag === d.current), sample = health.get(d.current) || {};
        byId('current').textContent = current ? current.name : d.current || 'Ожидание пула';
        byId('state').textContent = !d.enabled ? 'Автоматический режим на паузе — включите его в настройках LuCI.' :
            !d.monitor_running ? 'Монитор не запущен. Проверьте службу в LuCI.' : states[d.phase] || d.phase;
        byId('latency').textContent = sample.delay_ms != null ? sample.delay_ms + ' мс' : 'Задержка пока неизвестна';
        const sub = d.subscription || {}, scan = d.scan || {}, sync = d.sync || {};
        byId('progress').textContent = scan.state === 'running' ? 'Проверено: ' + scan.checked + '/' + scan.total :
            sub.state === 'running' ? 'Загрузка подписок…' : sync.state === 'error' ? 'Не удалось подключить пул. Повтор автоматический; подробности в журнале LuCI.' :
            sync.code === 'wan_unavailable' ? states.wan_unavailable : sub.state === 'partial' ? 'Часть подписок недоступна. Прежние узлы сохранены.' :
            sub.state === 'error' ? 'Ошибка загрузки подписок. Сохранён прежний пул; загрузка повторится автоматически.' : '';
        byId('refresh').disabled = busy || sub.state === 'running' || d.fetch_queued;
        byId('scan').disabled = busy || !nodes.length || scan.state === 'running' || d.scan_queued;
        const ready = d.enabled && d.attached && d.monitor_running && !['wan_unavailable', 'selector_missing', 'api_unavailable', 'integration_error', 'applying'].includes(d.phase) && !busy;
        const fragment = document.createDocumentFragment();
        nodes.slice().sort((a, b) => {
            const x = health.get(a.tag) || {}, y = health.get(b.tag) || {};
            const left = x.delay_ms == null ? Infinity : x.delay_ms, right = y.delay_ms == null ? Infinity : y.delay_ms;
            return (left === right ? 0 : left < right ? -1 : 1) || (a.name || a.tag).localeCompare(b.name || b.tag, 'ru');
        }).forEach(node => {
            const r = health.get(node.tag) || {}, selected = node.tag === d.current;
            const row = document.createElement('article'), info = document.createElement('div'), title = document.createElement('strong');
            row.className = 'server' + (selected ? ' selected' : ''); title.textContent = (selected ? '● ' : '') + (node.name || node.tag);
            const detail = document.createElement('p'); detail.textContent = node.protocol + ' · ' + (r.delay_ms != null ? r.delay_ms + ' мс' : 'н/д') + ' · ' +
                (r.healthy === true ? 'Доступен' : r.healthy === false ? 'Последняя проверка неудачна' : 'Ещё не проверен');
            const button = document.createElement('button'); button.textContent = selected ? 'Выбран' : 'Выбрать';
            button.disabled = !ready || !node.active || selected; button.addEventListener('click', () => act('select', node.tag));
            info.append(title, detail); row.append(info, button); fragment.append(row);
        });
        if (!nodes.length) { const empty = document.createElement('p'); empty.textContent = 'Добавьте подписки в настройках LuCI — серверы появятся автоматически.'; fragment.append(empty); }
        byId('servers').replaceChildren(fragment); byId('count').textContent = '(' + nodes.length + ')';
    }
    async function refresh() {
        clearTimeout(timer);
        try { render(await request()); }
        catch (e) { byId('state').textContent = e.message; }
        finally { timer = setTimeout(refresh, 5000); }
    }
    byId('refresh').addEventListener('click', () => act('fetch'));
    byId('scan').addEventListener('click', () => act('scan'));
    refresh();
})();
