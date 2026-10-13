'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require poll';
'require ui';
'require dom';

var status = rpc.declare({ object: 'podkop-autoswitch', method: 'status', expect: {} });
var fetchPool = rpc.declare({ object: 'podkop-autoswitch', method: 'fetch', expect: {} });
var applyPool = rpc.declare({ object: 'podkop-autoswitch', method: 'apply', expect: {} });
var scanPool = rpc.declare({ object: 'podkop-autoswitch', method: 'scan', expect: {} });
var selectNode = rpc.declare({ object: 'podkop-autoswitch', method: 'select', params: ['tag'], expect: {} });

function errorText(code) {
    var errors = {
        no_subscriptions: _('Нет включённых подписок. Добавьте URL и нажмите «Сохранить и применить».'),
        invalid_url: _('У подписки должен быть HTTPS URL.'),
        download_failed: _('Не удалось скачать подписку. Проверьте URL, срок действия подписки и доступ к её сайту.'),
        unsupported_format: _('Пустая подписка, неподдерживаемый формат или параметры узла. Поддерживаются sing-box JSON и URI/base64; Clash YAML не поддерживается.'),
        core_rejected: _('Установленный sing-box не принимает конфигурацию подписки. Проверьте версию ядра и параметры протоколов.'),
        too_large: _('Размер подписки превышает допустимый предел.'),
        too_many_nodes: _('Число серверов превышает настройку «Максимум серверов».'),
        interrupted: _('Задание было прервано. Повторите запрос.'),
        scan_failed: _('Не удалось завершить проверку. Возможен конфликт портов тестового sing-box; проверьте системный журнал.'),
        no_healthy_nodes: _('Ни один сервер не прошёл проверку передачи данных. Все серверы сохранены; можно проверить их снова.'),
        monitoring_disabled: _('Сначала включите мониторинг и сохраните настройки для применения пула.'),
        no_pool: _('Сначала загрузите подписки.'),
        worker_unavailable: _('Не удалось запустить загрузчик. Проверьте системный журнал podkop-autoswitch.'),
        invalid_config: _('Некорректные настройки аддона. Проверьте поля и системный журнал.'),
        internal_error: _('Ошибка загрузки. Проверьте свободное место и системный журнал podkop-autoswitch.')
    };
    return errors[code] || _('Не удалось выполнить запрос. Проверьте системный журнал.');
}
function call(fn) {
    return fn().then(function(r) {
        if (r.ok === false) throw new Error(errorText(r.code));
        if (r.queued) ui.addNotification(null, E('p', {}, _('Задание поставлено в очередь. Состояние обновляется автоматически.')));
    }).catch(function(e) { ui.addNotification(null, E('p', {}, e.message), 'error'); });
}
function button(label, fn, disabled) {
    return E('button', { 'class': 'cbi-button cbi-button-action', 'disabled': disabled || null,
        'click': ui.createHandlerFn(null, function() { return call(fn); }) }, label);
}
return view.extend({
    load: function() { return Promise.all([uci.load('podkop-autoswitch'), uci.load('podkop')]); },
    render: function() {
        var m = new form.Map('podkop-autoswitch', _('Podkop AutoSwitch'),
            _('HTTPS-проверки через sing-box. Рабочий сервер сохраняется; автоматического возврата нет. Первое применение пула и изменение его состава перезапускают Podkop.'));
        var s = m.section(form.NamedSection, 'main', 'settings', _('Настройки'));
        var o = s.option(form.Flag, 'enabled', _('Включить мониторинг и управление Podkop'),
            _('Подписки загружаются и проверяются также при выключенном мониторинге.')); o.rmempty = false;
        o = s.option(form.ListValue, 'section', _('Секция Podkop'));
        uci.sections('podkop', 'section', function(x) {
            if (x.connection_type === 'proxy' && !x['.name'].startsWith('pas_')) o.value(x['.name']);
        });
        o = s.option(form.Flag, 'auto_switch', _('Автоматическое переключение')); o.default = '1'; o.rmempty = false;
        o = s.option(form.Value, 'interval', _('Интервал проверки, с')); o.datatype = 'range(2,3600)'; o.default = '5';
        o = s.option(form.Value, 'failure_threshold', _('Неудач до переключения')); o.datatype = 'range(1,20)'; o.default = '3';
        o = s.option(form.Value, 'timeout_ms', _('Таймаут одной проверки, мс')); o.datatype = 'range(200,10000)'; o.default = '1500';
        o = s.option(form.Value, 'cooldown', _('Минимум между переключениями, с')); o.datatype = 'range(0,86400)'; o.default = '30';
        o = s.option(form.Flag, 'data_check', _('Проверять передачу данных'),
            _('Используется штатный локальный service proxy Podkop. Загрузка списков Podkop также пойдёт через выбранную секцию. Проверка HTTPS GET выявляет серверы, которые отвечают на пинг, но не передают данные.')); o.default = '1'; o.rmempty = false;
        o = s.option(form.Value, 'data_url', _('URL проверки текущего сервера')); o.default = 'https://www.cloudflare.com/cdn-cgi/trace';
        o = s.option(form.Value, 'qualify_url', _('URL проверки кандидата (тело ≥ 1 КБ)')); o.default = 'https://speed.cloudflare.com/__down?bytes=16384';
        o = s.option(form.Value, 'qualify_attempts', _('Попыток проверки кандидата')); o.datatype = 'range(2,6)'; o.default = '4';
        o = s.option(form.Value, 'qualify_successes', _('Успешных передач подряд')); o.datatype = 'range(2,6)'; o.default = '2';
        o = s.option(form.Value, 'parallel_checks', _('Параллельных проверок'),
            _('От 1 до 8 серверов одновременно, по умолчанию 3. Больше проверок требуют больше памяти и пропускной способности. Для всех проверок используется одно тестовое ядро sing-box.')); o.datatype = 'range(1,8)'; o.default = '3';
        o = s.option(form.DynamicList, 'test_url', _('Контрольные HTTPS URL'));
        o.validate = function(id, v) { return !v || /^https:\/\/[^\s]+$/.test(v) ? true : _('Требуется HTTPS URL'); };
        o = s.option(form.Value, 'update_interval', _('Обновление подписок, с')); o.datatype = 'range(300,2592000)'; o.default = '86400';
        o = s.option(form.Flag, 'auto_apply', _('Автоматически применять новый пул'),
            _('Применение изменённого пула перезапускает Podkop. Сначала проверьте работу ручного применения.')); o.rmempty = false;
        o = s.option(form.Value, 'max_nodes', _('Максимум серверов')); o.datatype = 'range(1,256)'; o.default = '64';
        s = m.section(form.TypedSection, 'subscription', _('Подписки'),
            _('Добавьте HTTPS URL и нажмите «Сохранить и применить»: серверы загрузятся автоматически. Мониторинг включать не обязательно. Несколько подписок объединяются; форматы — sing-box JSON, URI-списки и base64.'));
        s.anonymous = true; s.addremove = true;
        o = s.option(form.Flag, 'enabled', _('Использовать')); o.default = '1'; o.rmempty = false;
        o = s.option(form.Value, 'url', _('URL подписки')); o.password = true; o.rmempty = false;
        o.validate = function(id, v) { return /^https:\/\/[^\s]+$/.test(v || '') ? true : _('Требуется HTTPS URL'); };
        var state = E('div', { 'class': 'cbi-section' }, _('Загрузка состояния…'));
        poll.add(function() {
            return status().then(function(d) {
                var imported = d.subscription || {}, loading = (imported.state === 'running' && d.worker_running) || d.fetch_queued;
                var scan = d.scan || {}, scanning = (scan.state === 'running' && d.worker_running) || d.scan_queued;
                var scanText = _('Проверка серверов ещё не запускалась.');
                if (d.scan_queued) scanText = _('Проверка пула ожидает выполнения.');
                else if (scanning) scanText = _('Проверка пула: ') + scan.checked + '/' + scan.total;
                else if (scan.state === 'success') scanText = _('Проверка завершена. Доступно: ') + scan.healthy + '/' + scan.total;
                else if (scan.state === 'error') scanText = errorText(scan.code);
                else if (scan.state === 'running') scanText = errorText('interrupted');
                if (scan.elapsed_s != null && scan.state !== 'idle') scanText += ' · ' + scan.elapsed_s + ' ' + _('с');
                var importText = _('Подписки ещё не загружены. Добавьте URL и нажмите «Сохранить и применить».');
                if (d.fetch_queued) importText = _('Загрузка подписок ожидает выполнения.');
                else if (loading) importText = _('Загрузка подписки №') + imported.source + '…';
                else if (imported.state === 'success') importText = _('Загружено серверов: ') + imported.nodes + ' · ' + new Date(imported.last_success * 1000).toLocaleString();
                else if (imported.state === 'error') importText = (imported.source ? _('Подписка №') + imported.source + ': ' : '') + errorText(imported.code) + (imported.detail ? ' (curl ' + imported.detail + ')' : '');
                else if (imported.state === 'running') importText = errorText('interrupted');
                if (imported.state === 'error' && imported.nodes) importText += ' ' + _('Ранее загруженные серверы сохранены.');
                var results = {};
                (d.servers || []).forEach(function(x) { results[x.tag] = x; });
                var rows = (d.available || []).map(function(node) {
                    var r = results[node.tag] || {};
                    var checked = r.checked_at ? new Date(r.checked_at * 1000).toLocaleTimeString() : '—';
                    return E('tr', { 'class': 'tr' }, [
                        E('td', { 'class': 'td' }, (node.tag === d.current ? '● ' : '') + (node.name || node.tag)),
                        E('td', { 'class': 'td' }, node.protocol),
                        E('td', { 'class': 'td' }, r.healthy === true ? _('Доступен') : r.healthy === false ? _('Недоступен') : _('Не проверен')),
                        E('td', { 'class': 'td' }, r.delay_ms != null ? r.delay_ms + ' ms' : '—'),
                        E('td', { 'class': 'td' }, checked),
                        E('td', { 'class': 'td' }, button(_('Переключить'), function() { return selectNode(node.tag); }, !d.enabled || !d.attached || !node.active || node.tag === d.current))
                    ]);
                });
                if (!rows.length) rows.push(E('tr', { 'class': 'tr' }, [E('td', { 'class': 'td', 'colspan': 6 }, loading ? _('Серверы появятся после загрузки подписок…') : _('Список пуст. Добавьте подписку и сохраните настройки; причину ошибки загрузки смотрите выше.'))]));
                var names = {}; (d.available || []).forEach(function(x) { names[x.tag] = x.name; });
                dom.content(state, [
                    E('h3', {}, _('Состояние')),
                    E('p', {}, _('Служба: ') + (d.enabled ? d.phase : _('выключена')) + ' · ' + _('Пул: ') + (d.attached ? _('подключён') : _('не применён')) + ' · ' + _('Текущий: ') + (names[d.current] || d.current || '—') + ' · ' + _('Ошибок подряд: ') + (d.failures || 0)),
                    E('p', { 'class': imported.state === 'error' ? 'alert-message warning' : '' }, importText),
                    E('p', { 'class': scan.state === 'error' ? 'alert-message warning' : '' }, scanText),
                    E('div', { 'class': 'cbi-page-actions' }, [
                        button(_('Обновить подписки'), fetchPool, loading), ' ',
                        button(_('Проверить все серверы'), scanPool, !(d.available || []).length || loading || scanning), ' ',
                        button(_('Применить пул'), function() {
                            return new Promise(function(resolve) {
                                ui.showModal(_('Применить пул серверов?'), [
                                    E('p', {}, _('Podkop будет перезапущен; текущие соединения могут прерваться. Перед записью выполняются проверка и резервное копирование.')),
                                    E('div', { 'class': 'right' }, [
                                        E('button', { 'class': 'cbi-button', 'click': function() { ui.hideModal(); resolve({}); } }, _('Отмена')), ' ',
                                        E('button', { 'class': 'cbi-button cbi-button-apply', 'click': function() { ui.hideModal(); applyPool().then(resolve); } }, _('Применить'))
                                    ])
                                ]);
                            });
                        }, !d.enabled || !(d.available || []).length || loading)
                    ]),
                    E('table', { 'class': 'table' }, [E('tr', { 'class': 'tr table-titles' }, ['Сервер', 'Протокол', 'Проверка', 'Задержка', 'Время проверки', 'Действие'].map(function(x) { return E('th', { 'class': 'th' }, _(x)); }))].concat(rows))
                ]);
            }).catch(function(e) { dom.content(state, E('p', {}, _('RPC недоступен: ') + e.message)); });
        }, 5);
        return m.render().then(function(form) { return E('div', {}, [state, form]); });
    }
});
