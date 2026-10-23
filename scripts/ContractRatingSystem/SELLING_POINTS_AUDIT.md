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
