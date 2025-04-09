local fio = require('fio')
local log = require('log')
local socket = require('socket') -- Добавлено для проверки портов
local Server = require('test.helpers.server')
local fiber = require('fiber')
local cluster = {}

-- Создание и запуск экземпляров кластера
function cluster.start(ports)
    -- Добавлено очищение данных в начало
    local datadir = fio.pathjoin(fio.cwd(), 'test_cluster_data')
    if fio.path.exists(datadir) then
        fio.rmtree(datadir)  -- Удаляем старые данные
    end
    fio.mkdir(datadir)  -- Создаем новую директорию

    if cluster.servers ~= nil then
        log.warn("Кластер уже запущен")
        return
    end

    if type(ports) ~= 'table' or #ports == 0 then
        error("Необходимо указать таблицу портов для серверов")
    end

    -- Проверка занятости портов
    for _, port in ipairs(ports) do
        local sock = socket.tcp()
        local is_busy = sock:connect('localhost', port)
        sock:close()
        if is_busy then
            error("Port " .. port .. " is already in use!")
        end
    end

    log.info("Запуск кластера с портами: " .. table.concat(ports, ", "))

    -- Инициализация списка серверов
    cluster.servers = {}

    -- Базовая директория для хранения данных серверов
    local instance_path = fio.pathjoin(fio.cwd(),"test", "helpers",'instance.lua')

    -- Создаем и запускаем серверы
    for i, port in ipairs(ports) do
        local alias = 'server-' .. i
        -- Изменено: уникальные директории для серверов
        local workdir = fio.pathjoin(datadir, 'server-' .. i)

        fio.mkdir(workdir)
        fio.mkdir(fio.pathjoin(workdir, 'wal'))
        fio.mkdir(fio.pathjoin(workdir, 'vinyl'))

        -- Создаем экземпляр сервера
        local server_config = {
            alias = alias,
            command = instance_path, -- путь к instance.lua
            workdir = workdir,
            args = {               -- Добавить аргументы командной строки
            '--wal-dir', fio.pathjoin(workdir, 'wal'),
            '--vinyl-dir', fio.pathjoin(workdir, 'vinyl')
            },
            advertise_port = tonumber(port),
            env = {
                TARANTOOL_LISTEN = tostring(port), },

            net_box_credentials = {
                user = 'guest',
                password = "",
            },
            cluster_cookie = ""

        }

        local server = Server:new(server_config)

        -- Добавляем сервер в список
        table.insert(cluster.servers, server)

        -- Запускаем сервер
        server:start()
        -- Добавлено: задержка между запуском серверов
        require('fiber').sleep(1)

        log.info("Запущен сервер " .. alias .. " на порту " .. port)
    end

    for _, server in ipairs(cluster.servers) do
        server:wait_until_ready({timeout = 120})
    end

    log.info("Кластер успешно запущен, количество серверов: " .. #cluster.servers)
    return true
end

-- Остановка всех серверов кластера
function cluster.stop()
    if cluster.servers == nil then
        log.warn("Кластер не был запущен")
        return
    end

    log.info("Останавливаем кластер...")

    -- Останавливаем все серверы
    for _, server in ipairs(cluster.servers) do
        server:stop()
        log.info("Остановлен сервер " .. server.alias)
    end

    -- Очищаем список серверов
    cluster.servers = nil

    log.info("Кластер успешно остановлен")
    return true
end

return cluster
