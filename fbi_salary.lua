require "lib.moonloader"
require "sampfuncs"
local sampev   = require "samp.events"
local encoding = require "encoding"

encoding.default = "CP1251"
local u8 = encoding.UTF8

local DLG_MENU = 1214
local DLG_LIST = 3869
local DLG_EDIT = 3879

local MENU_ITEM_LABEL    = "Изменить зарплаты"
local MENU_ITEM_FALLBACK = 4

local DELAY          = 450
local TIMEOUT_SERVER = 8000
local TIMEOUT_USER   = 30000

local PREFIX = "{4DA6FF}[FBI Salary]{FFFFFF} "

local RANKS = {
    "Стажёр", "Испытательный агент", "Младший агент", "Агент",
    "Старший агент", "Специальный агент", "Оперативный агент",
    "Куратор", "Заместитель Директора", "Директор",
}

local LABEL_STD  = u8:decode("Стандартная зарплата")
local LABEL_MAX  = u8:decode("Максимальная возможная зарплата")
local LABEL_MENU = u8:decode(MENU_ITEM_LABEL)

local st = {
    active  = false,
    mode    = nil,
    rank    = 0,
    phase   = "idle",
    token   = 0,
    sending = false,
}

local function say(text)
    sampAddChatMessage(PREFIX .. u8:decode(text), -1)
end

local function reset()
    st.active  = false
    st.mode    = nil
    st.rank    = 0
    st.phase   = "idle"
    st.sending = false
    st.token   = st.token + 1
end

local function abort(reason)
    reset()
    say("Остановлено: " .. reason)
end

local function finish()
    reset()
    say("Готово!")
end

local function setPhase(phase)
    st.phase = phase
    st.token = st.token + 1
    return st.token
end

local function alive(token)
    return st.active and st.token == token
end

local function armTimeout(token, ms, reason)
    lua_thread.create(function()
        wait(ms)
        if alive(token) then
            abort(reason)
        end
    end)
end

local function sendResponse(id, button, list, input)
    st.sending = true
    sampSendDialogResponse(id, button, list, input)
    st.sending = false
end

local function parseMoney(text, label)
    local clean = (text:gsub("{%x%x%x%x%x%x}", ""))
    local _, e = clean:find(label, 1, true)
    if not e then return nil end
    local line = clean:match("^[^\r\n]*", e + 1) or ""
    local digits = line:match("(%d[%d%.%s,]*)")
    if not digits then return nil end
    return tonumber((digits:gsub("%D", "")))
end

local function findMenuIndex(text)
    if not text or text == "" then
        return MENU_ITEM_FALLBACK
    end
    local clean = (text:gsub("{%x%x%x%x%x%x}", ""))
    local i = 0
    for line in clean:gmatch("[^\r\n]+") do
        if line:find(LABEL_MENU, 1, true) then
            return i
        end
        i = i + 1
    end
    return nil
end

local function processMenu(text)
    local idx = findMenuIndex(text)
    if not idx then
        abort("в меню не найден пункт «" .. MENU_ITEM_LABEL .. "»")
        return
    end

    local token = setPhase("busy_menu")
    lua_thread.create(function()
        wait(DELAY)
        if not alive(token) then return end

        local token2 = setPhase("wait_list")
        sendResponse(DLG_MENU, 1, idx, "")
        armTimeout(token2, TIMEOUT_SERVER, "сервер не открыл список рангов после меню")
    end)
end

local function processList()
    if st.rank >= #RANKS then
        finish()
        return
    end

    local token = setPhase("busy_list")
    lua_thread.create(function()
        wait(DELAY)
        if not alive(token) then return end

        local rank   = st.rank
        local token2 = setPhase("wait_edit")
        sendResponse(DLG_LIST, 1, rank, "")
        armTimeout(token2, TIMEOUT_SERVER, "сервер не открыл диалог зарплаты")
    end)
end

local function processEdit(text)
    local label  = (st.mode == "max") and LABEL_MAX or LABEL_STD
    local salary = parseMoney(text, label)
    if not salary then
        abort("не удалось прочитать зарплату из диалога")
        return
    end

    local token = setPhase("busy_edit")
    lua_thread.create(function()
        wait(DELAY)
        if not alive(token) then return end

        local rank = st.rank
        sendResponse(DLG_EDIT, 1, 0, tostring(salary))
        say(("Ранг %d/%d (%s): %s"):format(
            rank + 1, #RANKS, RANKS[rank + 1], tostring(salary)))

        st.rank = rank + 1
        if st.rank >= #RANKS then
            finish()
        else
            local token2 = setPhase("wait_list")
            armTimeout(token2, TIMEOUT_SERVER, "сервер не вернул список рангов")
        end
    end)
end

local function start(mode)
    if st.active then
        say("Процесс уже запущен. Остановить: /set_fbi_stop")
        return
    end

    st.active = true
    st.mode   = mode
    st.rank   = 0
    say(mode == "max"
        and "Старт: максимальные зарплаты."
        or  "Старт: стандартные зарплаты.")

    local curId = sampIsDialogActive() and sampGetCurrentDialogId() or nil
    if curId == DLG_LIST then
        st.phase = "wait_list"
        processList()
    elseif curId == DLG_MENU then
        st.phase = "wait_list"
        processMenu(sampGetDialogText())
    else
        local token = setPhase("wait_list")
        say("Откройте меню организации или список рангов.")
        armTimeout(token, TIMEOUT_USER, "диалог не был открыт")
    end
end

function sampev.onShowDialog(id, style, title, button1, button2, text)
    if not st.active then return end

    if id == DLG_MENU then
        if st.phase ~= "wait_list" then
            abort("неожиданный диалог меню организации")
            return
        end
        processMenu(text)
        return false
    end

    if id == DLG_LIST then
        if st.phase ~= "wait_list" then
            abort("неожиданный диалог списка рангов")
            return
        end
        processList()
        return false
    end

    if id == DLG_EDIT then
        if st.phase ~= "wait_edit" then
            abort("неожиданный диалог редактирования зарплаты")
            return
        end
        processEdit(text)
        return false
    end

    abort("открылся другой диалог (ID " .. tostring(id) .. ")")
end

function sampev.onSendDialogResponse(id, button, list, input)
    if st.active and not st.sending
       and (id == DLG_MENU or id == DLG_LIST or id == DLG_EDIT) then
        abort("диалог закрыт вручную")
    end
end

function main()
    while not isSampAvailable() do wait(100) end

    sampRegisterChatCommand("set_fbi_max", function() start("max") end)
    sampRegisterChatCommand("set_fbi_min", function() start("min") end)
    sampRegisterChatCommand("set_fbi_stop", function()
        if st.active then
            abort("отменено командой /set_fbi_stop")
        else
            say("Скрипт сейчас ничего не делает.")
        end
    end)

    say("Загружен. Команды: /set_fbi_max, /set_fbi_min, /set_fbi_stop")
    wait(-1)
end
