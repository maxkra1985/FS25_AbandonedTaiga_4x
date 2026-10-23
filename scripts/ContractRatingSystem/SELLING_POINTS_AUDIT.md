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
