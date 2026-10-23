# Аудит точек приёма продукции — проход 2026-10-23

Статус: **частичный**, пока не проверен весь путь выгрузки и мгновенной перепродажи. Это приложение к [TECHNICAL_DESIGN.md](TECHNICAL_DESIGN.md).

## Подтверждённая конфигурация карты

В [config/placeables.xml](https://github.com/maxkra1985/FS25_AbandonedTaiga_4x/blob/main/config/placeables.xml), строки 87–93, имеются:

- `preplaced_sellingStationProducts_9dd6c026f17646e284165d259581c97e`
- `preplaced_sellingStationProducts_0ca796a1ab8114513d99adfe983259f8a`
- `preplaced_RailBulkSellPoint_22b676c5d05843409adca29b40ca3845`, `canBeSold="false"`, `farmId="100"`
- `preplaced_sellingStationWood_6b9aa86c9073c3ef85c004cc8eb3b327`, `canBeSold="false"`, `farmId="100"`
- `map/placeables/PalletBuyingStation/warehouseLogisticUS.xml`, отдельный placed object.

В [warehouseLogisticUS.xml](https://github.com/maxkra1985/FS25_AbandonedTaiga_4x/blob/main/map/placeables/PalletBuyingStation/warehouseLogisticUS.xml) на строке ~66 объявлен `palletBuyingStation`, с `fillType` в ~67–148, среди которых `INSTRUMENT`, `PLYWOOD`, `METAL`, `BOARDS`, `PLANKS`, `WOODBEAM`, `PREFABWALL` и множество других. **Этот объект не является обычной SellingStation.**

Важно: `config/placeables.xml` содержит ещё две точки `sellingStationProducts`, не следует объявлять их несуществующими либо исключать из кода, пока не установлено их предназначение.

## Взаимодействие с DinamycalPrice

В [scripts/DinamycalPrice.lua](https://github.com/maxkra1985/FS25_AbandonedTaiga_4x/blob/main/scripts/DinamycalPrice.lua):

- `getBuyingStationsForPlaceable` (~604) ищет BuyingStation в том числе через `storageSystem`.
- `capturePalletBuyingStationPriceScales` (~855) фиксирует настройки priceScale; `onPalletBuyingStationLoaded` (~914) работает после загрузки объекта.
- `overwrittenSellingStationEffectivePrice` (~1237) и `overwrittenBuyingStationEffectivePrice` (~1250) меняют расчёт цен.
- В ~1876–1891 устанавливаются hooks на `SellingStation.getEffectiveFillTypePrice` и `BuyingStation.getEffectiveFillTypePrice`.
- В ~1958–1966 установлен `PlaceablePalletBuyingStation.onLoad` hook; есть корректировка отображения цены поддонов за 1000 л.

**Вывод:** новую систему не следует внедрять через замену или переподключение ценовых hooks. Нужна независимая серверная проверка факта приёмки, режима продажи и идентификаторов точки/товара/фермы, совместимая с работающим DinamycalPrice.

## Проверенные исходники GIANTS

В [SellingStation.lua](https://github.com/maxkra1985/FarmingSimulator25_dataS/blob/main/scripts/objects/SellingStation.lua) `addFillLevelFromTool` (~317) имеет штатную логику `self.missions` и `fillSold`; обычный `sellFillType` (~365) начисляет деньги. **Этот путь нельзя без проверки переносить на PalletBuyingStation.**

## Следующие задачи

- [ ] Найти XML конфигурации `sellingStationWood` и `RailBulkSellPoint` и подтвердить их реальные классы/триггеры.
- [ ] Проверить, что означает каждая из двух `sellingStationProducts` и не затрагивают ли они контрактный товар.
- [ ] Найти `PlaceablePalletBuyingStation` и связанные скрипты выгрузки/покупки поддонов в исходниках 1.25.0.0.
- [ ] По вызовам проследить мгновенную покупку и выгрузку поддона на скупщике; исключить кредитование до принятия контрактного объёма.
- [ ] Проверить, может ли товар, запрещённый для обычной продажи, продолжать выгружаться в рамках миссии, и определить точные хуки для каждой специализации точки.
- [ ] Уточнить, какие ограничения работают для всех ферм, а какие должны применяться адресно по `farmId`.

**Пока не отмечать пункт 1.3 плана завершённым:** конфигурация точек найдена, пути приёмки и продаж не исследованы полностью.

## Прямое сравнение с тремя загруженными модами поставок

Источники: пользовательские архивы `FS25_SupplyTransportContracts.zip`, `FS25_Pallet_delivery_contracts.zip`, `FS25_Longtermcontracts.zip`.

### SupplyTransportContracts

- `scripts/missions/SupplyTransportMission.lua:487–498`: при старте миссия регистрируется в `sellingStation.missions[self]`; при `finish` удаляется (501–504).
- `fillSold(delta)` (549–559): учитывает `depositedLiters`, ограничивает объём `expectedLiters`, затем отвязывает миссию от станции. Штатная `SellingStation:addFillLevelFromTool` уже содержит путь приёмки миссии. **Проверить реальный зачтённый литраж:** в этом пути передаётся исходный delta до окончательного определения accepted volume; для нашей реализации нельзя считать точность доказанной.
- `onSavegameLoaded` (~366–372): восстанавливает `sellingStation.missions`; useful pattern для восстановления активного контракта, не копировать экономику/динамические цены.
- `dismiss` (531–542): самостоятельное начисление денег, не переносить вместе с базовым `AbstractMission:dismiss` без проверки во избежание двойной выплаты.

### Pallet_delivery_contracts

- `PalletDeliveryMission.lua:787–820`: `matchesStationDelivery` сверяет fillType и реальную `SellingStation` либо persistent placeableUniqueId + индекс разгрузочной станции.
- `onStationSold` (823–834) дополнительно проверяет `farmId`; `fillSold` (774–785) ведёт `deliveredLiters` и сетевой dirty flag.
- `installHooks` (1111–1146) перехватывает `UnloadTrigger.addFillUnitFillLevel`, вызывает оригинал и учитывает возвращённый **фактически принятый** объём. Для подавления обычной оплаты устанавливает `_suppressMoneyForFarmId` и перехватывает глобальный `FSBaseMission.addMoney`.
- `PalletUnloadTrigger.unloadPallets` (1149+) переписан дополнительным overwritten-hook с обходом поддонов, доступом, дополнительно оплачиваемой частью, фактическим вычитанием `used` и удалением пустого поддона. Это **высокорисковое вмешательство**: нельзя без проверки копировать в ContractRatingSystem.
- Глобальный флаг подавления оплаты **только по farmId** слишком широк: при новой разработке скоуп должен учитывать `stationId + fillTypeIndex + farmId + активный contractId` и реальный контекст разгрузки; блокировка покупки в магазине поддонов решает другую задачу.

### Longtermcontracts

- `scripts/main.lua:62–84`: перехват `UnloadingStation.addFillLevelFromTool`, оригинал вызывается первым, возвращённый `movedFillLevel` используется для зачёта и возвращается неизменным. Обработчик отделяет производственные станции от selling point.
- Демонстрирует критичность **не терять возвращаемый объём** при интеграции и не вызывать `fillSold` для продукции, фактически не принятой.

### Существенное уточнение: PalletBuyingStation является магазином

Источник: [PlaceablePalletBuyingStation.lua](https://github.com/maxkra1985/FarmingSimulator25_dataS/blob/main/scripts/placeables/specializations/PlaceablePalletBuyingStation.lua).

- `openShop` (116–122) открывает **магазин покупки поддонов**; `shopCallback` (124–152) отправляет клиентское событие покупки; `tryToSpawnPallets` (154–176) создаёт товар игроку.
- XML `warehouseLogisticUS.xml` описывает ассортимент **продажи игроку**, а не приёмку его поддонов.
- [PlaceablePalletBuyEvent.lua](https://github.com/maxkra1985/FarmingSimulator25_dataS/blob/main/scripts/placeables/specializations/events/PlaceablePalletBuyEvent.lua): в `run(connection)` сервер непосредственно вызывает `tryToSpawnPallets` и списывает `palletPrice*numBoughtPallets`; `palletPrice` передаётся клиентом. Простой запрет в UI обходится прямым событием покупки.
- Для запрета покупки контрактного `fillType` нужна **серверная проверка перед созданием поддонов**, независимо от клиентского окна. Требуется выбрать конкретную безопасную точку интеграции, не затрагивая глобально цены `DinamycalPrice`.
- Сама сдача продукции по контракту относится к **отдельной точке приёма** (`SellingStation`/другому unloading path), которая пока не установлена для каждого товара. Магазин покупки и станция продажи игроком — **разные объекты/операции**. Для древесины и сыпучих товаров также проверить, действительно ли существует покупка товара на месте: нельзя переносить запрет магазина поддонов на приёмные станции.

### Текущее направление архитектуры

1. Отдельный **проверяемый сервером запрет покупки** заблокированного `fillType` на доступных магазинах товаров, если он совпадает с товаром предложения.
2. Отдельный **обработчик контрактной сдачи**, который подтверждает ферму, точку, товар и фактический принятый объём; не перехватывает систему динамического ценообразования.
3. Отдельный расчёт денег **по базовой цене + премия**, согласно `FUNCTIONAL_REQUIREMENTS.md`, без зависимости от `DinamycalPrice`.
4. Синхронизация ассортимента в клиентском UI дополнительно к обязательному запрету на сервере.
5. Финальный выбор hook после трассировки `PalletShopDialog`, `PlaceablePalletBuyEvent`, `UnloadTrigger`, `PalletUnloadTrigger` и реальных точек продажи карты.

**Статус:** статический аудит исходников, не проверено выполнением в игре. Пункты 1.3–1.4 плана пока открыты.

## Согласованное поведение заблокированного товара (2026-10-23)

- **Сразу после генерации предложения** соответствующий товар запрещён к покупке в точке, через которую возможна перепродажа; принятие контракта не является условием блокировки.
- При попытке купить такой товар показывать локализованное сообщение **«Извините, товар закончился. Попробуйте позже.»**. Товар разрешается оставлять видимым в меню, вместо скрытия без объяснения.
- Сервер обязан отклонить покупку **до создания товара и списания денег**, включая прямой сетевой запрос. Клиентское предупреждение само по себе недостаточно.
- Контрактная сдача продукции и обычные покупки иных товаров не должны блокироваться.
- При истечении/отмене/удалении предложения снять запрет, если другого актуального контракта на этот товар нет. Детали скоупа по магазинам требуют дополнительной трассировки.
- Для `PlaceablePalletBuyingStation` в исходниках проверен путь `PlaceablePalletBuyEvent:run` → `tryToSpawnPallets`; точное место безопасной серверной проверки ещё предстоит выбрать.

## Аудит серверной покупки: отдельные маршруты (2026-10-23)

Источники (проверены непосредственно в исходниках FS25):
- [BuyingStation.lua](https://github.com/maxkra1985/FarmingSimulator25_dataS/blob/main/scripts/objects/BuyingStation.lua#L87-L116)
- [PlaceablePalletBuyingStation.lua](https://github.com/maxkra1985/FarmingSimulator25_dataS/blob/main/scripts/placeables/specializations/PlaceablePalletBuyingStation.lua#L116-L176)
- [PlaceablePalletBuyEvent.lua](https://github.com/maxkra1985/FarmingSimulator25_dataS/blob/main/scripts/placeables/specializations/events/PlaceablePalletBuyEvent.lua#L1-L64)

### A. Покупка сыпучего товара через BuyingStation

`BuyingStation:addFillLevelToFillableObject(fillableObject, fillUnitIndex, fillTypeIndex, fillDelta, fillInfo, toolType)` (стр. 96–116):
1. Получает `farmId` из `fillableObject:getOwnerFarmId()`.
2. Добавляет товар в транспорт через `fillableObject:addFillUnitFillLevel(...)`.
3. Лишь **после успешного добавления** начисляет отрицательную денежную операцию через `g_currentMission:addMoney(-price,...)`.

Следовательно, для серверного запрета нельзя ждать `addMoney`: товар уже был выдан. Проверку необходимости блокировать покупку нужно помещать **до** вызова исходного `addFillLevelToFillableObject`. Требуется выяснить конкретные `BuyingStation` карты, где покупка в принципе возможна, и проверить возможные альтернативные способы пополнения.

### B. Покупка поддонов в магазине

`PlaceablePalletBuyingStation:shopCallback` отправляет `PlaceablePalletBuyEvent.new(placeable,farmId,fillTypeIndex,quantity,pallet.price)` (стр. 124–150).

`PlaceablePalletBuyEvent:run` на сервере (стр. 49–62) вызывает `placeable:tryToSpawnPallets(...)`, затем списывает `self.palletPrice * numBoughtPallets`. То есть **запрет должен сработать до `tryToSpawnPallets`**, не после; отображение сообщения только в клиентском меню недостаточно.

**Дополнительное важное наблюдение:** событие сериализует `palletPrice`, `farmId`, `fillTypeIndex` и `quantity`, полученные от клиента; серверная ветка приведённого `run` непосредственно использует эти поля. Это требует отдельно проверить защиту цены и полномочий при покупке, не полагаться на клиентские аргументы и не вносить изменения в базовый движок без проверки всей цепочки. Речь о видимом коде `run`, а не о доказанном эксплойте на живом сервере.

### C. Общий принцип блокировки

1. Контрактный реестр блокировок строится по **актуальным предложениям и активным контрактам**, начиная с генерации, а не с принятия.
2. Проверка покупки выполняется **на сервере до выдачи товара**; при отказе ни товар, ни деньги не изменяются.
3. Клиент получает сообщение «Извините, товар закончился. Попробуйте позже.»; нужен сетевой сигнал об отказе, соответствующий фактическому пути покупки.
4. Не перехватывать `getEffectiveFillTypePrice` и не изменять работу `DinamycalPrice`; контрактный расчёт идёт отдельно от базовой цены.
5. Проверка `fillType` должна затрагивать только товары, фактически указанные в актуальных контрактах; место торговли / область действия блокировки уточняется при инвентаризации всех buying points.
6. Выгрузка по контракту является другой операцией: она должна оставаться доступна и учитывать фактически принятый объём.

### D. Оставшиеся проверки

- [ ] Найти точные файлы XML и классы станции покупки сыпучей продукции и продажи древесины на карте; исследовать, можно ли вообще купить древесину на указанных точках.
- [ ] Подтвердить, что пользовательское сообщение передаётся инициировавшему покупку игроку и что отказ корректен для выделенного сервера.
- [ ] Определить безопасный hook до выдачи поддонов, не меняющий поведение остальных магазинов, и способы отследить клиента/ферму.
- [ ] Провести сопоставление стандартных `PalletUnloadTrigger` и `UnloadTrigger` с продающими станциями карты для зачёта реальных литров.
- [ ] Протестировать покупку, отказ, логирование и переподключение в FS25; статическое чтение само по себе не подтверждает работоспособность.

**Вывод:** требуются как минимум два различных обработчика покупки: для `BuyingStation` и для `PlaceablePalletBuyingStation`. Нельзя заменить их одной клиентской проверкой или одним hook на расчёт цены.

## Уточнение реальных объектов карты и потоков (2026-10-23)

### Элеватор Степаныча — подтверждённый приём сыпучих грузов

Источник: [map/placeables/RailBulkSellPoint/RailBulkSellPoint.xml](https://github.com/maxkra1985/FS25_AbandonedTaiga_4x/blob/main/map/placeables/RailBulkSellPoint/RailBulkSellPoint.xml#L78-L84).

- Объект объявлен как `<placeable type="sellingStation">` (стр. 2), содержит `<sellingStation>` (стр. 78), `<unloadTrigger exactFillRootNode="unloadTrigger" ...>` (стр. 79) и `<baleTrigger>` (стр. 80).
- Допускаются не только зерновые: в списке есть `WOODCHIPS`, `SILAGE`, `GRASS`, `STONE`, `FERTILIZER`, `LIME` и другие. Для контрактной категории «сыпучие» нужен **явный список разрешённых fillType из XML**, а не простая проверка возможности выгрузки в данный триггер.
- Маршрут приёмки должен быть совместим со штатным [SellingStation.lua](https://github.com/maxkra1985/FarmingSimulator25_dataS/blob/main/scripts/objects/SellingStation.lua#L317-L390), включая `self.missions`/`fillSold`. Ещё предстоит проверить конкретные объекты unload trigger и точное подтверждение количества принятых литров.

### Склад Семёныча — подтверждённый магазин поддонов

Источник: [map/placeables/PalletBuyingStation/warehouseLogisticUS.xml](https://github.com/maxkra1985/FS25_AbandonedTaiga_4x/blob/main/map/placeables/PalletBuyingStation/warehouseLogisticUS.xml#L1-L15), [секция palletBuyingStation](https://github.com/maxkra1985/FS25_AbandonedTaiga_4x/blob/main/map/placeables/PalletBuyingStation/warehouseLogisticUS.xml#L66-L148).

- Описание объекта прямо называет его «Место покупки различных товаров», а код специализации `PlaceablePalletBuyingStation` создаёт покупаемые поддоны.
- **Это не доказательство наличия здесь точки СДАЧИ поддонов.** Скупщик паллет из функциональных требований должен быть найден отдельно среди `sellingStationProducts` или других продающих объектов карты; соответствие пока неизвестно.
- Для предотвращения перепродажи требуется блокировать **покупку** совпадающего `fillType` через этот магазин до создания поддона, сохраняя контрактную сдачу в реальную selling station.

### Покупка сыпучих товаров

Источник: [BuyingStation.lua](https://github.com/maxkra1985/FarmingSimulator25_dataS/blob/main/scripts/objects/BuyingStation.lua#L96-L116).

- `BuyingStation:addFillLevelToFillableObject` добавляет литры в транспорт до списания денег. Запрет покупки требуется проверять до вызова исходной операции.
- Элеватор Степаныча объявлен как **SellingStation**, не **BuyingStation**. Сам по себе этот элеватор не подтверждён как место покупки зерна. Запрет покупки сыпучего контрактного товара нужно применять к фактическим продающим игроку BuyingStation, которые ещё предстоит установить.

### Что пока не удалось установить

- Конкретный XML объекта `sellingStationWood` по записи preplaced в `config/placeables.xml`; предполагаемые пути не подтверждены.
- Обе `sellingStationProducts` и их связь с приёмом поддонов.
- Реальный метод приёма поддона и подтверждения принятого литража именно на карте.
- Достаточность одного hook для серверной блокировки магазина поддонов, включая корректный сетевой ответ игроку.

**Решение:** не реализовывать блокировку продажи на самом элеваторе как замену блокировке ПОКУПКИ товара. Это два разных направления передачи продукции, и запрет продажи разрушил бы выполнение контракта. Следующий шаг — получить реестр preplaced из map.i3d/конфигураций объектов, установить точные XML по uniqueId и проследить unloading path.

## Выгрузка поддонов: фактическая цепочка в штатном FS25 (2026-10-23)

Прочитаны [PalletUnloadTrigger.lua](https://github.com/maxkra1985/FarmingSimulator25_dataS/blob/main/scripts/triggers/PalletUnloadTrigger.lua#L64-L116) и [UnloadTrigger.lua](https://github.com/maxkra1985/FarmingSimulator25_dataS/blob/main/scripts/triggers/UnloadTrigger.lua#L125-L142).

1. `PalletUnloadTrigger:update()` на сервере запускает `unloadPallets()` при наличии поддонов в зоне; действие также вызывается из callback триггера.
2. `unloadPallets(farmId)` проверяет доступ к поддону, затем наличие допустимого `fillType`, количество в fillUnit и условия динамического крепления.
3. При наличии `getPalletUnloadTriggerExtraSellPrice` и `target.moneyChangeType` **до приёмки** может быть отдельно начислен бонус за поддон — потенциальный канал двойной оплаты в контрактной поставке.
4. Фактическая передача происходит через `used = self:addFillUnitFillLevel(pallet:getOwnerFarmId(), fillUnitIndex, fillLevel, fillTypeIndex, ToolType.UNDEFINED)`; ровно `used` вычитается из поддона. Пустой поддон удаляется.
5. `UnloadTrigger:addFillUnitFillLevel` вызывает `target:addFillLevelFromTool` и возвращает реально заявленное целевым объектом количество; **при конвертации fillType** возвращает `applied / ratio`. Это означает необходимость учитывать преобразование единиц/типов при зачёте поставки.
6. Следовательно, при контрактной поставке необходимо отдельно гарантировать: зачёт принятого количества, отсутствие промежуточных обычных продаж и дополнительных денежных начислений, сохранение штатного удаления/разгрузки поддонов, корректность MP.

### Существенный вопрос о текущем SellingStation.lua

В [SellingStation.lua:317–357](https://github.com/maxkra1985/FarmingSimulator25_dataS/blob/main/scripts/objects/SellingStation.lua#L317-L357) вызов `mission:fillSold(deltaFillLevel)` расположен **до** формирования `movedFillLevel`. При этом `movedFillLevel` присваивается только внутри ветки `if storeGoods then`, а базовый `getStoreGoods` (стр. 359–361) возвращает `false`. Буквальное прочтение этого файла означает, что прямой `SellingStation` по умолчанию возвращает 0, хотя миссии может засчитываться `deltaFillLevel`. Это нетривиальное расхождение: **нельзя считать фактическую выгрузку доказанной по одному этому файлу**. Требуется проверить наследование/переопределения, реальный runtime и соответствие восстановленных исходников установленной версии игры. Ни в коем случае не копировать этот фрагмент без проверки.

### Уточнение карты

[RailBulkSellPoint.xml](https://github.com/maxkra1985/FS25_AbandonedTaiga_4x/blob/main/map/placeables/RailBulkSellPoint/RailBulkSellPoint.xml#L78-L84) подтверждает базовый `SellingStation` с `unloadTrigger` и `baleTrigger`; типы продукции перечислены явно. Пункт приёма древесины и две `sellingStationProducts` ещё требуют точной привязки к XML из preplaced map.i3d.

### Осталось проверить

- [ ] Есть ли у конкретного SellingStation override `getStoreGoods`, и соответствует ли логика реальному FS25 1.25.0.0.
- [ ] Точные XML двух `sellingStationProducts`, пункта древесины и типы их триггеров.
- [ ] Попадает ли паллетный путь в `SellingStation` напрямую либо в иной подкласс, включая дополнительную оплату паллет.
- [ ] Сетевая обработка отказа покупки и демонстрация локализованного сообщения без выдачи товара.
