# Hardware bring-up — start here

Written for someone who has never touched electronics. Follow it in order. Each step proves one thing,
so when something breaks you know exactly which thing broke.

**Budget about one full day** for the first time through. Most of that is installing software and waiting
for parts, not actual building.

---

## 1. What to buy

| Part | What it does | Approx ₹ | What to search for |
|---|---|---|---|
| **ESP32 DevKit V1** (ESP32-WROOM-32) | The brain. WiFi + processor. | 400 | "ESP32 development board 30 pin" |
| **MAX30102** module | Heart rate + SpO₂ | 300 | "MAX30102 pulse oximeter module" |
| **MPU6050** (GY-521) | Motion + fall detection | 180 | "MPU6050 GY-521 module" |
| **DHT22** (AM2302) **3-pin module** | Ambient temp + humidity | 250 | "DHT22 module 3 pin" — **not** the bare 4-pin sensor |
| **Breadboard** (830 point) | Connects things without soldering | 150 | "solderless breadboard 830" |
| **Jumper wires** male-to-female + male-to-male | The connections | 150 | "jumper wires 40pin dupont" |
| **USB cable** | Power + programming | — | Must be a **data** cable, see below |

**Total ≈ ₹1,450.** Buy from Robu.in, Robocraze, Quartz Components, or Amazon.in. Most major cities have an
electronics market that's cheaper and same-day if you can get there.

### Three buying traps

1. **Ask for "with header pins soldered."** Modules usually ship with a loose strip of pins that must be
   soldered on. Pushing them in without soldering gives an intermittent connection that will waste a day of
   your life. If you can't get pre-soldered, budget ₹400 for a basic 25W soldering iron and solder wire —
   it's 8 joints per module and genuinely not hard.
2. **Get the DHT22 *module* (small PCB, 3 pins), not the bare 4-pin sensor.** The module has the required
   10 kΩ resistor built in. The bare sensor doesn't, and you'd have to add one.
3. **Your USB cable must carry data.** Many phone-charger cables are power-only and will light up the board
   but never appear as a COM port. If the board doesn't show up, try a different cable *first* — this is the
   single most common beginner dead end.

Buy **two ESP32 boards** if you can afford ₹400 more. They're the part most likely to get fried, and a spare
turns a dead demo into a five-minute swap.

### Not needed for v1

Body-temperature sensor (MAX30205) and a PM2.5 sensor. The firmware handles both being absent — body temp
shows "sensor not fitted", and air quality comes from the weather API. Add them later if you have time.

---

## 2. Install the software

1. **Arduino IDE** — download from [arduino.cc/en/software](https://www.arduino.cc/en/software), install normally.
2. **Add ESP32 board support:**
   - File → Preferences → "Additional Board Manager URLs" → paste:
     `https://espressif.github.io/arduino-esp32/package_esp32_index.json`
   - Tools → Board → Boards Manager → search `esp32` → install **"esp32 by Espressif Systems"**
   - This downloads ~200 MB. Let it finish.
3. **Install the four libraries** — Tools → Manage Libraries, search and install each:
   - `SparkFun MAX3010x Pulse and Proximity Sensor Library`
   - `DHT sensor library` (by Adafruit)
   - `Adafruit Unified Sensor` (by Adafruit)
   - `Adafruit MPU6050` (by Adafruit)
4. **USB driver (Windows).** Plug the board in and check Device Manager → Ports. If you see nothing, or a
   yellow warning triangle, install the driver for your board's USB chip — **CP2102** or **CH340** (it's
   printed on the small square chip near the USB socket). Search "CP2102 driver" or "CH340 driver".

**Board settings** — Tools menu, set these once:
- Board: **ESP32 Dev Module**
- Upload Speed: **115200** (higher speeds fail on cheap cables)
- Port: whichever COM port appeared

---

## 3. Test 1 and 2 — before wiring anything

Open `bringup/t1_blink/t1_blink.ino` and upload it (→ arrow button). Open Serial Monitor
(magnifying glass, top right) and **set the dropdown to 115200 baud** or you'll see garbage.

> **If upload fails with "Failed to connect... Timed out waiting for packet header":**
> hold the **BOOT** button on the board while the IDE prints `Connecting......`, release once it starts
> writing. Some boards need this every time; it's normal, not a fault.

Then `bringup/t2_wifi/t2_wifi.ino` — edit the two credential lines first.

> **ESP32 cannot join 5 GHz WiFi.** Only 2.4 GHz. If your router shows two networks, pick the 2.4 GHz one.
> A phone hotspot works well and is often the most reliable option at a venue.

Don't continue until both pass.

---

## 4. Wire it up

**Power off — unplug the USB — before changing any wire.**

Everything runs at **3.3 V**. Never connect any of these modules to the 5V pin.

The two I²C sensors (MAX30102, MPU6050) share the same two data wires. That's normal and correct — each has
a different address, so they take turns.

| Module | Module pin | → | ESP32 pin |
|---|---|---|---|
| **MAX30102** | VIN (or VCC) | → | **3V3** |
| | GND | → | **GND** |
| | SDA | → | **GPIO 21** |
| | SCL | → | **GPIO 22** |
| **MPU6050** | VCC | → | **3V3** |
| | GND | → | **GND** |
| | SDA | → | **GPIO 21** *(same as above)* |
| | SCL | → | **GPIO 22** *(same as above)* |
| **DHT22 module** | + (or VCC) | → | **3V3** |
| | − (or GND) | → | **GND** |
| | OUT (or DATA) | → | **GPIO 4** |

Use the breadboard's long **red rail** for 3V3 and the long **blue rail** for GND, then run short wires from
each rail to each module. That way you only take two wires off the ESP32 instead of six.

```
     ESP32                          breadboard rails
  ┌──────────┐
  │      3V3 ├──────────────────► red rail ──┬── MAX30102 VIN
  │      GND ├──────────────────► blue rail ─┼── MPU6050 VCC
  │          │                               └── DHT22 +
  │  GPIO 21 ├───── SDA ──────► MAX30102 SDA + MPU6050 SDA
  │  GPIO 22 ├───── SCL ──────► MAX30102 SCL + MPU6050 SCL
  │  GPIO  4 ├───── DATA ─────► DHT22 OUT
  └──────────┘
```

Double-check GND before powering on. A swapped power/ground is the one mistake that kills a module.

---

## 5. Test 3 — the wiring check

Upload `bringup/t3_i2c_scan/t3_i2c_scan.ino`. **This is the most important test.**

You should see:

```
  found device at 0x57   <- MAX30102 (heart rate / SpO2)
  found device at 0x68   <- MPU6050 (motion)
found 2 device(s)
```

If you see both, your wiring is correct and everything after this is software. If you don't, fix it here —
don't move on hoping it sorts itself out.

| What you see | Almost always means |
|---|---|
| `found 0 device(s)` | SDA and SCL swapped, or no power reaching the modules |
| Only `0x68` | MAX30102 problem — check its solder joints |
| Only `0x57` | MPU6050 problem — check its solder joints |
| `0x69` instead of `0x68` | Fine. MPU6050's AD0 pin is high. Change `0x68` to `0x69` in test 5 |
| Board keeps restarting | Short circuit — unplug immediately, recheck every wire |

---

## 6. Tests 4, 5, 6 — one sensor at a time

Run each, confirm, move on.

**`t4_max30102`** — heart rate. *Rest* a fingertip on the glowing window; **do not press hard** (pressure
squeezes blood out of the fingertip and the signal disappears). Hold still 10–15 seconds. Wrist-mounted PPG
during movement is genuinely hard — fingertip at rest is how you demo it.

**`t5_mpu6050`** — motion. Still on the desk reads ≈ **1.00 g**. That's gravity, not an error. Lift it fast
(drops below 1), tap it (spikes above 2). To test a real fall, drop it 20 cm **onto a cushion or your hand** —
never onto a hard surface.

**`t6_dht22`** — temperature/humidity. **Breathe on it** — humidity should jump within seconds. That proves
it's actually reading rather than printing a constant. First one or two reads returning `nan` is normal.

---

## 7. Test 7 — talk to the backend

Start the backend on your laptop first (`cd backend && npm run dev`).

Find your laptop's IP — PowerShell → `ipconfig` → the **IPv4 Address** under your WiFi adapter, e.g.
`192.168.1.42`.

> **Never use `localhost` or `127.0.0.1` here.** On the ESP32 those mean "the ESP32 itself", so it would be
> posting to nobody. It must be your laptop's actual network address, and both must be on the same WiFi.

Edit the four lines at the top of `bringup/t7_post/t7_post.ino`, upload, and watch for `HTTP 200`. Open the
dashboard — a heart rate should be moving.

| Result | Fix |
|---|---|
| `HTTP 200` | Working. Move to step 8. |
| `HTTP 401` | `API_KEY` doesn't match `DEVICE_API_KEY` in `backend/.env` |
| `FAILED (-1)` | Backend not running, wrong IP, or different networks |
| `FAILED` and IP is right | **Windows Firewall.** See below. |

**Windows Firewall** blocks incoming connections to Node by default, so the ESP32 can't reach port 4000.
Run PowerShell **as Administrator**:

```powershell
New-NetFirewallRule -DisplayName "Health Companion backend" -Direction Inbound -LocalPort 4000 -Protocol TCP -Action Allow
```

---

## 8. The real firmware

Now everything is proven, run the actual thing:

1. Open `esp32_sensor_node/esp32_sensor_node.ino`
2. Copy `config.example.h` → `config.h` (same folder)
3. Fill in `config.h`: WiFi name/password, `SERVER_URL` with your laptop IP, `DEVICE_API_KEY` matching
   `backend/.env`
4. Upload

Serial Monitor should show the sensors initialising, then a JSON line every 5 seconds with `HTTP 200`.

To test fall detection, drop it onto a cushion — you should see `** FALL CONFIRMED`, a critical alert on the
dashboard, and an SMS line in the backend terminal.

---

## Safety and care

- **Unplug before rewiring.** Every time.
- **Never connect these modules to 5V.** They are 3.3 V parts.
- Don't let the bare board sit on anything metal — it shorts the pins underneath.
- The ESP32 gets warm in normal use. Too hot to touch means something is shorted — unplug it.
- Handle boards by the edges. Static from a synthetic carpet can damage chips.
- **This is a prototype, not a medical device.** Don't use its readings to make an actual health decision,
  and say so on your slides — judges respect the disclaimer far more than an overclaim.

---

## If you get properly stuck

Work backwards through the tests. The last one that passed tells you where the problem is. Two questions
solve most of it:

1. Does `t3_i2c_scan` still find both devices? If not, it's hardware — wires or solder.
2. Does `t7_post` still get `HTTP 200`? If not, it's network — IP, firewall, or the backend isn't running.

And when something worked yesterday but not today, the answer is almost always a wire that got nudged loose,
or your laptop got a **new IP address** from the router. Re-run `ipconfig` and check.
