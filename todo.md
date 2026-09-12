# openHAB TODO

Working list for this config. Read this at the start of a session; add to it rather than
letting findings evaporate into chat history.

## 0. NEXT SESSION — read this first (written 2026-09-12 ~16:50, for a session ~2026-09-13 midday)

openHAB was rebooted on the evening of 2026-09-12 specifically so the next session can read a
**full heating cycle** out of the log. 2026-09-13 is a **Sunday**, so the weekend crons apply.

**Do not restart openHAB before reading the log** — `openhab.log` and `events.log` rotate on
restart, and the cycle would be lost. Check `ls -la /var/log/openhab/` first.

**PRECONDITION — check this before interpreting anything.** After the 16:50 reboot all three
`Heating_*_Enabled` masters were OFF (section A). Christian was asked to switch them back ON before
leaving. If they were left OFF, then **the cycle test is void, not broken**: every scheduled rule
will simply log `<Room>: master switch is OFF → ignoring` and nothing will have heated all night.
That is the master switch working exactly as designed — do NOT misdiagnose it as a fault in the
weather guard, the 120min logic or the new scheduling. Check
`curl -s localhost:8080/rest/items/Heating_Kueche_Enabled/state` first; if OFF, the only finding is
"masters were not restored", and the cycle needs re-running on another day.

**Status check 2026-09-12 ~21:30:** all three `Heating_*_Enabled` masters were still **OFF**
(verified via REST). The 18:00 Dinner rule logged a genuine `TOO WARM` decision (weather check runs
before the master gate, so that line is real), and 20:00 `After Dinner → Küche OFF` fired. Unless
the masters are switched ON before 23:00, the overnight/morning part of section B is void.
The 16:51:22 NPE was re-checked: it is the one described in A, no new errors after 16:52.

**Restart 2026-09-12 22:34:10 → 22:35:17 (systemctl restart, after the mapdb + REST changes).
Results, analysed the same evening:**
- [x] **mapdb restore PROVEN.** All three `Heating_*_Enabled` back ON, targets 19/21/21,
      `_Comfort` OFF, `TooWarm` ON, StopTemps 17/18 — exactly the pre-restart values. The
      `_Comfort_120min` and `_120min_Until` items came back NULL because they were never
      updated after mapdb was installed (nothing to store); they will be from now on.
      Restores do NOT appear in events.log (restore sets state without an event) — check via REST.
- [x] Stop still hung (section 10) but was killed after **60 s** instead of 120 s. Restart
      total 67 s. `Failed to kill control group ... Invalid argument` in the journal is systemd
      noise, ignore.
- [x] **The avmfritz NPE CAME BACK at 22:36:07 — the 16:55 guard is defeated by mapdb.** (Fixed
      and proven 22:52, see the end of this item.)
      `on_load` logged `Arbeitszimmer: radiator_mode → OFF (item was OFF)` — at 16:51 that was
      `(item was )`, i.e. NULL. mapdb (`*`, restoreOnStartup) now restores
      `Radiator_*_RadiatorMode` too, so the mode item is never NULL at boot and the
      "NULL = no device data" heuristic no longer detects an un-polled thing. First FRITZ poll
      was 22:36:49, 42 s after the command. Only one ERROR (one handler); Küche/Bad were already
      polled or absorbed it. Effect is harmless (valve was OFF anyway) but the command is lost
      and it is an ERROR at every boot.
      **Correct guard = thing status.** Checked in the 5.2.x binding source
      (`AVMFritzBaseThingHandler`): `initialize()` sets `UNKNOWN`; `ONLINE` is set only in
      `onDeviceUpdated()` after the bridge delivered device data with `present == 1` — exactly
      the moment `getHkr()` stops being null. Thing UIDs (all ONLINE now):
      Küche `avmfritz:FRITZ_DECT_301:1:099950581490`,
      Badezimmer `avmfritz:FRITZ_DECT_301:1:099950124754`,
      Arbeitszimmer `avmfritz:FRITZ_DECT_302:1:139790923452` (the 302, not the phantom 301).
      **FIXED in `heating.rb` 22:48 (approved by Christian), unproven until the next cold boot:**
      one `reassert(key)` helper holds the logic once; `valve_online?(r)` asks the thing linked
      to the mode item (`r[:mode].thing&.online?`, no UIDs copied); `on_load` re-asserts only
      rooms whose valve is online and logs `valve thing not online yet → re-assert waits for it`
      for the rest; new rule `'Heating - valve came online → re-assert its room'`
      (`changed things, to: :online`) re-asserts a room when its valve thing turns ONLINE — this
      also closes a gap: before, a skipped room at boot never re-armed its 120min timer, so a
      restored window would have heated forever. Reloaded twice at 22:48 with no error, 21
      heating rules registered. **At the next cold boot expect**, per room: the "waits for it"
      line at load, then `valve thing is online → re-asserting` ~40 s later, and NO NPE.
      Also covers a FRITZ!Box reboot (things go OFFLINE → ONLINE).
      **PROVEN at the 22:51 cold restart:** load at 22:52:07 → Küche + Badezimmer (DECT 301)
      were already online and re-asserted OFF; Arbeitszimmer (DECT 302) logged `valve thing not
      online yet → re-assert waits for it`; at 22:52:50 (first poll of the 302, 43 s later)
      `valve thing is online → re-asserting` → OFF. **No NPE, zero ERRORs.** All restored
      states exact again (masters ON, targets 19/21/21). The 302 polls later than the 301s —
      that is why only one handler ever threw. This stop was the clean variant: 21 s, no kill.

### A. Startup behaviour — ALREADY ANSWERED, do not re-investigate

The reboot happened at **16:50:27 on 2026-09-12** and was fully analysed the same evening.
Results, so the next session does not repeat the work:

- [x] **Masters came back OFF — the restore bug REPRODUCED.** All three were ON before the reboot.
      Full diagnosis in section 7b: rrd4j restores Numbers correctly, Switches wrongly, and
      DateTime not at all.
- [x] **The 120min resume test was VOID**, not failed. Its inputs were destroyed by the same bug:
      `Heating_Kueche_Comfort_120min` came back OFF and `Heating_Kueche_120min_Until` came back
      NULL, so there was nothing to resume and no `resumed after reload` line. The resume logic
      itself was verified working across a script reload at 16:43.
- [x] **`on_load` OFF-assertions fired** for all three rooms at 16:51:22 — but **caused an ERROR**:
      the avmfritz binding threw `NullPointerException: getHkr() is null` because Arbeitszimmer was
      commanded at 16:51:22 while that thing did not poll until 16:52:03. Commanding a heating
      channel before its thing's first poll is not safe.
      **Fixed at 16:55** — `on_load` now skips a room whose `mode` item is still NULL and logs
      `no device data yet on load → skipping re-assert`. **This guard is UNEXERCISED**: at the
      16:55 reload the binding had already polled, so it did not trigger. It will only be proven at
      the next genuine cold boot — check for that line, and for the absence of the NPE.
- [x] 20 heating rules registered, all IDLE. `Radiator_*` items all resolve after a cold start —
      the rename survived the reboot cleanly.
- [x] Harmless: `SseItemStatesEventBuilder` warnings about `FRITZDECT3011*` names at 16:50:54 are
      an open browser tab still subscribed to the pre-rename page. A refresh clears them.
- [x] **New finding — duplicate thing.** AIN `139790923452` has TWO things:
      `avmfritz:FRITZ_DECT_302:1:139790923452` ("FRITZ!DECT 302 #3", all 12 channels linked to the
      `Radiator_Arbeitszimmer_*` items — the real one) and
      `avmfritz:FRITZ_DECT_301:1:139790923452` (from `things/fritzbox.things:11`, **zero** linked
      items — a phantom). Two handlers poll the same physical valve. The phantom did NOT cause the
      NPE (nothing is linked to it), but this is section 2's stale line doing real damage.

### B. The full cycle (grep `heating.rule` in openhab.log, in this order)
- [ ] **18:00 Dinner** — the FIRST real execution of `too_warm?`. It was ~22 °C against stop
      thresholds 17/18, so expect `Dinner: weather now ... → TOO WARM, no heating`. Confirm
      `Heating_TooWarm` finally stops being NULL. If it heated anyway, the all-day guard is wrong.
- [ ] **20:00** `After Dinner → Küche OFF`.
- [ ] **23:00** night mode (`Arbeitszimmer, Küche, Bad OFF`) AND the new bathroom rule fire at the
      same minute. The bathroom rule only acts if `ANOut` was ON. Check they did not fight.
- [ ] **Overnight** — nothing should heat. Any `set_temp →` line between 23:00 and 07:00 is a bug.
- [ ] **Morning** — GoodWatch (alarm clock) and/or the Sunday 08:00 weekend cron → `morning_heating`
      → weather check → Küche + Bad 120min. Verify the weather guard decided, not the old cache.
- [ ] **11:00 Sunday** weekend Arbeitszimmer, weather-gated.
- [ ] **12:00 Lunch** — Küche, only if Christian home, weather-gated.
- [ ] Confirm no 120min window was silently extended (each should be exactly 120 min).

### C. Still open, needs a decision
- [x] **mapdb + persistence fix (section 7b)** — done 2026-09-12 22:11, unproven until the next
      cold boot. Uncommitted: `persistence/{mapdb,rrd4j,jdbc}.persist`, `todo.md`.
- [x] `jdbc.persist` parses again (section 7b) — `default =` line removed, loaded 22:00:23.
- [x] **Committed + pushed 2026-09-12 as `be07f7f`** — `heating.rb`, `main.items`,
      `fritzbox.items`, `absence.rules`, `jdbc.persist`, deleted `layout/main.yaml`,
      `todo.md` + `CLAUDE.md`. Deliberately left OUT of that commit, still uncommitted:
      `services/runtime.cfg.dpkg-old` (packaging backup, see section 3) and
      `sounds/doorbell.mp3` (unexplained binary change). Both are unrelated to heating;
      neither contains secrets — the dpkg-old diff was checked line by line.
- [ ] Revoke the `claudebot` / `claudebot2` API tokens — see section 9 for what they actually
      grant, and for the two bigger findings next to them.
- [ ] `things/fritzbox.things:11` still declares the 302 as a `FRITZ_DECT_301` (section 2) —
      deliberately untouched; the file declares a different thing UID than the live JSONDB thing,
      so "fixing" it could re-provision the Arbeitszimmer valve. Needs its own analysis.

## 1. Move comfort temperature control into openHAB (main goal)

**Decision (2026-09-12): comfort temperature will in future be set centrally from openHAB,
not per-device in the FRITZ!Box.**

**HISTORIC — how it worked BEFORE 2026-09-12** (kept because it explains why the FRITZ!Box
values below existed): the rules never sent a temperature. They only sent the mode string
`COMFORT` to the `radiator_mode` channel, and the FRITZ!DECT valve regulated to the comfort
temperature stored **on the device**. As of 2026-09-12 this is no longer true — the temperature
comes from `Heating_<Room>_Target` in openHAB and is written to `set_temp`. See "Done" below.

FRITZ!Box location (found, so we don't re-research it): `http://fritz.box` →
Smart Home → Geräte und Gruppen → edit (pencil) behind the thermostat → **Zeitschaltung**
section. Comfort/Absenk are the two temperatures belonging to the weekly schedule — that is
why there is no standalone "Komforttemperatur" field.

Values as found on 2026-09-12:

| Room | ComfortTemp | EcoTemp |
|---|---|---|
| Arbeitszimmer | 21 °C | 6 °C |
| Badezimmer | 21 °C | 6 °C |
| Küche | 20 °C | 6 °C |

Resolved 2026-09-12:
- `comfort_temp` is **read-only** (`readOnly: true` on the item) — openHAB can never write it.
  Centralising therefore *must* go through `set_temp`, which is writable.
- The binding clamps `set_temp` to **8.0–28.0 °C**, rounded to 0.5 (`HeatingModel`:
  `TEMP_CELSIUS_MIN/MAX`, `normalizeCelsius`). A value below 8 is clamped *up*, it does
  **not** switch the valve off — so "off" must always go via `radiator_mode = OFF`.
- `TEMP_FRITZ_OFF = 253` renders as `8 − 2 = 6 °C`. A `SetTemp` of 6 °C means *off*, not a
  setpoint. That is why an idle room reads 6 °C.
- `radiator_mode = COMFORT` sends the device-stored `komfort` value — this was the
  dependency on the FRITZ!Box, now removed.

Done:
- [x] Drive `Radiator_*_SetTemp` from the rules instead of the device-stored comfort value.
      (Written as `FRITZDECT3011*_SetTemp` at the time; renamed later the same day — see section 5.)
- [x] Per-room target lives in UI-editable Items `Heating_<Room>_Target` (8–28 °C, 0.5 steps).
- [x] Per-room master switch `Heating_<Room>_Enabled`; OFF overrides every automation.

Still open:
- [ ] Leave the FRITZ!Box **Zeitschaltung schedule empty**. If Schaltpunkte are defined the
      FRITZ!Box drives the valve at those times and fights the openHAB rules.
- [x] Stepper + master-switch widgets added to the Heating page (`page_e5b6251094`) on
      2026-09-12 via the REST API.
- [ ] Revoke the `claudebot` / `claudebot2` API tokens when no longer needed, and delete
      `~/.config/openhab/claudebot*.token`. `claudebot` was malformed and never worked.

## 5. Deferred renames (risky, not done on purpose)

- [x] **DONE 2026-09-12 — `FRITZDECT3011*` renamed to `Radiator_*`.** The old prefix was wrong
      twice over: Arbeitszimmer is a **302**, and "3011" was never a model number, just `301` plus
      bridge index `1`. The new name is function-based on purpose, so swapping a valve for a
      different model cannot make it lie again.
      Done as a single prefix swap (`FRITZDECT3011` → `Radiator_`, preserving room and channel)
      across `items/fritzbox.items` (36), `heating.rb` (6), `persistence/jdbc.persist` (4) and the
      UI page JSON (12), with openHAB stopped so all files loaded together — editing them live
      would have left one referencing items the other had removed, raising `NameError` at script
      load and silently dropping every heating rule.
      **History was deliberately not migrated** (Christian: "no data migration"): 27 `.rrd` files
      and 4 Postgres tables are now orphaned under the old names and those charts restart empty.
      They can be deleted, or renamed to match, whenever convenient.
- [ ] `Heating_<Room>_Comfort` no longer sends `COMFORT` to anything; it is a plain "heat now"
      switch. Renaming to `_Heat` would touch `absence.rules:62-63`, `kueche.rules:105` and the
      UI page. Labels were fixed instead (2026-09-12) so the UI is no longer ambiguous.
- [x] `layout/main.yaml` was dead (dated Dec 2023, loaded by nothing, not the source of the
      Heating page — that lives in the JSONDB). Removed with `git rm` on 2026-09-12.

## 6. Pre-existing heating behaviours — DECIDED 2026-09-12

Found during the correctness review, then ruled on by Christian. Do **not** "fix" the WON'T FIX
entries in a later cleanup — they are deliberate.

- **WON'T FIX — night mode leaves a running 120min alone.** The 23:00 cron clears only
  `_Comfort`, so a 120min started at 22:30 heats Küche/Bad until 00:30.
  *Reason: "when I want to have it warm at night, I press the button." The 120min button is the
  intended way to get night heat, so the cron must not cancel it.*
- **WON'T FIX — 'Christian leaves' does not stop Badezimmer.** A running Bad 120min keeps
  heating after everyone has left.
  *Reason: the bathroom radiator dries towels; that has to continue in an empty flat.*
- [x] **FIXED 2026-09-12 — after a restart, Comfort-only rooms are never re-commanded.** `on_load`
      now re-asserts any room whose `_120min` **or** `_Comfort` is ON.
- [x] **FIXED + VERIFIED 2026-09-12 — every script reload granted a fresh 120 minutes.** The window
      end is now persisted in `Heating_<Room>_120min_Until` (DateTime). `on_load` calls
      `timed_updated(key, resume: true)` and re-arms only the remaining time; a real button press
      still restarts the full two hours.
      Verified live at 16:40:51: pressing Küche 120min logged "heating until 18:40", wrote
      `2026-09-12T18:40:51+0200`, and commanded `set_temp → 19 °C`. No errors.
      Resume verified at 16:43:07: a reload while the window was live logged "120min resumed after
      reload → heating until 18:40" and left the deadline **unchanged**, i.e. it re-armed only the
      remaining ~117 min instead of a fresh 2 h. That was the original defect.
      Testing note: openHAB's script watcher reacts to a CONTENT change, not mtime — `touch` alone
      does not reload the file.
- [ ] **AWAITING DECISION — master-switch ON heats unconditionally**, ignoring `CNOut` and the
      time of day, unlike every other path. Küche has no off-cron before 20:00, so a master ON at
      02:00 heats the kitchen all day.

## 7. Absence + heating — SPECIFIED by Christian 2026-09-12, implemented

The intended behaviour, in his words, and where each part lives:

- **"I leave, all off except bathroom."** `CNOut` OFF→ON ⇒ Arbeitszimmer + Küche off, including
  the Küche 120min. Badezimmer is deliberately untouched (towel drying). Already matched
  `heating.rb`; no change was needed.
- **"I come: Arbeitszimmer to comfort"** — but the **08:00–22:00 guard stays**. Christian was
  explicit: "don't need heating when coming home at 23:00, very important." The guard was briefly
  removed on 2026-09-12 and restored the same day. Do not remove it again. Other rooms keep their
  normal schedule; returning home does not start them.
- **"Lightshow: if me and Anne are out."** Already correct and unchanged: `RandomLight` is
  `Group:Switch:AND(ON,OFF)` over `ANOut` + `CNOut` + `SunIsDown`, so it arms only when both are
  out *and* it is dark.
- **NEW — "if Anne is out, Badezimmer off at night, always."** Cron at **23:00**; if `ANOut` is ON
  it clears `Heating_Badezimmer_Comfort_120min` and `_Comfort`. Purpose: the bathroom is the one
  room deliberately left running when the flat empties, so it is the one that gets forgotten.
  *Time assumed to be 23:00 to match the existing night mode — say if you want it earlier/later.*
- **Heating removed from `absence.rules`.** Lines 62-63 used to switch Arbeitszimmer + Küche off
  on `AbsenceMode`, duplicating `heating.rb` and missing the Küche 120min. `AbsenceMode` only goes
  ON when both are out, which implies `CNOut` is already ON, so `heating.rb` has always handled it
  first. Heating now lives in one file — do not add heating commands back to `absence.rules`.

## 7b. Persistence is unreliable for the heating control switches — FOUND 2026-09-12

At the 16:34 restart, `Heating_Arbeitszimmer_Enabled` and `Heating_Badezimmer_Enabled` both flipped
`ON → OFF` at the exact boot instant (16:35, confirmed from rrd4j datapoints). Nothing in
`heating.rb` ever writes those items OFF — `on_load` only ever does `update(ON)` when the state is
NULL. So the restart **restored the wrong value**.

**REPRODUCED at the deliberate 16:50 reboot on 2026-09-12, and now fully diagnosed.** Baseline
before the reboot was all three masters ON with a Küche 120min window running until 18:40.
Afterwards:

| Item | Type | After reboot | Verdict |
|---|---|---|---|
| `Heating_*_Target` | Number | 21 / 21 / 19 | restored **correctly** |
| `Heating_*_Enabled` | Switch | OFF (were ON) | restored **wrongly** |
| `Heating_*_Comfort_120min` | Switch | OFF (was ON) | restored **wrongly** |
| `Heating_*_120min_Until` | DateTime | NULL | **cannot be stored by rrd4j at all** |

So restore *is* running — the Numbers prove it — but rrd4j handles Numbers well, Switches wrongly,
and DateTime not at all. There is **no `rrd4j.persist`**, so rrd4j's built-in averaging default
applies to all 96 items; averaging is meaningless for a Switch. `on_load` did not repair it because
it only fills NULL, and OFF is not NULL, so it skipped silently and logged nothing.

Do not try to diagnose this from rrd4j charts: rrd4j carries the last value forward across the
downtime gap, so it showed `Enabled = ON` right through a period when REST read OFF. It is
consolidated data, not an event record.

**Consequence beyond the masters:** the 120-minute resume (section 6) works across *script
reloads* — verified 16:43 — but **cannot survive an openHAB restart**, because its deadline lives
in a DateTime item rrd4j cannot persist. mapdb is therefore load-bearing for two features, not
optional polish.

Consequence: **after any restart the master switches may come back OFF and nothing will heat**,
with no error anywhere. That is the worst possible failure mode for winter.

**Implemented 2026-09-12 ~22:00 (no restart), with one step left for Christian:**

- [x] **Real root cause found.** "There is no `rrd4j.persist`" was only half true: there is a
      **UI-managed** rrd4j configuration in
      `/var/lib/openhab/jsondb/org.openhab.core.persistence.PersistenceServiceConfiguration.json`
      with `* : restoreOnStartup, everyChange, everyMinute`. That is where the wrong Switch
      restores come from. A managed config **wins over the file**: the new `rrd4j.persist` was
      rejected at 22:00:17 with `Cannot add "PersistenceServiceConfiguration" with key "rrd4j". It
      exists already from provider "ManagedPersistenceServiceConfigurationProvider"`.
- [x] `persistence/mapdb.persist` written: `* : everyChange, everyUpdate, restoreOnStartup`.
      mapdb add-on installed via REST (`POST /rest/addons/persistence-mapdb/install`, 22:01),
      registered as service `mapdb`, storing to `/var/lib/openhab/persistence/mapdb/storage.mapdb`.
      Seeded by re-posting the current state of the 3 masters, 3 targets, 3 `_Comfort`, both
      `StopTemp` and `TooWarm` (all `changed`-triggered, so a same-value update is inert; the
      `_Comfort_120min` items were deliberately NOT re-posted because they are `updated`-triggered).
      Verified via `GET /rest/persistence/items/<item>?serviceId=mapdb`: exact values, e.g.
      `Heating_Kueche_Enabled = ON`, `Heating_Kueche_Target = 19`.
- [x] `persistence/rrd4j.persist` written (everyChange + everyMinute for `*`, **no**
      restoreOnStartup) — but currently **ignored**, see next item.
- [x] **Managed rrd4j config deleted** by Christian at 22:11 (`DELETE /rest/persistence/rrd4j`
      → 200; jsondb file now `{}`). `rrd4j.persist` re-saved and loaded at 22:11:33 with no
      `Cannot add` warning. `GET /rest/persistence/rrd4j` now shows `* : everyChange, everyMinute`
      (no restoreOnStartup); `GET /rest/persistence/mapdb` shows
      `* : everyChange, everyUpdate, restoreOnStartup`. The 22:11:16 WARN `Tried to remove
      strategy container with serviceId 'rrd4j', but it was added by another provider` is the
      DELETE itself, harmless.
- [x] **Proven at the 22:35 restart** (section 0): all three `Heating_*_Enabled` and every other
      seeded item came back exactly. Still unproven: a running `_Comfort_120min` surviving a
      restart with its `_120min_Until` intact — needs a restart while a window is running.
- [x] `persistence/jdbc.persist` fixed: openHAB 5's grammar (checked in
      `org.openhab.core.model.persistence-5.2.1.jar`, `Persistence.xtext`) has **no `default =`**
      in `Strategies` any more; the line was removed. Loaded cleanly at 22:00:23, the first time
      since August. Each item already named `every5Minutes`, so behaviour is as configured.
      Not yet verified that rows actually land in Postgres `oh_persistence`.

## 8. Comfort vs. cool — the household rules, decided 2026-09-12

Christian wants it warm when he is there (lunch, breakfast). Anne prefers it cool and dislikes
seeing the heating on when it is warm outside. These are the agreed reconciliations:

- **Dinner (18:00) heats if EITHER of them is home — deliberate, do not "fix" to `CNOut` only.**
  Christian often comes home late and eats straight away, so the kitchen should already be warm
  when he walks in; Anne being home is enough to pre-heat it. Lunch (12:00) by contrast requires
  Christian, because that is his meal.
  *Accepted edge case: if both are out at 18:00 the kitchen stays cold, so a late arrival to an
  empty flat is not pre-heated.*
- **Weekday breakfast has no cron on purpose.** It is driven by Christian's alarm clock via
  GoodWatch (`rules/goodwatch.rules`), and Anne knows when they get up. Keep that rule.
- **Badezimmer is the standing exception** to "if Christian is out and Anne is home, heating is
  off" — it dries towels. The 23:00 cron while Anne is out is the safety net against forgetting it.
- **The weather veto now runs ALL DAY, not just in the morning** (Anne's requirement). It gates
  the weekend 08:00 morning heating, GoodWatch, Küche lunch, Küche dinner and the weekend 11:00
  Arbeitszimmer. It deliberately does **not** gate: manual switches, the master switch, or
  'Christian returns' — a person asking for heat always gets heat.
  *This supersedes the 2026-09-11 decision "nothing else is weather-checked". Christian approved
  the change on 2026-09-12 with "enable the weather guard for the full day and see how it goes",
  so treat it as an experiment that may be narrowed again.*
- **The weather is re-read at every scheduled event**, not cached once per morning. The old
  per-day global was wiped by every script reload, and an 08:00 reading is meaningless at 18:00.
- **Open idea, not built:** the comfort temperature is one shared number per room, so it cannot
  express "warmer when Christian is alone, cooler when Anne is alone". Now that the target lives
  in `Heating_<Room>_Target` it could be made presence-dependent if the arguing continues.
- [ ] `RadiatorMode` will now read `ON` rather than `COMFORT` whenever the target differs
      from the device's stored `komfort`. Cosmetic, but `jdbc.persist` records it.

## 9. REST API exposure — ANALYSED 2026-09-12, mostly NOT about the tokens

Asked "why revoke, where is the risk?". Answer, so it is not re-derived:

**The tokens are not leaked.** Never tracked in git — `claudebot` appears nowhere outside this
file. `~/.config/openhab/claudebot2.token` is `0600`, owned by cneuhaus, outside the repo.
Do not repeat the earlier framing that linked them to the repo being public; there is no link.

**What the token grants.** Probed live on 2026-09-12 (openHAB 5.2.1):

```
/rest/items        200   <- NO AUTH REQUIRED
/rest/things       401
/rest/rules        401
/rest/inbox        401
/rest/persistence  401
```

`org.openhab.restauth:implicitUserRole` is commented out in `services/runtime.cfg:221`, so it
defaults to **enabled**: any unauthenticated request gets the implicit `user` role. Anyone who can
reach :8080 can already read and command **every item** — heating, lights — with no token.

So the token buys only the admin half. That half includes `POST /rest/rules`, and openHAB rules are
scripts executed in the openHAB JVM ⇒ an admin token is effectively **arbitrary code execution as
the `openhab` user**. That, not "someone turns the radiator on", is the token's blast radius.

- [ ] Revoke both tokens — they were minted for one job (editing the Heating page over REST on
      2026-09-12) which is finished. No expiry, no owner.
- [ ] Delete `~/.config/openhab/claudebot2.token` **and** `~/.config/openhab/.claudebot.token.swp`
      — the latter is a vim swap file holding a copy of the first, malformed token. It will not be
      caught by "delete the .token files".

### The two findings that matter more than the tokens

- [x] **`implicitUserRole` — DONE 2026-09-12 22:26, no restart.** `services/runtime.cfg` now has
      `implicitUserRole=false` + `trustedNetworks=127.0.0.1/32, 192.168.1.0/24` (both lines are
      needed: trustedNetworks is ignored while implicitUserRole is on). Applied live within
      seconds. Verified with `curl --interface <src>` against `/rest/items` unauthenticated:
      LAN 192.168.1.110 → 200, localhost → 200, WireGuard 10.10.0.1 → **401**, with token → 200.
      (A host-side test with `--interface 172.19.0.1` gives 200 — docker's MASQUERADE rewrites
      locally generated packets to 127.0.0.1, test artifact.) From inside the forgejo container
      (172.19.0.3) unauthenticated → **401**, so the docker bridges are really closed.
      VPN clients therefore need a login now — the phone app already authenticates as
      `cneuhaus` (GoodWatch source), so nothing known breaks.
      **Tightened ~22:33:** Christian identified the SmartSwitch as `192.168.1.107`
      (MAC `5c:cf:7f:8a:29:bd`, Espressif = ESP8266). `trustedNetworks` is now
      `127.0.0.1/32, 192.168.1.107/32` — the rest of the LAN needs a login too.
      - [ ] Give `5c:cf:7f:8a:29:bd` a DHCP reservation in the FRITZ!Box (Heimnetz → Netzwerk →
            device → "immer die gleiche IPv4-Adresse zuweisen"); if its address ever changes the
            Arbeitszimmer lamps silently stop reacting (401 is not logged anywhere).
      - [ ] Verify with a real press: events.log must show `SmartSwitch1/2 received command ...
            (source: org.openhab.core.io.rest)`.
      - [ ] When the firmware is next reflashed, give it an API token and drop the `.107` entry.
      Uncommitted.
      Changing it will break anything that talks to REST anonymously — check before flipping it.
      **CHECKED 2026-09-12 22:20 — it WOULD break something. Do NOT flip it as-is.** events.log
      tags every REST command with its source. Across all retained logs (2026-08-02 → 09-12):
      `SmartSwitch1`/`SmartSwitch2` (67 commands) come from `org.openhab.core.io.rest` with NO
      user = **anonymous** — that is the self-built Arbeitszimmer switch device
      (`rules/arbeitszimmer.rules`, Stehlampe + Deckenleuchte). `GoodWatch` (16) comes from
      `org.openhab.core.io.rest$cneuhaus` = authenticated, unaffected. Nothing else uses REST.
      A second review session claimed "no local config depends on unauthenticated REST" — that
      was based on live TCP connections only; the device connects for milliseconds per press.
      Options: (a) give the device an API token / basic auth (allowBasicAuth is on) — needs a
      firmware change on the self-built device; (b) `trustedNetworks=192.168.1.0/24` instead of
      disabling implicitUserRole — keeps the LAN as it is today, blocks docker (172.19/172.20)
      and anything from outside; (c) both. Recommendation: (b) now, (a) when the device is next
      reflashed.
- [ ] **UNVERIFIED — is :8080 reachable from the internet?** openHAB listens on `*:8080` and
      `*:8443` (all interfaces). The firewall could not be read (`sudo ufw status` denied) and the
      router config is not visible from this host. **Check the FRITZ!Box → Internet → Freigaben for
      a port forward to :8080.** If one exists, the anonymous item access above is internet-facing,
      which is a far bigger problem than either token. No openHAB Cloud connector is installed
      (`services/openhabcloud.cfg` absent), so myopenhab is not a path in.

## 2. Stale thing type for Arbeitszimmer

`things/fritzbox.things:11` declares AIN `139790923452` as `FRITZ_DECT_301`, but
`items/fritzbox.items` links it to `avmfritz:FRITZ_DECT_302:...` and the live thing in the
JSONDB is a **302**. It works today because the JSONDB thing wins, but it is a trap for the
next edit.

- [ ] Correct line 11 to `FRITZ_DECT_302`.

## 3. Credentials — CLEARED, earlier entry here was wrong

An earlier version of this file claimed plaintext credentials were still committed. That was
**incorrect** and is retracted. Verified 2026-09-12:

- `things/fritzbox.things` has **0 commits** — it was never tracked. It is in `.gitignore`.
- None of the current passwords (avmfritz, tr064, Postgres) appear anywhere in `git rev-list --all`.
- `services/jdbc.cfg` was tracked until `88ab338`, which removed it and added it to `.gitignore`.
  Its historical password differs from the current one, i.e. it **was rotated**. The value in
  history is dead.

Commit `88ab338` ("remove leaked credentials") did exactly what its title says. The plaintext
passwords in the working tree are expected — openHAB needs them to run, and the files are ignored.

- [ ] Optional hygiene only: `services/runtime.cfg.dpkg-old` is **tracked** in git and has
      uncommitted changes (+30/−6). A Debian packaging backup does not belong in the repo; its
      two `password|token` matches are comment text, not secrets. Consider `git rm` + ignore.
- [ ] `sounds/doorbell.mp3` has an unexplained uncommitted change (102399 → 80005 bytes),
      predating this session.

## 4. Smaller items

- [x] The Badezimmer page exposed only `Heating_Badezimmer_Comfort_120min`. It now carries both
      that and `Heating_Badezimmer_Comfort`, plus the Solltemperatur stepper and master switch.
- [ ] `persistence/jdbc.persist` only persists Arbeitszimmer. Küche and Badezimmer, and all
      `ComfortTemp`/`EcoTemp` items, are not persisted — worth adding before changing the
      heating logic, so there is data to compare against.

## Notes

- Editing `.items` files requires re-running `init.rules` afterwards.
- AVM has migrated `avm.de` → `fritz.com` and renamed the DECT 302 to
  "FRITZ!Smart Thermo 302". Most old knowledge-base deep links now 404; the product
  manual PDFs under `assets.avm.de` still work.

## 0b. PRE-REBOOT BASELINE — captured 2026-09-12 16:47:17 +0200

State immediately BEFORE the 2026-09-12 evening reboot. Compare against this after the
restart: if any `Heating_*_Enabled` differs, the rrd4j restore bug (section 7b) reproduced.

```
ROOM           Enabled   Comfort   120min   Target     SetTemp   Mode     
Arbeitszimmer  ON        OFF       n/a      21 °C     6 °C     OFF      
Badezimmer     ON        OFF       OFF      21 °C     6 °C     OFF      
Kueche         ON        OFF       ON       19 °C     19 °C    COMFORT  

Kueche_120min_Until     2026-09-12T18:40:51.273271+0200
Badezimmer_120min_Until NULL
CNOut=OFF  ANOut=OFF  TooWarm=NULL
outside now=22.1 °C  in 2h=22.1 °C  stops=17 °C / 18 °C
```

Expected after reboot: all three Enabled=ON (you set them at 16:40). Küche 120min should
**resume** to 18:40:51, not restart, if the reboot is before 18:40.

## 10. Slow shutdown — DIAGNOSED 2026-09-12 ~22:25, mitigated via systemd

Every `systemctl stop/restart openhab` (and therefore every reboot) takes the full **2 minutes**
and ends in **SIGKILL**. Journal, both stops on 2026-09-12 (16:18 and 16:48):
`State 'stop-sigterm' timed out. Killing.` → `Failed with result 'timeout'`. The stop on
2026-09-11 21:48 completed cleanly in 20 s, so it is a race, not deterministic.

**Where it hangs** (Equinox thread dump in the journal, identical both times): the
`Framework stop` thread sits in `org.openhab.core.io.net.http.internal.WebClientFactoryImpl.deactivate`
→ `WebSocketClient.doStop` → `HttpClient.doStop` → `AbstractConnectorHttpClientTransport.doStop`
→ `CountDownLatch.await`, forever. Cause in openHAB core 5.2.1: `deactivate()` stops the shared
HTTP client first, which takes the shared `OH-httpClient-common` thread pool down with it, then
stops the shared WebSocket client, whose selector shutdown needs that pool to run — so the latch
never counts down. (`openhab.log` shows the matching `ManagedSelector ClosedSelectorException`
WARN ~19 s after SIGTERM.) Nothing in this config causes it: no binding here uses the common
WebSocket client; it is created eagerly by core. `main` in openhab-core now stops the pool
explicitly last with stop timeout 0, so a later openHAB release may fix it — re-check after the
next upgrade. Not caused by rules, timers or the JRuby script.

**Fix (mitigation):** shorten systemd's stop timeout so the inevitable SIGKILL comes after 60 s
instead of 120 s. A clean stop takes ~20 s; the hang is detectable at 30 s. Data safety is
unchanged: today's stops are already SIGKILLed, just later. Needs root — the override is
`root:root`:

```
! sudo sh -c 'printf "TimeoutStopSec=60\n" >> /etc/systemd/system/openhab.service.d/override.conf' && sudo systemctl daemon-reload && systemctl show openhab -p TimeoutStopUSec
```
(the override already has a `[Service]` section; the line lands inside it.)

- [x] Override applied by Christian 22:33, `TimeoutStopUSec=1min`; the 22:34 restart hung as
      predicted and was killed at 22:35:11, 61 s after `Stopping`.
- [ ] After the next upgrade, check `journalctl -u openhab | grep stop-sigterm` — if the hang is
      gone, the override can stay anyway.
