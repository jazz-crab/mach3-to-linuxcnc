---
title: "LinuxCNC для Purelogic RA0306-02"
subtitle: "Переход с Mach3 на LinuxCNC по LPT (PLC545)"
date: "2026-08-02"
---

# LinuxCNC для Purelogic RA0306-02

Подробная пошаговая инструкция: как поднять LinuxCNC на Debian Trixie с LPT-портом и драйвером Purelogic PLC545, вместо Mach3.

**Станок:** RA0306-02 (рабочая зона 640 × 350 × 100 мм)  
**Электроника:** многоканальный драйвер ШД PLC545 (LPT)  
**Шпиндель:** QW1.5/220/24K + частотник ESMD152X2SFA  
**ОС на станке:** Debian Trixie, минимальный рабочий стол (openbox), ~2 ГБ ОЗУ

---

# 1. Как это устроено (простыми словами)

## 1.1. Что «шлёт» программа в разъём

LinuxCNC **не** отправляет «команды» вроде «двигай X». Она работает так:

1. G-code / джог → контроллер движения считает, сколько **шагов** нужно по каждой оси.
2. Компонент `stepgen` генерирует импульсы **STEP** и уровни **DIR**.
3. Через HAL (Hardware Abstraction Layer) эти сигналы подключаются к пинам параллельного порта.
4. Драйвер `hal_parport` выставляет 0/1 на контактах DB25.
5. Плата PLC545 принимает STEP/DIR, крутит шаговики; ШИМ на пине 14 превращает в 0–10 В для частотника.

Связка выглядит так:

```hal
loadrt hal_parport cfg="0x378"
net Xstep  stepgen.0.step  =>  parport.0.pin-02-out
net Xdir   stepgen.0.dir   =>  parport.0.pin-06-out
```

## 1.2. Номера пинов

**Номер пина в LinuxCNC = физический контакт разъёма DB25 = номер пина в Mach3 Ports & Pins.**  
Ничего «угадывать заново» не нужно: если связка работала под Mach3, раскладка та же.

| Контакты DB25 | Назначение на классическом LPT |
|---------------|--------------------------------|
| 2–9 | 8 выходов данных (STEP/DIR и т.п.) |
| 1, 14, 16, 17 | 4 управляющих выхода (реле, PWM, ENABLE) |
| 10–13, 15 | 5 входов (концевики, E-stop) |
| 18–25 | GND |

---

# 2. Что взять с собой в институт

Чеклист перед понедельником:

- [ ] Флешка / ноутбук с этой инструкцией (PDF)
- [ ] Мультиметр (прозвонка, 0–10 В на частотнике)
- [ ] Фонарик — чтобы читать надписи на PLC545
- [ ] Блокнот: записать pinout, DIP-микрошаг, адрес LPT, latency
- [ ] (Желательно) Ethernet-кабель / Wi‑Fi — докачать пакеты, если чего-то нет
- [ ] Знать root-пароль Debian на станке
- [ ] Не подключать фрезу в шпиндель на время первых тестов

**Безопасность:** при любых переподключениях — питание драйвера и частотника **выкл**. E-stop в доступности. Первые движения — на малой скорости, рука на стопе.

---

# 3. Железо: что у тебя на станке

По паспорту RA0306-02 (полная комплектация Purelogic):

| Узел | Модель / параметр |
|------|-------------------|
| Станок | RA0306-02, портальный фрезер |
| Оси | X 640 мм, Y 350 мм, Z 100 мм |
| Передача | ШВП Ø16, **шаг 5 мм/об** (все оси) |
| Моторы | PL57H76-D8 (типично 1.8° → **200 полных шагов/об**) |
| Драйвер | **PLC545** (LPT-кабель), до 4 осей |
| БП осей | S-350-48 + дампер PLZ005-G2 (у PLC545 питание своё по мануалу платы) |
| Шпиндель | QW1.5/220/24K-D80/ER11 |
| Частотник | ESMD152X2SFA |
| Концевики | датчики (IN1… на плате), до 5 входов |
| Было ПО | Mach3 + профиль с purelogic.ru |

PLC545 — **старая** линейка; ближайший живой родственник в каталоге Purelogic — PLC330-G2 (тоже LPT, явно заявлен LinuxCNC). Раскладка LPT у 4-осевых плат Purelogic **почти везде одна и та же** (см. §4). Истина — **надписи на твоей плате**.

---

# 4. Раскладка LPT Purelogic (стартовая)

Из официальных профилей Mach3 Purelogic (`PureLogic.xml`, `PLC4x-G2.xml` и др.):

## 4.1. Выходы (оси и шпиндель)

| Пин DB25 | Сигнал | Примечание |
|----------|--------|------------|
| **2** | X STEP | |
| **3** | Y STEP | |
| **4** | Z STEP | |
| **5** | A STEP | на 3-осевом станке не используется |
| **6** | X DIR | часто **инвертирован** |
| **7** | Y DIR | часто **инвертирован** |
| **8** | Z DIR | часто **инвертирован** |
| **9** | A DIR | не используется |
| **14** | **PWM шпинделя** | на конвертер ШИМ→0…10 В платы → ЧП |
| **1** | выход (реле / enable) | смотри подпись на плате |
| **16** | выход (реле) | часто реле K1/K2 |
| **17** | выход (реле) | часто реле K1/K2 |

Адрес порта в профилях Purelogic: **0x378** (LPT1, десятичное 888).

## 4.2. Входы

| Пин DB25 | Типичное назначение |
|----------|---------------------|
| **10** | E-stop / общий / запасной вход |
| **11** | концевик оси X (или shared) |
| **12** | концевик оси Y |
| **13** | концевик оси Z |
| **15** | доп. вход / probe / shared |

На схеме RA0306 в мануале подписаны **S.X, S.Y, S.Z** (датчики). Точное соответствие IN1…IN5 ↔ пины — **с платы**.

## 4.3. Обязательно снять с платы (5–10 минут)

Открой крышку шкафа / посмотри на шелкографию PLC545 и **запиши**:

1. Какой контакт LPT = STEP X / DIR X / …  
2. Где **ENABLE** (если есть отдельный)  
3. Где **PWM / FREQ / 0-10V**  
4. **RELAY1 / RELAY2** — что подключено (шпиндель ON, помпа СОЖ)  
5. **IN1…IN5** — X/Y/Z home-limit, E-stop  
6. **DIP микрошага** по каналам: 1 / 2 / 8 / 16  
7. **DIP тока** (не трогай без нужды, если станок ездил нормально)

> Если подписи совпали с таблицей §4.1 — дальше просто вбиваешь эти пины в StepConf.  
> Если нет — **верь плате**, не таблице.

---

# 5. Расчёт шагов на миллиметр (SCALE)

Формула:

\[
\text{SCALE} = \frac{\text{полных шагов/об} \times \text{микрошаг}}{\text{шаг винта, мм/об}}
\]

Для RA0306-02:

| Параметр | Значение |
|----------|----------|
| Полных шагов/об | 200 (1.8°) |
| Шаг ШВП | 5 мм/об |
| Ремень/шкив | 1:1 (прямой вал) |

| Микрошаг на DIP | SCALE (шаг/мм) |
|-----------------|----------------|
| 1:8 | **320** |
| 1:16 | **640** |
| 1:2 | 80 |
| 1:1 | 40 |

**Рекомендация Purelogic:** 1:8 или 1:16 (плавнее, меньше резонанс).

Скорость из паспорта: до **6000 мм/мин** = 100 мм/с.  
При SCALE 320 и 100 мм/с → 32 000 шаг/с (нормально для софт-степпинга).  
При SCALE 640 → 64 000 шаг/с — нужна хорошая latency; на старте лучше **30–50 мм/с**, потом поднимать.

---

# 6. Подготовка Debian на станке

Залогинься на ПК станка. Команды от root или через `sudo`.

## 6.1. Realtime-ядро (желательно)

```bash
sudo apt update
sudo apt install linux-image-rt-amd64
# при необходимости:
# sudo apt install linux-headers-rt-amd64
sudo reboot
```

После перезагрузки:

```bash
uname -r
# в имени ядра должно быть что-то вроде ...-rt-...
```

> На LPT при невысоких скоростях иногда ездит и без RT, но **лучше с RT**. Jitter смотри в latency-test.

## 6.2. Пакеты LinuxCNC

```bash
sudo apt install linuxcnc-uspace linuxcnc-uspace-dev
# или метапакет, если есть в репозитории:
# sudo apt install linuxcnc
```

Проверь:

```bash
which linuxcnc stepconf latency-test
linuxcnc -v   # или --help
```

Минимум для openbox уже есть. Нужны шрифты/зависимости GUI — обычно тянутся сами.

## 6.3. Параллельный порт

### BIOS

- LPT **Enabled**
- Режим: **EPP** или **ECP+EPP** или **SPP** (если EPP капризничает — SPP)
- Адрес часто **378h**, IRQ 7

### Linux

```bash
# есть ли порт?
ls -l /dev/parport* 2>/dev/null
dmesg | grep -iE 'parport|ppdev' | tail -20
cat /proc/ioports | grep -i par
```

Типичный адрес: **0x378**.

Чтобы ядро не мешало `hal_parport`, модуль принтера `lp` лучше не цеплять к порту:

```bash
echo 'blacklist lp' | sudo tee /etc/modprobe.d/blacklist-lp.conf
# при необходимости перезагрузка
```

Права: LinuxCNC/uspace обычно ходит в порт через RTAPI; если будут ошибки доступа — добавь пользователя в группы:

```bash
sudo usermod -aG dialout,plugdev "$USER"
# перелогинься
```

## 6.4. Latency test (обязательно)

```bash
latency-test
```

Пока тест идёт **2–10 минут**, нагрузи ПК: двигай окна, копируй файлы, открой браузер (если есть). **Не** запускай LinuxCNC параллельно.

Запиши **Max Jitter** (нс).

| Max Jitter | Оценка |
|------------|--------|
| < 15–20 µs (15000–20000 ns) | отлично для soft-step |
| 30–50 µs | можно, скорости скромнее |
| > 100 µs | плохой кандидат на LPT soft-step |
| > 1 ms | для LinuxCNC почти непригоден |

В StepConf это поле **Base Period Maximum Jitter**.

---

# 7. Создание конфига мастером StepConf

## 7.1. Запуск

В openbox / терминале:

```bash
stepconf
```

Выбери **Create New**.  
(Опционально: **Import** — XML профиля Mach3 Purelogic, если скачаешь; см. §10.)

## 7.2. Basic Information

| Поле | Значение |
|------|----------|
| Machine Name | `RA0306` (латиница, без пробелов) |
| Axis Configuration | **XYZ (Mill)** |
| Machine Units | **mm** |
| Driver Type | **Other** |
| Step Time | **12000** ns (минимум Purelogic ~10 µs; с запасом 12–15 µs) |
| Step Space | **12000** ns |
| Direction Hold | **10000** ns |
| Direction Setup | **10000** ns |
| One / Two Parport | **One** |
| Base Period Maximum Jitter | **число из latency-test** |

## 7.3. Parallel Port Setup

- Address: **0x378** (или `0`, если ядро само нашло первый порт)
- Output pinout preset: **не** Sherline/Xylotex — выставляй вручную:

**Выходы (пример Purelogic — сверь с платой!):**

| Pin | Signal | Invert |
|-----|--------|--------|
| 2 | X Step | нет |
| 3 | Y Step | нет |
| 4 | Z Step | нет |
| 5 | Unused | |
| 6 | X Direction | **да** (часто) |
| 7 | Y Direction | **да** |
| 8 | Z Direction | **да** |
| 9 | Unused | |
| 1 | Spindle ON / Relay / Enable | по плате |
| 14 | **Spindle PWM** | обычно нет |
| 16 | Relay / Coolant | по плате |
| 17 | Relay / Enable | по плате |

**Входы (пример — сверь с платой!):**

| Pin | Signal | Invert |
|-----|--------|--------|
| 10 | Estop / Both Limit+Home shared | часто **да** (active low) |
| 11 | X Home / X Both Limit+Home | часто **да** |
| 12 | Y Home / Y Both Limit+Home | часто **да** |
| 13 | Z Home / Z Both Limit+Home | часто **да** |
| 15 | Unused / Probe | |

> Если концевики **нормально замкнуты (NC)** в цепочку — при срабатывании вход «отпускается»; в LinuxCNC почти всегда ставят **Invert**. Если джог сразу в limit fault — попробуй снять/поставить Invert.

**Charge Pump:** на классическом PLC545/PLC330 обычно **не** требуется. Не включай, пока не увидишь на плате вход CHARGE PUMP.

## 7.4. Оси X / Y / Z

Одинаково по формуле, отличаются только travel:

| Поле | X | Y | Z |
|------|---|---|---|
| Motor steps per revolution | 200 | 200 | 200 |
| Driver microstepping | **с DIP** (8 или 16) | то же | то же |
| Pulley teeth (motor:leadscrew) | 1 : 1 | 1 : 1 | 1 : 1 |
| Leadscrew pitch | **5** mm/rev | **5** | **5** |
| Maximum Velocity | начни **40** mm/s | 40 | 25–30 |
| Maximum Acceleration | начни **200** mm/s² | 200 | 150 |
| Table travel min / max | 0 … **640** | 0 … **350** | 0 … **100** (или −100…0 — как удобнее home) |
| Home location | внутри soft limits, **не** на краю | | |

Потом **Test this axis** (осторожно! см. §8).

Если ось едет **не в ту сторону** — либо Invert на DIR, либо **отрицательный** leadscrew pitch (−5).

## 7.5. Spindle (частотник)

Страница появится, если на пине выбран **Spindle PWM**.

| Поле | Рекомендация |
|------|----------------|
| PWM Rate | **0** (режим PDM — удобно для ЦАП ШИМ→напряжение на плате Purelogic) **или** 100–1000 Гц по мануалу ЧП |
| Speed 1 / PWM 1 | 0 / 0 |
| Speed 2 / PWM 2 | временно 24000 / 1.0 (макс. обороты шпинделя ~24k) — **откалибруешь** после первого запуска |

**Spindle ON** — отдельный выход на реле платы → обычно «пуск» частотника (FOR/STF или клеммы пуска — как у тебя разведено).

Подключение Purelogic (типично):

- Пин **14** LPT → внутренний конвертер ШИМ→U  
- Выход платы **0…~8.5–10 В** + земля + питание 10 В **от частотника**  
- Реле — сухой контакт на клеммы пуска ЧП  

**Не путай** силовые клеммы 220 В и управляющие клеммы ЧП.

## 7.6. Options и Finish

- Include Halui — по желанию  
- Onscreen prompt for tool change — удобно  
- **Apply** → конфиг в `~/linuxcnc/configs/RA0306/`

Запуск:

```bash
linuxcnc ~/linuxcnc/configs/RA0306/RA0306.ini
# или через Configuration Selector
```

---

# 8. Порядок первых пусков (безопасно)

Делай **строго по шагам**. Не пропускай.

## Шаг A. Без движения (моторы можно оставить подключёнными, но скорость 0)

1. Запусти LinuxCNC, сними E-stop, Machine ON.  
2. Открой **Halshow** (Machine → Show HAL Configuration) или `halshow`.  
3. Джог X+ / X− — должен мигать `parport.0.pin-02-out` (STEP) и меняться DIR на пине 6.  
4. То же для Y, Z.  
5. MDI: `M3 S1000` — должен включиться выход реле и появиться активность PWM (пин 14).  
6. `M5` — выключить.

Если пины не те — правь в StepConf (Modify existing) или в `.hal`.

## Шаг B. Одна ось, малая зона

1. Питание драйвера **вкл**.  
2. Частотник **выкл** или на стопе.  
3. В StepConf → ось → **Test this axis**: маленькая зона (20–30 мм), низкая скорость.  
4. Нет стука / пропуска шагов → подними velocity, потом acceleration.  
5. Нашёл предел без потери шагов → **минус 10–15%** → впиши в конфиг.  
6. Повтори для Y и Z (Z — осторожнее, масса шпинделя).

## Шаг C. Направления и лимиты

1. Джог: X+ должен ехать в +X станка (обычно «от нуля вправо/вглубь» — как принято у тебя).  
2. Soft limits не дают уехать в железо.  
3. Концевик: при срабатывании LinuxCNC должен уйти в fault / stop — проверь **до** быстрого джога.

## Шаг D. Homing

1. Настрой Home search velocity (медленно, 5–15 mm/s).  
2. Home latch: обычно **Same** (подход, отъезд, медленный повтор).  
3. Home location — чуть внутрь от свитча, **не** совпадает с soft limit.  
4. `Home All`.

Если home/limit на одном датчике на ось — в StepConf выбирай **Both Limit + Home**.

## Шаг E. Шпиндель + частотник

1. Мультиметр на клеммы **аналогового входа** ЧП (0–10 В), не на силовые.  
2. MDI: `M3 S6000` → реле пуска, напряжение растёт.  
3. `S12000`, `S18000` — снять 2–3 точки «S-код ↔ реальные RPM / вольты».  
4. Вернуться в StepConf → Spindle calibration (Speed1/PWM1, Speed2/PWM2).  
5. Проверить направление вращения; при необходимости клеммы ЧП / параметр направления.

## Шаг F. Холостой G-code

Простой файл:

```gcode
G21 G90 G94
G0 Z5
G0 X10 Y10
G1 X50 F300
G0 Z10
M2
```

Смотри плавность, нет ли пропуска шагов, греется ли драйвер.

---

# 9. Если что-то пошло не так

| Симптом | Что проверить |
|---------|----------------|
| Вообще нет реакции на LPT | BIOS LPT, адрес 0x378, `dmesg`, blacklist `lp`, latency/RT |
| Ось не едет, драйвер молчит | ENABLE (уровень/пин), питание 48/27 В, DIP, аварийный светодиод |
| Едет рывками / теряет шаги | Скорость/ускорение ↓, Step Time ↑, экраны, микрошаг, ток |
| Едет не туда | Invert DIR или знак pitch |
| Сразу joint limit / following error | Invert входов концевиков; soft limits; SCALE слишком большой |
| Шпиндель не крутится | Реле, JMP на плате (у PLC330 K1 только при разомкнутом JMP1), клеммы пуска ЧП |
| Обороты не те | PWM rate, калибровка, параметр макс. частоты ЧП, полярность 0–10 В |
| GUI тормозит / 2 ГБ ОЗУ | Только openbox+linuxcnc, без браузера; закрыть лишнее |
| `Permission denied` / realtime error | RT-ядро, группы пользователя, не запускать latency и linuxcnc вместе |

Полезные команды:

```bash
halcmd show pin parport
halcmd show pin stepgen
dmesg | tail -50
```

Правка вручную (после StepConf):

- `~/linuxcnc/configs/RA0306/RA0306.ini` — скорости, SCALE, limits  
- `~/linuxcnc/configs/RA0306/RA0306.hal` — `net` на пины  
- `custom.hal` / `custom_postgui.hal` — свои доработки (StepConf их не затирает)

Пример инверсии пина:

```hal
setp parport.0.pin-06-out-invert true
```

---

# 10. Полезные ссылки и файлы

| Что | Где |
|-----|-----|
| Документация LinuxCNC (hal_parport, StepConf) | https://linuxcnc.org/docs/html/ |
| StepConf | https://linuxcnc.org/docs/html/config/stepconf.html |
| Профили Mach3 Purelogic (ZIP) | https://purelogic.ru/soft/elektronika/mach_profiles_soft.zip |
| Мануал родственного PLC330-G2 | https://purelogic.ru/docs/elektronika/driver_stepmotor_plc330_g2_user_manual_ru.pdf |
| Сайт Purelogic | https://purelogic.ru |

Из ZIP профилей для старта ближе всего:

- `PureLogic.xml`  
- `PLC4x-G2.xml`  

StepConf → **Import** → пройтись по страницам и поправить travel/SCALE под RA0306.

---

# 11. Шпаргалка «в день настройки» (одна страница)

1. BIOS: LPT on, адрес 378h.  
2. `sudo apt install linux-image-rt-amd64 linuxcnc-uspace` → reboot → `uname -r`.  
3. `latency-test` → записать jitter.  
4. Списать pinout + DIP микрошага с PLC545.  
5. `stepconf`: mm, XYZ, timings 12 µs, port 0x378, пины Purelogic, SCALE = 200×µ/5.  
6. Vel 40 mm/s, Accel 200 — тест оси.  
7. Направления, soft limits, home.  
8. PWM pin 14 + реле → ЧП; калибровка S.  
9. Холостой G-code.  
10. Сохранить конфиг, сделать копию `~/linuxcnc/configs/RA0306` на флешку.

---

# 12. Краткая теория HAL (если полезешь в .hal)

| Понятие | Смысл |
|---------|--------|
| **pin** | точка входа/выхода компонента (`parport.0.pin-02-out`) |
| **signal** | именованный провод (`Xstep`) |
| **net** | соединить signal с pin’ами |
| **setp** | выставить параметр (`…-invert true`) |
| **addf** | повесить функцию на realtime-thread |

Типичный кусок после StepConf (имена могут чуть отличаться):

```hal
loadrt hal_parport cfg="0x378 out"
addf parport.0.read base-thread
addf parport.0.write base-thread

net xstep  <= stepgen.0.step  => parport.0.pin-02-out
net xdir   <= stepgen.0.dir   => parport.0.pin-06-out
net ystep  <= stepgen.1.step  => parport.0.pin-03-out
net ydir   <= stepgen.1.dir   => parport.0.pin-07-out
net zstep  <= stepgen.2.step  => parport.0.pin-04-out
net zdir   <= stepgen.2.dir   => parport.0.pin-08-out

net spindle-on  spindle.0.on  => parport.0.pin-01-out
# PWM — через pwmgen, StepConf пропишет сам
```

---

# Приложение A: расчёт SCALE — примеры

**Микрошаг 1:8**

\[
200 \times 8 / 5 = 320 \text{ шаг/мм}
\]

Перемещение на 10 мм → 3200 импульсов STEP.

**Микрошаг 1:16**

\[
200 \times 16 / 5 = 640 \text{ шаг/мм}
\]

Проверка линейкой: команда `G0 X100` → рулетка должна показать ≈100 мм.  
Ошибка 98 мм при 100 → SCALE надо × (100/98).

---

# Приложение B: что не делать

- Не ставить размыкатель **после** БП на линии DC драйвера (Purelogic прямо запрещает) — только на 220 В до БП.  
- Не соединять «−» БП драйвера с корпусом/землёй «как попало» (см. мануал платы).  
- Не гонять max скорость из паспорта в первый день.  
- Не калибровать шпиндель «на глаз» без мультиметра на 0–10 В.  
- Не коммитить и не править конфиг вслепую на работающем шпинделе с фрезой в заготовке.

---

# Приложение C: Список литературы

[1] LinuxCNC Documentation — Parallel Port Driver (`hal_parport`). https://linuxcnc.org/docs/html/man/man9/hal_parport.9.html  

[2] LinuxCNC Documentation — Stepper Configuration Wizard (StepConf). https://linuxcnc.org/docs/html/config/stepconf.html  

[3] LinuxCNC Documentation — Stepper Configuration (HAL pinout examples). https://linuxcnc.org/docs/html/config/stepper.html  

[4] Purelogic R&D — Руководство по эксплуатации RA0306-02 (ред. 14.07.2016).  

[5] Purelogic R&D — Многоканальный драйвер PLC330-G2, РЭ (ред. 04.05.2026). https://purelogic.ru/docs/elektronika/driver_stepmotor_plc330_g2_user_manual_ru.pdf  

[6] Purelogic R&D — Профили Mach3 (ZIP). https://purelogic.ru/soft/elektronika/mach_profiles_soft.zip  

[7] Purelogic R&D — каталог, PLC330-G2 (совместимость с LinuxCNC). https://purelogic.ru/catalog/kontroller_shd_plc330-g2_interfeys_lpt/
