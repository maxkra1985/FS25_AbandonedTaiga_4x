# ContractRatingSystem — технический аудит (рабочий документ)

**Дата:** 2026-10-23. **Статус:** аудит начат, пункты 1.1–1.9 ещё не закрыты.  
**База:** [FUNCTIONAL_REQUIREMENTS.md](FUNCTIONAL_REQUIREMENTS.md) v1.1, [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md).  
**Исходники:** FS25 1.25.0.0 и новее. Ниже приведены только подтверждённые при чтении репозиториев наблюдения. Это **не завершённая архитектура**.

## A. Штатные контракты

Источники:
- [MissionManager.lua](https://github.com/maxkra1985/FarmingSimulator25_dataS/blob/main/scripts/missions/MissionManager.lua)
- [AbstractMission.lua](https://github.com/maxkra1985/FarmingSimulator25_dataS/blob/main/scripts/missions/AbstractMission.lua)

Подтверждено:

1. `MissionManager:registerMissionType(classObject, name, defaultMaxNumInstances)` регистрирует тип в `missionTypes` и `nameToMissionType` (MissionManager.lua:497). Путь загрузки XML классов — `loadMapData` (стр. 85 и далее).
2. `MissionManager:registerMission` назначает тип, регистрирует и публикует `MessageType.MISSION_GENERATED` (стр. 285–291); `addMission` обеспечивает уникальный ID (293–302).
3. `MissionManager:startMission` вызывается только на сервере, проверяет лимит фермы, `validate()`, доступный activeMissionId, присваивает `farmId`, вызывает `mission:start` и публикует `MissionStartedEvent` (317–349).
4. `MissionManager:cancelMission` вызывает `mission:finish(MissionFinishState.CANCELED)` (351–357).
5. `AbstractMission:finish` устанавливает `MissionStatus.FINISHED`, заполняет `finishState`, обновляет статистику успешной фермы, рассылает `MissionFinishedEvent` и публикует его в messageCenter (330–349). **Нужно проверить протокол подписки на событие, обработку клиентов и другие возможные пути завершения до реализации рейтинга.**
6. `AbstractMission:dismiss` выполняет `getTotalReward()` и на сервере начисляет `MoneyType.MISSIONS` (350–365). Значит **финансовое завершение отличается от установки FINISHED**.
7. `MissionManager:saveToXMLFile` сохраняет активные зарегистрированные миссии через их `saveToXMLFile`; `loadFromXMLFile` восстанавливает их с контролем `MissionManager.VERSION` (около 139–205). `AbstractMission` реализует базовые `registerSavegameXMLPaths`, `saveToXMLFile`, `loadFromXMLFile` (8–23, 78–154).
8. `MissionManager:getIsShapeCutAllowed(shape,x,z,farmId)` обходит активные миссии и делегирует проверку `mission:getIsShapeCutAllowed` (около 548–562). `getIsMissionDestructible` и `getIsMissionWorkAllowed` — другие потенциальные точки интеграции. Это **не доказывает**, что все инструменты рубки и уничтожения пней используют именно их.

**Решение на дальнейшую проверку:** для рейтинга использовать серверное завершение с отдельным журналом однократных операций, но не считать уже доказанной пригодность одного события для всех штатных типов миссий.

## B. Приём товаров и денежная операция

Источник: [SellingStation.lua](https://github.com/maxkra1985/FarmingSimulator25_dataS/blob/main/scripts/objects/SellingStation.lua).

1. `SellingStation:getIsFillTypeAllowed(fillTypeIndex, extraAttributes)` проверяет `acceptedFillTypes` (310–316).
2. `SellingStation:addFillLevelFromTool(farmId, deltaFillLevel, fillTypeIndex, fillInfo, toolType, extraAttributes)` обходит `self.missions`, ищет совпадающие `farmId` и `fillTypeIndex`, вызывает `mission:fillSold(deltaFillLevel)`. Далее в обычном сценарии возможен `sellFillType` (317–357).
3. `SellingStation:getStoreGoods` и `getSkipSell` по умолчанию возвращают `false` (359–364). Их переопределения конкретными точками **не проверены**.
4. `SellingStation:sellFillType` считает стоимость и перечисляет деньги вызовом `g_currentMission:addMoney(price, farmId, self.moneyChangeType, true)` (365–390).

**Следствие:** блокировка контрактного товара не может ограничиваться скрытием в UI. Нужна проверка реального пути выгрузки/продажи соответствующих `SellingStation` карты и согласование с механизмом `fillSold`, чтобы контрактная поставка работала, а обычная перепродажа на месте — нет.

**Не подтверждено:** идентификаторы трёх объектов карты; какой из них использует `SellingStation` и какие переопределения; специальный код мгновенной перепродажи. Поэтому пока нельзя утверждать, что достаточно одного hook на `getIsFillTypeAllowed`.

## C. Имеющиеся модули карты

Источники:
- [MissionTayga.lua](https://github.com/maxkra1985/FS25_AbandonedTaiga_4x/blob/main/scripts/MissionTayga.lua)
- [ConstructionLifecycle.lua](https://github.com/maxkra1985/FS25_AbandonedTaiga_4x/blob/main/scripts/constructionLifecycle/ConstructionLifecycle.lua)
- [ConstructionTriggerRegistry.lua](https://github.com/maxkra1985/FS25_AbandonedTaiga_4x/blob/main/scripts/constructionLifecycle/ConstructionTriggerRegistry.lua)
- [ConstructionFacilityLifecycle.lua](https://github.com/maxkra1985/FS25_AbandonedTaiga_4x/blob/main/scripts/constructionLifecycle/ConstructionFacilityLifecycle.lua)

1. `MissionTayga` наследуется от `Mission00` и загружает несколько файлов `scripts/loggingContractor/` через `MissionTayga.loadLoggingContractorModules` (19–42).
2. В `MissionTayga:onStartMission` после вызова базового метода создаётся `LoggingContractor`, вызываются `initialize()` и `loadFromSavegame()`. В `update` и `onConnectionsUpdateTick` предусмотрены серверные и сетевые шаги этого модуля; в `delete` предусмотрена его очистка.
3. `ConstructionLifecycle` даёт методы `getLifecycleState`, `isUnderConstruction`, `isFinished`, `getConstructionProgress`, `getCompletedPhaseNumber`, `isConstructionUnloadingStation`.
4. `ConstructionTriggerRegistry` регистрирует объекты и узлы станций/триггеров с назначением; `ConstructionFacilityLifecycle` управляет регистрацией строительных/производственных станций и взаимодействиями. Обнаружена логика `allowMissions`; её влияние на контракты надо изучить отдельно.
5. `modDesc.xml` карты содержит `sourceFile` для подсистем `constructionLifecycle`. Для нового модуля потребуется проверить безопасный порядок загрузки и жизненного цикла.

**Не подтверждено:** поддержка нужных событий и повторное использование функций `loggingContractor`, обработчики завершения стадий и восстановление стройки, фактические классы объектов дополнения.

## D. Оставшаяся программа аудита

- [ ] Найти исходники и конкретные типы стандартных миссий сухостоя, доставки, камней; проверить все пути завершения, не только `AbstractMission:finish`.
- [ ] Проверить три конкретные точки продажи на карте и реализацию мгновенной перепродажи, допустимые `fillType`, серверное блокирование обычной продажи.
- [ ] Проследить вызовы `getIsShapeCutAllowed`, пни, посадку, удаление деревьев, оценку литров и стадии роста.
- [ ] Проверить файл/классы farmland карты, способ невозможности покупки и временный доступ по видам действий.
- [ ] Построчно исследовать `loggingContractor` и строительный lifecycle, выявить безопасные точки повторного использования.
- [ ] Проверить стандартный GUI контрактов, сетевые Event и формат долговременной истории.
- [ ] По подтверждённым данным составить окончательную структуру классов, XML и список внедряемых hooks.
- [ ] Обновить [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md) только после выполнения пунктов и проверки результатов.

## E. Правила технического проектирования

- Не вводить новые hooks и не изменять `modDesc.xml` до проверки фактических мест интеграции.
- Не трактовать `finish` и `dismiss` как одно событие.
- Не предполагать, что запрет принятия товара и запрет продажи — одна и та же операция.
- Не предоставлять права владельца `farmland` в качестве универсального разрешения на контрактные работы.
- Все изменения рейтинга и денег учитывать по уникальной попытке без повторных проводок.

## F. Диагностика одного предложения сухостоя и перевозки (2026-10-23)

**Ситуация:** пользователь наблюдает по одному контракту обоих типов даже после принудительной генерации с Better Contracts.

Проверены пользовательский архив `FS25_BetterContracts.zip`, `map/map.xml`, `map/missions/deadwoodSpots.i3d`, `map/missions/transportSpots.i3d`, а также исходник [MissionManager.lua](https://github.com/maxkra1985/FarmingSimulator25_dataS/blob/main/scripts/missions/MissionManager.lua).

**Подтверждено:**
- В `map/map.xml` у `deadwoodMission` и `treeTransportMission` указано `maxNumInstances="10"`.
- В `deadwoodSpots.i3d` содержится **27** отдельных `TransformGroup name="spotN"` (1–27).
- В `transportSpots.i3d` содержится **14** `TransformGroup name="spotN"` (1–14).
- В `betterContracts.lua:549–576` Better Contracts повторно вызывает `missionType.classObject.tryGenerateMission()` и добавляет контракт только при ненулевом результате; при `config.genSingle=false` не переходит к следующему типу после каждого успешного вызова.
- `betterContracts.lua:440–462` содержит начальное значение `genSingle=false`; настройки конкретной сохранённой игры могут отличаться.
- В `betterContracts.lua:996–1005` при `self.extendedInfo` установлено **принудительное снижение** `data.maxNumInstances` до 2 для ряда не-полевых типов, в том числе `treeTransportMission` и `deadwoodMission`.
- `betterContracts.lua:1057–1079` изменяет общий интервал генерации и `MissionManager.MAX_MISSIONS`, но не гарантирует, что конкретный тип миссии имеет ещё доступные цели.
- Исходный `MissionManager:generateMission()` (стр. 259–283) сам вызывает `tryGenerateMission` соответствующего типа. Количество созданных заданий зависит от возвращаемых генератором миссий и лимитов.

**Что не доказано:** точная причина, по которой у пользователя возникает ровно одно предложение; наличие 27/14 spot-узлов не означает 27/14 допустимых контракта. Код конкретных `DeadwoodMission.tryGenerateMission` и `TreeTransportMission.tryGenerateMission` пока не найден по подтверждённым путям в репозитории исходников. Не следует заявлять, что дело наверняка в лимитах/расположении объектов/файле сохранения.

**Следующие целевые проверки:**
- [ ] Найти фактические пути классов deadwood/treeTransport в исходниках FS25 и изучить критерии `tryGenerateMission`, уникальность spot и счётчики.
- [ ] Проверить, какие `genSingle`, `genDead`, `genTree`, `extendedInfo` действуют в сохранении/на сервере.
- [ ] Получить серверный лог/диагностический вывод генератора при повторном вызове, если статический анализ не объяснит результат.
- [ ] Проверить места и конфликты spot на карте; сравнить число кандидатов с числом успешно созданных миссий.

**Вывод:** по одной миссии — не следствие числа размеченных spot (их больше), но однозначная причина на данном этапе не установлена.

## G. Сверка жизненного цикла и проект регистрации рейтинга (2026-10-23)

Основа — проверенные [MissionManager.lua](https://github.com/maxkra1985/FarmingSimulator25_dataS/blob/main/scripts/missions/MissionManager.lua#L317-L366) и [AbstractMission.lua](https://github.com/maxkra1985/FarmingSimulator25_dataS/blob/main/scripts/missions/AbstractMission.lua#L326-L365).

### Подтверждённый порядок

- `MissionManager:startMission(mission,farmId,spawnVehicles)` — серверный метод. **До** присвоения `mission.farmId` и `mission:start` он проверяет режим наблюдателя, лимит фермы, занятый `activeMissionId`, `PREPARING` и `mission:validate()`; затем присваивает active ID и farmId. При успешном старте публикует `MissionStartedEvent`.
- `MissionManager:cancelMission` — серверный метод: если миссия не в статусе FINISHED, вызывает `mission:finish(MissionFinishState.CANCELED)`. Для рейтинга не следует полагаться только на вызов `cancelMission`, поскольку другие пути могут завершать задание.
- `AbstractMission:finish(finishState)` — меняет статус на FINISHED, фиксирует `finishState`, снимает доступ при неуспехе, на сервере обновляет статистику успеха и отправляет `MissionFinishedEvent`; затем локально публикует сообщение `g_messageCenter:publish(MissionFinishedEvent,self,finishState)`.
- `AbstractMission:dismiss()` переводит в DISMISSED и **на сервере** перечисляет результат `getTotalReward()` по `MoneyType.MISSIONS`. `MissionManager:dismissMission` вызывает `dismiss()`, затем `delete()`.
- `MissionManager:registerMissionType(classObject,name,defaultMaxNumInstances)` регистрирует тип и устанавливает **по умолчанию 2 экземпляра**. Для собственных типов нужен явный лимит и проверка генератора.
- `MissionManager:saveToXMLFile` пишет через `mission:saveToXMLFile` весь текущий список; `loadFromXMLFile` восстанавливает с проверкой `MissionManager.VERSION`. **Удалённые** контракты не могут оставаться единственным источником полного журнала.

### Следствия для архитектуры (предложения, не реализованный код)

1. **Порог рейтинга проверять сервером на пути принятия до `mission:start`**. Важно определить корректное отображение отказа клиенту: прямой `MissionManager:startMission` возвращает `MissionStartState`; нельзя без аудита возвращать неизвестную enum-константу. Для своей миссии возможно встроить проверку в `validate()`, но надо проверить, не вызовет ли это преждевременное удаление предложения при отказе по рейтингу.
2. **Рейтинг начислять по окончательному finishState только на сервере**, фиксировать уникальный ключ операции `attemptId + result`, не повторять при событии/загрузке.
3. **Финансовую модель миссий отделить от рейтинга**: при `dismiss` штатная логика перечисляет `getTotalReward()`; для кастомных поставок возврат товара, компенсация и премия должны быть согласованы с этим штатным платёжным путём без двойного начисления.
4. Историю закрытых/удалённых попыток и рейтинг сохранять **самостоятельным долговременным журналом**, а не только в `missions.xml`; уникальные ID и восстановление из savegame.
5. Подключение клиентов: `MessageCenter` публикация на сервере сама по себе не равна надёжной репликации журнала; создать явный начальный snapshot и события изменений, после изучения сетевого lifecycle карты.
6. Зафиксировать наличие всех трёх штатных типов в `map/map.xml`: `deadwoodMission`, `treeTransportMission`, `destructibleRockMission`. События их результатов следует проверить на фактических классах до закрытия задачи 1.2.

### Блокирующие неизвестные

- [ ] Неизвестны точные штатные способы отказа в принятии по рейтингу без удаления предложения.
- [ ] Не подтверждена идентичность ID попытки при последовательных реинициализациях и переходе FINISHED → DISMISSED.
- [ ] Не проверены конкретные классы и окончания всех трёх встроенных типов.
- [ ] Не проверен формат регистраций XML-схемы и способ вызова savegame-hooks для дополнительного независимого журнала.
- [ ] Не проведены игровые и MP тесты.

**Этап 1 остаётся в работе; ничего из этого не следует выдавать за реализованный рейтинг.**

## H. Проверка рейтингового допуска в сетевом маршруте принятия (2026-10-24)

Проверены следующие штатные файлы:
- [InGameMenuContractsFrame.lua](https://github.com/maxkra1985/FarmingSimulator25_dataS/blob/main/scripts/gui/InGameMenuContractsFrame.lua#L379-L430)
- [MissionStartEvent.lua](https://github.com/maxkra1985/FarmingSimulator25_dataS/blob/main/scripts/missions/events/MissionStartEvent.lua)
- [MissionStartState.lua](https://github.com/maxkra1985/FarmingSimulator25_dataS/blob/main/scripts/missions/MissionStartState.lua)
- [MissionManager.lua](https://github.com/maxkra1985/FarmingSimulator25_dataS/blob/main/scripts/missions/MissionManager.lua#L317-L366)
- [MissionFinishedEvent.lua](https://github.com/maxkra1985/FarmingSimulator25_dataS/blob/main/scripts/missions/events/MissionFinishedEvent.lua)
- [MissionFinishState.lua](https://github.com/maxkra1985/FarmingSimulator25_dataS/blob/main/scripts/missions/MissionFinishState.lua)

### Реальная последовательность принятия

1. Клиентский `InGameMenuContractsFrame:startContract` передаёт выбранную миссию, `farmId`, флаг аренды транспорта через `MissionStartEvent.new`.
2. `MissionStartEvent:run(connection)` на сервере определяет пользователя по соединению, проверяет право `manageContracts` и вызывает `g_missionManager:startMission(self.mission, self.farmId, self.spawnVehicles)`.
3. `MissionManager:startMission` требует выполнения на сервере, проверяет ограничения, затем выполняет `mission:validate()`. **Если validate возвращает false, миссия удаляется** и ответом становится `MissionStartState.NOT_AVAILABLE_ANYMORE`.
4. После запуска сервер посылает `MissionStartEvent.newServerToClient(startState, spawnVehicles)`; GUI показывает диалог по перечислению `MissionStartState`.

### Установленные ограничения

- В `MissionStartState` существует только восемь значений: `OK`, `LIMIT_REACHED`, `ALREADY_STARTED`, `NOT_AVAILABLE_ANYMORE`, `NO_ACCESS`, `CANNOT_BE_STARTED_NOW`, `PENDING_MISSION`, `NO_PERMISSION`. **Специального значения «недостаточно рейтинга» нет**.
- Следовательно, нельзя реализовывать рейтинговый отказ через `mission:validate() == false`: штатный менеджер удалит само предложение.
- Также нельзя без изменения штатного enum отправлять новый, произвольный `MissionStartState`. Безопаснее перехватить серверный путь **до вызова** `MissionManager:startMission`, передать поддерживаемый `CANNOT_BE_STARTED_NOW` и дополнительно синхронизировать требуемый/фактический рейтинг своим событием либо заранее показать причину клиенту. Точную схему пользовательского сообщения и повторных сетевых отказов необходимо определить после аудита событий.
- Серверный `MissionStartEvent:run` проверяет permission для `senderFarm.farmId`, но вызывает менеджер с `self.farmId`, переданным клиентом. Это **наблюдаемая разница аргументов**, не подтверждённый эксплойт; при интеграции своего контроля рейтинга идентификатор фермы следует брать из проверенного контекста соединения, а не доверять одному клиентскому `farmId`.

### Сохранение и результат

- `MissionManager:saveToXMLFile` сохраняет список миссий, `loadFromXMLFile` восстанавливает их по зарегистрированным типам, проверяя версию. Отдельная история рейтинга и удалённых попыток требует собственного сериализуемого состояния; точный savegame-hook в `MissionTayga` ещё проверяется.
- `MissionFinishState` различает `SUCCESS`, `FAILED`, `TIMED_OUT`, `CANCELED`; для рейтинга не следует объединять успех, отмену и истечение времени. `MissionFinishedEvent:run` на клиенте вызывает `self.mission:finish(self.finishState)`, что повторно публикует локальное сообщение об окончании. **Начислять рейтинг должен только сервер**, даже если UI наблюдает событие на клиенте.

### Предлагаемый следующий шаг

1. Найти штатные точки `Mission00` сохранения/загрузки, события savegame и жизненный цикл карты; выбрать место для отдельного журнала.
2. Сверить корректность привязки фермы к соединению и способ сообщать причину отказа, не ломая стандартную сетевую обработку.
3. Только после этого создавать код ядра; рабочее серверное правило допуска обязательно покрыть тестом сохранения предложения и повторной попытки после повышения рейтинга.

**Статус:** подтверждено по исходникам, не испытано на выделенном сервере.
