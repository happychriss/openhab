require 'ostruct'

# Timers
$bathroom_timer = OpenStruct.new(value: nil)
$kitchen_timer = OpenStruct.new(value: nil)

def should_heat(heating_switch, radiator, temp_now, temp_2h, temp_limit, label)
  if heating_switch.on?
    logger.info("#{label} ON - evaluating temperature...")
    logger.info("Temp now: #{temp_now.state}, in 2h: #{temp_2h.state}")
    if temp_now.state.to_f < temp_limit && temp_2h.state.to_f < (temp_limit + 1)
      logger.info("#{label}: cold enough → COMFORT")
      radiator.command('COMFORT')
      Heating_ToWarm.off
      true
    else
      logger.info("#{label}: too warm → OFF")
      radiator.command('OFF')
      Heating_ToWarm.on
      false
    end
  else
    logger.info("#{label} OFF - switching OFF radiator")
    radiator.command('OFF')
    Heating_ToWarm.off
    false
  end
end

def comfort_120min(heating_switch, radiator, temp_now, temp_2h, temp_limit, label, timer_var)
  if should_heat(heating_switch, radiator, temp_now, temp_2h, temp_limit, label)
    timer_var.value&.cancel
    timer_var.value = after(120.minutes) do
      logger.info("#{label} 120min timer ended → OFF")
      radiator.command('OFF')
      heating_switch.off
      timer_var.value = nil
    end
  else
    radiator.command('OFF')
    timer_var.value&.cancel
    timer_var.value = nil
  end
end

# --- Arbeitszimmer ---
rule 'Heating Arbeitszimmer' do
  changed Heating_Arbeitszimmer_Comfort
  run do
    should_heat(Heating_Arbeitszimmer_Comfort, FRITZDECT3011Arbeitszimmer_RadiatorMode,
                localCurrentTemperature, localCurrentTemperature_2h, 22, 'Arbeitszimmer')
  end
end

# --- Küche ---
rule 'Heating Kueche' do
  changed Heating_Kueche_Comfort
  run do
    should_heat(Heating_Kueche_Comfort, FRITZDECT3011Kueche_RadiatorMode,
          localCurrentTemperature, localCurrentTemperature_2h, 17, 'Küche')
  end
end

# --- Badezimmer ---
rule 'Heating Badezimmer' do
  changed Heating_Badezimmer_Comfort
  run do
    should_heat(Heating_Badezimmer_Comfort, FRITZDECT3011Badezimmer_RadiatorMode,
                localCurrentTemperature, localCurrentTemperature_2h, 17, 'Badezimmer')
  end
end

# --- Badezimmer 120min ---
rule 'Heating Badezimmer 120min' do
  updated Heating_Badezimmer_Comfort_120min
  run do
    comfort_120min(Heating_Badezimmer_Comfort_120min, FRITZDECT3011Badezimmer_RadiatorMode,
                   localCurrentTemperature, localCurrentTemperature_2h, 17, 'Badezimmer', $bathroom_timer)
  end
end

# --- Küche 120min ---
rule 'Heating Kueche 120min' do
  updated Heating_Kueche_Comfort_120min
  run do
    comfort_120min(Heating_Kueche_Comfort_120min, FRITZDECT3011Kueche_RadiatorMode,
                   localCurrentTemperature, localCurrentTemperature_2h, 17, 'Küche', $kitchen_timer)
  end
end

# --- Presence Control (Christian) ---
rule 'Heating - When Christian comes home' do
  changed CNOut
  run do
    if CNOut.on?
      logger.info('Christian left → Heating OFF')
      Heating_Arbeitszimmer_Comfort.off
    else
      hour = Time.now.hour
      if hour > 7 && hour <= 22
        logger.info('Christian returns → Heating ON')
        Heating_Arbeitszimmer_Comfort.on
      else
        logger.info("Christian returns, but it's night → no heating")
      end
    end
  end
end

rule 'Heating - Christian is out' do
  changed CNOut
  run do
    if CNOut.on?
      Heating_Kueche_Comfort.off
      Heating_Badezimmer_Comfort.off
      logger.info('Christian out → Küche + Bad OFF')
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
    logger.info('Night mode → Arbeitszimmer OFF')
  end
end

rule 'Heating Weekend (FRI-SUN)- Arbeitszimmer' do
  cron '0 0 11 ? * FRI, SAT,SUN *'
  run do
    if CNOut.off?
      Heating_Arbeitszimmer_Comfort.on
      logger.info('Weekend morning → Arbeitszimmer ON')
    end
  end
end

rule 'Heating Weekend (FRI-SUN) -Kueche & BZ' do
  cron '0 45 8 ? * FRI,SAT,SUN *'
  run do
    if CNOut.off?
      Heating_Kueche_Comfort_120min.on
      Heating_Badezimmer_Comfort_120min.on
      logger.info('Good morning weekend → Küche + BAD')
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