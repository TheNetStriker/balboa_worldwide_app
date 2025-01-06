# frozen_string_literal: true

module BWA
  module Messages
    class Status < Message
      attr_accessor :hold,
                    :priming,
                    :notification,
                    :heating_mode,
                    :twenty_four_hour_time,
                    :filter_cycles,
                    :heating,
                    :temperature_range,
                    :hour,
                    :minute,
                    :circulation_pump,
                    :blower,
                    :pumps,
                    :lights,
                    :mister,
                    :aux,
                    :current_temperature,
                    :target_temperature
      attr_reader :temperature_scale
      alias_method :hold?, :hold
      alias_method :priming?, :priming
      alias_method :twenty_four_hour_time?, :twenty_four_hour_time
      alias_method :heating?, :heating

      MESSAGE_TYPE = "\xaf\x13".b
      # additional features have been added in later versions
      MESSAGE_LENGTH = (23..32).freeze

      NOTIFICATIONS = {
        0x00 => nil,
        0x0a => :ph,
        0x04 => :filter,
        0x09 => :sanitizer
      }.freeze

      def initialize
        super

        @src = 0xff
        self.hold = false
        self.priming = false
        self.notification = nil
        self.heating_mode = :ready
        @temperature_scale = :fahrenheit
        self.twenty_four_hour_time = false
        self.filter_cycles = Array.new(2, false)
        self.heating = false
        self.temperature_range = :high
        self.hour = self.minute = 0
        self.circulation_pump = false
        self.pumps = Array.new(6, 0)
        self.lights = Array.new(2, false)
        self.mister = false
        self.aux = Array.new(2, false)
        self.target_temperature = 100
      end

      def log?
        BWA.verbosity >= 1
      end

      def parse(data)
        flags = data[0].ord
        self.hold = (flags & 0x05 != 0)

        self.priming = data[1].ord == 0x01
        flags = data[5].ord
        self.heating_mode = case flags & 0x03
                            when 0x00 then :ready
                            when 0x01 then :rest
                            when 0x02 then :ready_in_rest
                            end
        self.notification = data[1].ord == 0x03 && NOTIFICATIONS[data[6].ord]
        flags = data[9].ord
        self.temperature_scale = (flags & 0x01 == 0x01) ? :celsius : :fahrenheit
        self.twenty_four_hour_time = (flags & 0x02 == 0x02)
        filter_cycles[0] = (flags & 0x04 != 0)
        filter_cycles[1] = (flags & 0x08 != 0)
        flags = data[10].ord
        self.heating = (flags & 0x30 != 0)
        self.temperature_range = (flags & 0x04 == 0x04) ? :high : :low
        flags = data[11].ord
        pumps[0] = flags & 0x03
        pumps[1] = (flags >> 2) & 0x03
        pumps[2] = (flags >> 4) & 0x03
        pumps[3] = (flags >> 6) & 0x03
        flags = data[12].ord
        pumps[4] = flags & 0x03
        pumps[5] = (flags >> 2) & 0x03

        flags = data[13].ord
        self.circulation_pump = (flags & 0x02 == 0x02)
        self.blower = (flags >> 2) & 0x03
        flags = data[14].ord
        lights[0] = (flags & 0x03 != 0)
        lights[1] = ((flags >> 2) & 0x03 != 0)
        flags = data[15].ord
        self.mister = (flags & 0x01 == 0x01)
        aux[0] = (flags & 0x08 != 0)
        aux[1] = (flags & 0x10 != 0)
        self.hour = data[3].ord
        self.minute = data[4].ord
        self.current_temperature = data[2].ord
        self.current_temperature = nil if current_temperature == 0xff
        self.target_temperature = data[20].ord

        return unless temperature_scale == :celsius

        self.current_temperature /= 2.0 if current_temperature
        self.target_temperature /= 2.0 if target_temperature
      end

      def serialize
        data = "\x00" * 24
        data[0] = (hold ? 0x05 : 0x00).chr
        data[1] = if priming
                    0x01
                  elsif notification
                    0x04
                  else
                    0x00
                  end.chr
        data[5] = { ready: 0x00,
                    rest: 0x01,
                    ready_in_rest: 0x02 }[heating_mode].chr
        data[6] = NOTIFICATIONS.invert[notification].chr
        flags = 0
        flags |= 0x01 if temperature_scale == :celsius
        flags |= 0x02 if twenty_four_hour_time
        data[9] = flags.chr
        flags = 0
        flags |= 0x30 if heating
        flags |= 0x04 if temperature_range == :high
        data[10] = flags.chr
        flags = 0
        flags |= pump1
        flags |= pump2 * 4
        data[11] = flags.chr
        flags = 0
        flags |= 0x02 if circulation_pump
        data[13] = flags.chr
        flags = 0
        flags |= 0x03 if light1
        data[14] = flags.chr
        data[3] = hour.chr
        data[4] = minute.chr
        if temperature_scale == :celsius
          data[2] = (current_temperature ? (current_temperature * 2).to_i : 0xff).chr
          data[20] = (target_temperature * 2).to_i.chr
        else
          data[2] = (current_temperature.to_i || 0xff).chr
          data[20] = target_temperature.to_i.chr
        end

        super(data)
      end

      def temperature_scale=(value)
        if value != @temperature_scale
          if value == :fahrenheit
            if current_temperature
              self.current_temperature *= 9.0 / 5
              self.current_temperature += 32
              self.current_temperature = current_temperature.round
            end
            self.target_temperature *= 9.0 / 5
            self.target_temperature += 32
            self.target_temperature = target_temperature.round
          else
            if current_temperature
              self.current_temperature -= 32
              self.current_temperature *= 5.0 / 90
              self.current_temperature = (current_temperature * 2).round / 2.0
            end
            self.target_temperature -= 32
            self.target_temperature *= 5.0 / 9
            self.target_temperature = (target_temperature * 2).round / 2.0
          end
        end
        @temperature_scale = value
      end

      def inspect
        items = []

        items << "hold" if hold
        items << "priming" if priming
        items << "notification=#{notification}" if notification
        items << self.class.format_time(hour, minute, twenty_four_hour_time: twenty_four_hour_time)
        items << "#{current_temperature || "--"}/#{target_temperature}°#{temperature_scale.to_s[0].upcase}"
        items << "filter_cycles=#{filter_cycles.inspect}"
        items << heating_mode
        items << "heating" if heating
        items << temperature_range
        items << "circulation_pump" if circulation_pump
        items << "blower=#{blower}"
        items << "pumps=#{pumps.inspect}"
        items << "lights=#{lights.inspect}"
        items << "aux=#{aux.inspect}"
        items << "mister" if mister

        "#<BWA::Messages::Status #{items.join(" ")}>"
      end
    end
  end
end
