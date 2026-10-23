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
