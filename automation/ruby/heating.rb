# Heating: Arbeitszimmer, Küche, Badezimmer (FRITZ!DECT radiators)
#
# - Switches do exactly what they say: ON → radiator COMFORT, OFF → radiator OFF.
# - Comfort and Comfort_120min of the same room are exclusive: turning one on turns the other off.
# - The outside weather is checked once per morning, by the morning heating (weekend schedule, GoodWatch).

# --- Switch handling ---

def comfort_switched(comfort, timed, radiator, label)
  if comfort.on?
    logger.info("#{label} Comfort ON → COMFORT")
    timed&.ensure&.off
    radiator.ensure.command('COMFORT')
  elsif timed&.on?
    logger.info("#{label} Comfort OFF, 120min still active → radiator stays on")
  else
    logger.info("#{label} Comfort OFF → OFF")
    radiator.ensure.command('OFF')
  end
end

def timed_updated(timed, comfort, radiator, label)
  timer_id = "#{label} 120min"
  if timed.on?
    logger.info("#{label} 120min ON → COMFORT for 120min")
    comfort.ensure.off
    radiator.ensure.command('COMFORT')
    # switching ON again restarts the 120min
    after(120.minutes, id: timer_id) do
      logger.info("#{label} 120min ended")
      timed.off
    end
  else
    timers.cancel(timer_id)
    if comfort.on?
      logger.info("#{label} 120min OFF, Comfort still ON → radiator stays on")
    else
      logger.info("#{label} 120min OFF → OFF")
      radiator.ensure.command('OFF')
    end
  end
end

# --- Morning weather check (once per day) ---

# Stop temperatures are items (Heating_StopTemp_Now / _2h), so they can be changed in the UI
def stop_limit(item, default)
  return item.state if item.state

  logger.warn("#{item.name} has no value → using #{default}")
  default
end

# No heating needed when it's already warm outside or will be within 2h.
# The result is kept in Heating_ToWarm and reused for the rest of the day.
def too_warm_this_morning?
  if $heating_weather_checked_on == Date.today
    logger.info("Weather already checked today → #{Heating_ToWarm.on? ? 'too warm' : 'heating needed'}")
    return Heating_ToWarm.on?
  end

  now = localCurrentTemperature.state
  in_2h = localCurrentTemperature_2h.state
  if now.nil? || in_2h.nil?
    logger.warn("Weather data missing (now: #{now.inspect}, in 2h: #{in_2h.inspect}) → heating as scheduled")
    return false
  end

  stop_now = stop_limit(Heating_StopTemp_Now, 17 | '°C')
  stop_2h = stop_limit(Heating_StopTemp_2h, 18 | '°C')
  too_warm = now >= stop_now || in_2h >= stop_2h
  logger.info("Weather check: now #{now} (stop at #{stop_now}), in 2h #{in_2h} (stop at #{stop_2h}) " \
              "→ #{too_warm ? 'too warm' : 'heating needed'}")
  Heating_ToWarm.update(too_warm ? ON : OFF)
  $heating_weather_checked_on = Date.today
  too_warm
end

def morning_heating(label)
  if too_warm_this_morning?
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
  run do
    comfort_switched(Heating_Arbeitszimmer_Comfort, nil, FRITZDECT3011Arbeitszimmer_RadiatorMode, 'Arbeitszimmer')
  end
end

# --- Küche ---
rule 'Heating Kueche' do
  changed Heating_Kueche_Comfort
  run do
    comfort_switched(Heating_Kueche_Comfort, Heating_Kueche_Comfort_120min,
                     FRITZDECT3011Kueche_RadiatorMode, 'Küche')
  end
end

rule 'Heating Kueche 120min' do
  updated Heating_Kueche_Comfort_120min
  run do
    timed_updated(Heating_Kueche_Comfort_120min, Heating_Kueche_Comfort,
                  FRITZDECT3011Kueche_RadiatorMode, 'Küche')
  end
end

# --- Badezimmer ---
rule 'Heating Badezimmer' do
  changed Heating_Badezimmer_Comfort
  run do
    comfort_switched(Heating_Badezimmer_Comfort, Heating_Badezimmer_Comfort_120min,
                     FRITZDECT3011Badezimmer_RadiatorMode, 'Badezimmer')
  end
end

rule 'Heating Badezimmer 120min' do
  updated Heating_Badezimmer_Comfort_120min
  run do
    timed_updated(Heating_Badezimmer_Comfort_120min, Heating_Badezimmer_Comfort,
                  FRITZDECT3011Badezimmer_RadiatorMode, 'Badezimmer')
  end
end

# Timers are lost when this script is reloaded → restart 120min for switches still ON
rule 'Heating 120min - restart timers on load' do
  on_load
  run do
    [[Heating_Kueche_Comfort_120min, Heating_Kueche_Comfort, FRITZDECT3011Kueche_RadiatorMode, 'Küche'],
     [Heating_Badezimmer_Comfort_120min, Heating_Badezimmer_Comfort, FRITZDECT3011Badezimmer_RadiatorMode, 'Badezimmer']]
      .select { |timed, *| timed.on? }
      .each { |args| timed_updated(*args) }
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

rule 'Heating - Christian returns' do
  changed CNOut, from: ON, to: OFF
  run do
    hour = Time.now.hour
    if hour > 7 && hour <= 22
      logger.info('Christian returns → Heating ON Arbeitszimmer')
      Heating_Arbeitszimmer_Comfort.on
    else
      logger.info("Christian returns, but it's night → no heating")
    end
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

# GoodWatch wake-up (coffee machine: rules/goodwatch.rules)
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
    if CNOut.off?
      Heating_Arbeitszimmer_Comfort.on
      logger.info('Weekend morning → Arbeitszimmer ON')
    else
      logger.info('Weekend → Nobody home')
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
    if CNOut.off?
      Heating_Kueche_Comfort_120min.on
      logger.info('Lunch → Küche ON')
    else
      logger.info('Lunch → Nobody home')
    end
  end
end

rule 'Heating Kueche - Dinner' do
  cron '0 0 18 * * ? *'
  run do
    if CNOut.off? || ANOut.off?
      Heating_Kueche_Comfort_120min.on
      logger.info('Dinner → Küche ON')
    else
      logger.info('Dinner → Nobody home')
    end
  end
end
