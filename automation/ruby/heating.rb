# Heating: Arbeitszimmer, Küche, Badezimmer (FRITZ!DECT radiators)
#
# - Heating_<Room>_Comfort and _Comfort_120min are the "heat now" switches that the automation
#   drives. ON → heat to the room's comfort temperature, OFF → radiator off.
# - Heating_<Room>_Enabled is the master switch. Only an explicit OFF disables a room, and it
#   wins over every automation in this file.
# - The comfort temperature lives in Heating_<Room>_Target (openHAB, UI-editable), NOT in the
#   FRITZ!Box. It is sent to the radiator's set_temp channel. The device's own comfort_temp
#   channel is read-only and deliberately unused.
# - Comfort and Comfort_120min of the same room are exclusive: turning one on turns the other off.
# - The outside weather is checked fresh before EVERY scheduled heating, all day long: weekend
#   morning, GoodWatch, Küche lunch + dinner, weekend Arbeitszimmer. It never gates a person:
#   manual switches, the master switch and 'Christian returns' always heat.

# --- Rooms ---
# Keys are ASCII on purpose, so they can never disagree with the item names (Kueche, not Küche).
# The binding clamps set_temp to 8..28 °C (HeatingModel: TEMP_CELSIUS_MIN/MAX); a value below the
# minimum is clamped UP and does NOT switch the valve off, so "off" always goes via radiator_mode.
CLAMP_MIN = 8 | '°C'
CLAMP_MAX = 28 | '°C'

ROOMS = {
  arbeitszimmer: {
    name: 'Arbeitszimmer',
    comfort: Heating_Arbeitszimmer_Comfort,
    timed: nil,
    mode: Radiator_Arbeitszimmer_RadiatorMode,
    settemp: Radiator_Arbeitszimmer_SetTemp,
    target: Heating_Arbeitszimmer_Target,
    enabled: Heating_Arbeitszimmer_Enabled,
    deadline: nil, # no 120min switch, so no window to remember
    fallback_temp: 21 | '°C'
  },
  kueche: {
    name: 'Küche',
    comfort: Heating_Kueche_Comfort,
    timed: Heating_Kueche_Comfort_120min,
    mode: Radiator_Kueche_RadiatorMode,
    settemp: Radiator_Kueche_SetTemp,
    target: Heating_Kueche_Target,
    enabled: Heating_Kueche_Enabled,
    deadline: Heating_Kueche_120min_Until,
    fallback_temp: 19 | '°C'
  },
  badezimmer: {
    name: 'Badezimmer',
    comfort: Heating_Badezimmer_Comfort,
    timed: Heating_Badezimmer_Comfort_120min,
    mode: Radiator_Badezimmer_RadiatorMode,
    settemp: Radiator_Badezimmer_SetTemp,
    target: Heating_Badezimmer_Target,
    enabled: Heating_Badezimmer_Enabled,
    deadline: Heating_Badezimmer_120min_Until,
    fallback_temp: 21 | '°C'
  }
}.freeze

TARGET_TO_ROOM = ROOMS.to_h { |key, r| [r[:target].name, key] }.freeze

def room(key) = ROOMS.fetch(key)

# --- Switch handling ---

def target_temp(r)
  t = r[:target].state
  if t.nil?
    logger.warn("#{r[:name]}: #{r[:target].name} has no value → using #{r[:fallback_temp]}")
    return r[:fallback_temp]
  end
  return CLAMP_MIN if t < CLAMP_MIN
  return CLAMP_MAX if t > CLAMP_MAX

  t
end

# Deliberately NOT `ensure`: rrd4j restores SetTemp on startup, so the item can claim a
# temperature the valve is not actually at. `ensure` would compare against that stale value,
# skip the command, and the room would never heat while the log claimed it did.
# A few extra DECT commands per day are much cheaper than a cold room.
def heat(r)
  temp = target_temp(r)
  logger.info("#{r[:name]}: set_temp → #{temp} (item was #{r[:settemp].state})")
  r[:settemp].command(temp)
end

def heat_off(r)
  logger.info("#{r[:name]}: radiator_mode → OFF (item was #{r[:mode].state})")
  r[:mode].command('OFF')
end

# The master switch beats everything. Only an explicit OFF disables a room: NULL/UNDEF counts as
# enabled, so a missing value can never silently stop the heating.
def disabled?(r)
  return false unless r[:enabled].off?

  logger.info("#{r[:name]}: master switch is OFF → ignoring")
  true
end

def comfort_switched(key)
  r = room(key)
  if r[:comfort].on?
    if disabled?(r)
      r[:comfort].ensure.off
      heat_off(r) # do not rely on the bounced rule: it may see the other switch still ON
      return
    end
    r[:timed]&.ensure&.off
    heat(r)
  elsif r[:timed]&.on?
    logger.info("#{r[:name]}: Comfort OFF, 120min still active → radiator stays on")
  else
    heat_off(r)
  end
end

# End of a 120min window that is still running, or nil if there is none.
# Any problem reading it degrades to "start a fresh window", i.e. the behaviour we had before.
def running_deadline(r)
  state = r[:deadline]&.state
  return nil if state.nil?

  deadline = state.to_time
  deadline > Time.now ? deadline : nil
rescue StandardError => e
  logger.warn("#{r[:name]}: cannot read the 120min deadline (#{e.message}) → fresh window")
  nil
end

# `resume: true` is used on script load: the remaining time of a window that was already running
# is read back from Heating_<Room>_120min_Until instead of granting a fresh 120 minutes. Without
# it, every reload restarted the full two hours - and we reloaded ten times in one afternoon.
# A real button press (resume: false) always restarts the full window, which is what people expect.
def timed_updated(key, resume: false)
  r = room(key)
  timer_id = "#{r[:name]} 120min"
  if r[:timed].on?
    if disabled?(r)
      r[:timed].ensure.off
      heat_off(r) # see comfort_switched
      return
    end

    deadline = resume ? running_deadline(r) : nil
    if deadline.nil?
      deadline = Time.now + (120 * 60)
      r[:deadline]&.update(deadline)
      logger.info("#{r[:name]}: 120min ON → heating until #{deadline.strftime('%H:%M')}")
    else
      logger.info("#{r[:name]}: 120min resumed after reload → heating until " \
                  "#{deadline.strftime('%H:%M')}")
    end

    r[:comfort].ensure.off
    heat(r)
    after((deadline - Time.now).round.seconds, id: timer_id) do
      logger.info("#{r[:name]}: 120min ended")
      r[:timed].off
    end
  else
    timers.cancel(timer_id)
    if r[:comfort].on?
      logger.info("#{r[:name]}: 120min OFF, Comfort still ON → radiator stays on")
    else
      heat_off(r)
    end
  end
end

# Master switch: OFF → radiator off and automation blocked.
# ON → re-enables the automation and nothing more; it does NOT heat by itself (decided
# 2026-09-12). Use the room's "Heizung ... jetzt" switch to heat right now. This keeps the master
# free of the presence/time/weather guards that every other automatic path has, and it also means
# seeding the item to ON at load can never start heating.
def enabled_switched(key)
  r = room(key)
  if r[:enabled].on?
    logger.info("#{r[:name]}: master switch ON → automation enabled again (does not heat by itself)")
  else
    logger.info("#{r[:name]}: master switch OFF → overrides all automation")
    r[:timed]&.ensure&.off
    r[:comfort].ensure.off
    heat_off(r)
  end
end

# --- Weather check (fresh on every scheduled heating) ---

# Stop temperatures are items (Heating_StopTemp_Now / _2h), so they can be changed in the UI
def stop_limit(item, default)
  return item.state if item.state

  logger.warn("#{item.name} has no value → using #{default}")
  default
end

# No heating needed when it is already warm outside, or will be within 2h.
#
# Checked FRESH on every scheduled heating, all day long (decided 2026-09-12). It used to run once
# per morning and cache the answer in a global, which was wrong twice over: an 08:00 reading is
# worthless at 18:00, and the global was wiped by every script reload anyway.
#
# Missing weather data means "heat as scheduled" on purpose: a failed API call must never be the
# reason the flat stays cold.
def too_warm?(label)
  now = localCurrentTemperature.state
  in_2h = localCurrentTemperature_2h.state
  if now.nil? || in_2h.nil?
    logger.warn("#{label}: weather data missing (now: #{now.inspect}, in 2h: #{in_2h.inspect}) " \
                '→ heating as scheduled')
    Heating_TooWarm.update(OFF)
    return false
  end

  stop_now = stop_limit(Heating_StopTemp_Now, 17 | '°C')
  stop_2h = stop_limit(Heating_StopTemp_2h, 18 | '°C')
  too_warm = now >= stop_now || in_2h >= stop_2h
  logger.info("#{label}: weather now #{now} (stop at #{stop_now}), in 2h #{in_2h} " \
              "(stop at #{stop_2h}) → #{too_warm ? 'TOO WARM, no heating' : 'heating needed'}")
  Heating_TooWarm.update(too_warm ? ON : OFF)
  too_warm
end

def morning_heating(label)
  if too_warm?(label)
    logger.info("#{label} → too warm, no heating")
  else
    logger.info("#{label} → Küche + Bad")
    Heating_Kueche_Comfort_120min.on
    Heating_Badezimmer_Comfort_120min.on
  end
end

# --- Arbeitszimmer ---
rule 'Heating Arbeitszimmer' do
  changed Heating_Arbeitszimmer_Comfort
  run { comfort_switched(:arbeitszimmer) }
end

# --- Küche ---
rule 'Heating Kueche' do
  changed Heating_Kueche_Comfort
  run { comfort_switched(:kueche) }
end

rule 'Heating Kueche 120min' do
  updated Heating_Kueche_Comfort_120min
  run { timed_updated(:kueche) }
end

# --- Badezimmer ---
rule 'Heating Badezimmer' do
  changed Heating_Badezimmer_Comfort
  run { comfort_switched(:badezimmer) }
end

rule 'Heating Badezimmer 120min' do
  updated Heating_Badezimmer_Comfort_120min
  run { timed_updated(:badezimmer) }
end

# --- Master switches (OFF overrides every automation below) ---
rule 'Heating master switch Arbeitszimmer' do
  changed Heating_Arbeitszimmer_Enabled
  run { enabled_switched(:arbeitszimmer) }
end

rule 'Heating master switch Kueche' do
  changed Heating_Kueche_Enabled
  run { enabled_switched(:kueche) }
end

rule 'Heating master switch Badezimmer' do
  changed Heating_Badezimmer_Enabled
  run { enabled_switched(:badezimmer) }
end

# --- Comfort temperature changed in the UI: apply at once if the room is heating ---
rule 'Heating - comfort temperature changed' do
  changed Heating_Arbeitszimmer_Target, Heating_Kueche_Target, Heating_Badezimmer_Target
  run do |event|
    r = room(TARGET_TO_ROOM.fetch(event.item.name))
    next unless r[:comfort].on? || r[:timed]&.on?
    next if disabled?(r)

    heat(r)
  end
end

# --- Presence Control (Christian) ---
# from:/to: ignore NULL → OFF at startup (init.rules: Christian is home)
rule 'Heating - Christian leaves' do
  changed CNOut, from: OFF, to: ON
  run do
    logger.info('Christian left → Arbeitszimmer + Küche OFF (Bad stays as it is)')
    Heating_Arbeitszimmer_Comfort.ensure.off
    Heating_Kueche_Comfort.ensure.off
    Heating_Kueche_Comfort_120min.ensure.off
  end
end

# Arbeitszimmer heats on return, but NOT at night: coming home at 23:00 should not start the
# heating. Every other room simply keeps to its normal schedule - returning home does not start
# them. (The 08:00-22:00 guard is deliberate; it was briefly removed on 2026-09-12 and restored.)
rule 'Heating - Christian returns' do
  changed CNOut, from: ON, to: OFF
  run do
    hour = Time.now.hour
    if hour > 7 && hour <= 22
      logger.info('Christian returns → Arbeitszimmer ON; other rooms keep their schedule')
      Heating_Arbeitszimmer_Comfort.on
    else
      logger.info("Christian returns, but it's night → no heating")
    end
  end
end

# Safety net: the bathroom radiator dries towels and is deliberately left running when the flat
# empties, so it is the one room that can be forgotten. If Anne is out, kill it at night.
rule 'Heating Badezimmer - off at night while Anne is out' do
  cron '0 0 23 * * ? *'
  run do
    next unless ANOut.on?

    logger.info('Night and Anne is out → Badezimmer OFF (safety net against leaving it on)')
    Heating_Badezimmer_Comfort_120min.ensure.off
    Heating_Badezimmer_Comfort.ensure.off
  end
end

# --- Morning Heating ---
rule 'Heating Weekend (FRI-SUN) - Kueche & Bad' do
  cron '0 0 8 ? * FRI,SAT,SUN *'
  run do
    if CNOut.on?
      logger.info('Weekend → Nobody home')
    else
      morning_heating('Good morning weekend')
    end
  end
end

# GoodWatch wake-up (coffee machine: rules/goodwatch.rules).
# This IS the weekday breakfast heating: it is driven by Christian's alarm clock, and Anne knows
# when they get up. There is deliberately no weekday breakfast cron - the alarm clock is the
# schedule. Keep this rule. (decided 2026-09-12)
rule 'Heating GoodWatch' do
  received_command GoodWatch, command: ON
  run do
    if Time.now.hour < 10
      morning_heating('GoodWatch')
    else
      logger.info("GoodWatch → not morning anymore, no heating")
    end
  end
end

# --- Scheduled Heating Rules ---
rule 'Heating - Night Mode' do
  cron '0 0 23-01 * * ? *'
  run do
    Heating_Arbeitszimmer_Comfort.off
    Heating_Kueche_Comfort.off
    Heating_Badezimmer_Comfort.off
    logger.info('Night mode → Arbeitszimmer, Küche, Bad OFF')
  end
end

rule 'Heating Weekend (FRI-SUN) - Arbeitszimmer' do
  cron '0 0 11 ? * FRI,SAT,SUN *'
  run do
    if CNOut.on?
      logger.info('Weekend → Nobody home')
    elsif too_warm?('Weekend Arbeitszimmer')
      logger.info('Weekend Arbeitszimmer → too warm, no heating')
    else
      Heating_Arbeitszimmer_Comfort.on
      logger.info('Weekend morning → Arbeitszimmer ON')
    end
  end
end

rule 'Heating Kueche - Off after dinner' do
  cron '0 0 20 * * ? *'
  run do
    Heating_Kueche_Comfort.off
    logger.info('After Dinner → Küche OFF')
  end
end

rule 'Heating Kueche - Lunch' do
  cron '0 0 12 * * ? *'
  run do
    if CNOut.on?
      logger.info('Lunch → Christian not home, no heating')
    elsif too_warm?('Lunch')
      logger.info('Lunch → too warm, no heating')
    else
      Heating_Kueche_Comfort_120min.on
      logger.info('Lunch → Küche ON')
    end
  end
end

# The "either of us is home" condition is DELIBERATE (decided 2026-09-12), unlike lunch which
# requires Christian. Reason: Christian often comes home late and eats straight away, so the
# kitchen should already be warm when he walks in - Anne being home is enough to pre-heat it.
# Known edge case, accepted: if BOTH are out at 18:00 the kitchen stays cold, so a late arrival
# to an empty flat is not pre-heated.
rule 'Heating Kueche - Dinner' do
  cron '0 0 18 * * ? *'
  run do
    if CNOut.on? && ANOut.on?
      logger.info('Dinner → Nobody home')
    elsif too_warm?('Dinner')
      logger.info('Dinner → too warm, no heating')
    else
      Heating_Kueche_Comfort_120min.on
      logger.info('Dinner → Küche ON')
    end
  end
end

# --- Re-assert: make the valve do what openHAB believes it should ---------------------------
#
# "Re-assert" = look at the room's switches and command the valve accordingly. It is the SAME
# logic in two situations:
#
#   1. this script (re)loads              -> for every room whose valve is already reachable
#   2. a valve thing goes ONLINE          -> for that one room (cold boot, FRITZ!Box reboot)
#
# WHY TWO SITUATIONS?  At a cold boot this script loads about 40 s BEFORE the FRITZ!Box has been
# polled for the first time. Commanding a valve in that gap makes the avmfritz binding throw
# (NullPointerException: getHkr() is null - seen on 2026-09-12 at 16:51 and again at 22:36).
# So on load we can only handle rooms that are already reachable; the rest are handled the moment
# their thing turns ONLINE, which is exactly when the binding has received the first device data.
#
# WHY NOT "is the mode item still NULL?" (the old check)?  Since 2026-09-12 mapdb restores every
# item's last value at boot, BEFORE the first poll - so the item has a value while the binding
# still has no device data. Only the thing status tells the truth.
#
# WHAT IT DOES for one room, first match wins:
#   120min window ON  -> re-arm the timer with the REMAINING time and heat     (timed_updated)
#   Comfort ON        -> heat                                                  (comfort_switched)
#   neither           -> valve OFF. After a restart the valve may still be heating from before
#                        openHAB went down (seen 2026-09-12 16:34: Arbeitszimmer at 21 °C while
#                        openHAB said "off"). If openHAB says off, the valve must agree.
def reassert(key)
  r = room(key)
  if r[:timed]&.on?
    timed_updated(key, resume: true) # resume: keep the old deadline, do not grant a fresh 2h
  elsif r[:comfort].on?
    comfort_switched(key)
  else
    heat_off(r)
  end
end

# "Is this room's valve reachable?"  The thing linked to the room's mode item must be ONLINE.
# (No thing UIDs are written down here on purpose - the item link already knows its thing.)
def valve_online?(r)
  r[:mode].thing&.online? || false
end

# Situation 2: a valve thing has just turned ONLINE. Runs for ANY thing going online, so it first
# checks whether the thing belongs to one of our rooms and ignores everything else (astro, mqtt…).
rule 'Heating - valve came online → re-assert its room' do
  changed things, to: :online
  run do |event|
    key, r = ROOMS.find { |_key, room| room[:mode].thing&.uid == event.thing.uid }
    next unless key # not one of our valves

    logger.info("#{r[:name]}: valve thing is online → re-asserting")
    reassert(key)
  end
end

# --- Load-time setup -------------------------------------------------------
# Note for testing: openHAB's script watcher reacts to a CONTENT change, not to mtime. `touch`
# alone will NOT reload this file - edit something real, or restart openHAB.
# Deliberately the LAST rule in this file: on_load runs its block inline while the script is
# loading, so an exception here aborts <main> and every rule defined after it is silently
# dropped. Keeping it last means a failure can only cost us the setup, not the automation.
# The rescue makes even that survivable.
rule 'Heating - defaults and timers on load' do
  on_load
  run do
    begin
      ROOMS.each_value do |r|
        if r[:enabled].state.nil?
          logger.info("#{r[:name]}: master switch had no value → ON")
          r[:enabled].update(ON)
        end
        if r[:target].state.nil?
          logger.info("#{r[:name]}: comfort temperature had no value → #{r[:fallback_temp]}")
          r[:target].update(r[:fallback_temp])
        end
      end

      # update() is asynchronous, so the states written above may not have landed yet. That is
      # safe here only because disabled? keys on an explicit OFF: a not-yet-landed NULL counts
      # as enabled, so a restored 120min switch can never be bounced off by a lost race.

      # Situation 1 of "re-assert" (see the big comment above `def reassert`): every room whose
      # valve is already reachable. Rooms that are not reachable yet are NOT forgotten - the rule
      # 'Heating - valve came online' does them the moment the binding has polled.
      ROOMS.each_key do |key|
        r = room(key)
        unless valve_online?(r)
          logger.info("#{r[:name]}: valve thing not online yet → re-assert waits for it")
          next
        end
        reassert(key)
      end
    rescue StandardError => e
      logger.error("Heating on_load failed: #{e.class}: #{e.message} — #{e.backtrace&.first}")
    end
  end
end
