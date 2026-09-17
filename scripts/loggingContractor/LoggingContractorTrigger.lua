--[[
    LoggingContractorTrigger

    Модуль триггера подрядчиков на лесоповал.

    В дальнейшем модуль будет отвечать за:
    - привязку к trigger-node карты с атрибутом loggingContractor=true;
    - добавление действия по кнопке R через ActivatableObjectsSystem;
    - проверку доступности действия для локального игрока и его фермы;
    - открытие LoggingContractorDialog при активации.
]]

LoggingContractorTrigger = {}
