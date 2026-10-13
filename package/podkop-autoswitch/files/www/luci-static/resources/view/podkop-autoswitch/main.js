'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require poll';
'require ui';

var status = rpc.declare({ object: 'podkop-autoswitch', method: 'status', expect: {} });
var fetchPool = rpc.declare({ object: 'podkop-autoswitch', method: 'fetch', expect: {} });
var applyPool = rpc.declare({ object: 'podkop-autoswitch', method: 'apply', expect: {} });
var scanPool = rpc.declare({ object: 'podkop-autoswitch', method: 'scan', expect: {} });
var selectNode = rpc.declare({ object: 'podkop-autoswitch', method: 'select', params: ['tag'], expect: {} });

function call(fn) {
    return fn().then(function(r) {
        ui.addNotification(null, E('p', {}, r.queued ? _('Задание поставлено в очередь. Служба должна быть включена.') : _('Запрос выполнен.')));
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
        var o = s.option(form.Flag, 'enabled', _('Включить службу')); o.rmempty = false;
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
        o = s.option(form.DynamicList, 'test_url', _('Контрольные HTTPS URL'));
        o.validate = function(id, v) { return !v || /^https:\/\/[^\s]+$/.test(v) ? true : _('Требуется HTTPS URL'); };
        o = s.option(form.Value, 'update_interval', _('Обновление подписок, с')); o.datatype = 'range(300,2592000)'; o.default = '86400';
        o = s.option(form.Flag, 'auto_apply', _('Автоматически применять новый пул'),
            _('Применение изменённого пула перезапускает Podkop. Сначала проверьте работу ручного применения.')); o.rmempty = false;
        o = s.option(form.Value, 'max_nodes', _('Максимум серверов')); o.datatype = 'range(1,256)'; o.default = '64';
        s = m.section(form.TypedSection, 'subscription', _('Подписки'),
            _('Несколько HTTPS-подписок объединяются; дубликаты удаляются. JSON sing-box, URI-списки и base64.'));
        s.anonymous = true; s.addremove = true;
        o = s.option(form.Flag, 'enabled', _('Использовать')); o.default = '1'; o.rmempty = false;
        o = s.option(form.Value, 'url', _('URL подписки')); o.password = true; o.rmempty = false;
        o.validate = function(id, v) { return /^https:\/\/[^\s]+$/.test(v || '') ? true : _('Требуется HTTPS URL'); };
        var state = E('div', { 'class': 'cbi-section' }, _('Загрузка состояния…'));
        poll.add(function() {
            return status().then(function(d) {
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
                        E('td', { 'class': 'td' }, button(_('Переключить'), function() { return selectNode(node.tag); }, !d.enabled || node.tag === d.current))
                    ]);
                });
                var names = {}; (d.available || []).forEach(function(x) { names[x.tag] = x.name; });
                ui.setElementContent(state, [
                    E('h3', {}, _('Состояние')),
                    E('p', {}, _('Служба: ') + (d.enabled ? d.phase : _('выключена')) + ' · ' + _('Текущий: ') + (names[d.current] || d.current || '—') + ' · ' + _('Ошибок подряд: ') + (d.failures || 0)),
                    E('div', { 'class': 'cbi-page-actions' }, [
                        button(_('Обновить подписки'), fetchPool, !d.enabled), ' ',
                        button(_('Проверить все серверы'), scanPool, !d.enabled), ' ',
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
                        }, !d.enabled)
                    ]),
                    E('table', { 'class': 'table' }, [E('tr', { 'class': 'tr table-titles' }, ['Сервер', 'Протокол', 'Проверка', 'Задержка', 'Время проверки', 'Действие'].map(function(x) { return E('th', { 'class': 'th' }, _(x)); }))].concat(rows))
                ]);
            }).catch(function(e) { ui.setElementContent(state, E('p', {}, _('RPC недоступен: ') + e.message)); });
        }, 5);
        return m.render().then(function(form) { return E('div', {}, [state, form]); });
    }
});
