require 'set'

module DatastaxRails
  class Column
    TRUE_VALUES = [true, 1, '1', 't', 'T', 'true', 'TRUE', 'on', 'ON'].to_set
    FALSE_VALUES = [false, 0, '0', 'f', 'F', 'false', 'FALSE', 'off', 'OFF'].to_set
    
    module Format
      ISO_DATE = /\A(\d{4})-(\d\d)-(\d\d)\z/
      ISO_DATETIME = /\A(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)(\.\d+)?\z/
    end

    attr_reader :name, :default, :type, :cql_type, :solr_type
    attr_accessor :primary, :coder

    alias :encoded? :coder

    # Instantiates a new column in the table.
    #
    # +name+ is the column's name as specified in the schema. e.g., 'first_name' in
    # <tt>first_name text</tt>.
    # +default+ is the type-casted default value that will be applied to a new record
    # if no value is given.
    # +type+ is the type of the column. Usually this will match the cql_type, but
    # there are exceptions (e.g., date)
    # +cql_type+ is the type of column as specified in the schema. e.g., 'text' in
    # <tt>first_name text</tt>.
    # +solr_type+ overrides the normal CQL <-> SOLR type mapping (uncommon)
    def initialize(name, default, type, options = {})#cql_type = nil, solr_type = nil)
      @name      = name
      @type      = type.to_sym
      @cql_type  = cql_type(type, options)
      @solr_type = solr_type(type, options)
      @default   = extract_default(default)
      @options   = options
      @primary   = nil
      @coder     = nil
    end
    
    # Returns +true+ if the column is either of type ascii or text.
    def text?
      [:ascii, :text].include?(type)
    end

    # Returns +true+ if the column is either of type integer, float or decimal.
    def number?
      [:decimal, :double, :float, :integer].include?(type)
    end

    def has_default?
      !default.nil?
    end

    # Returns the Ruby class that corresponds to the abstract data type.
    def klass
      case type
      when :integer                        then Fixnum
      when :float                          then Float
      when :decimal, :double               then BigDecimal
      when :timestamp, :time, :datetime    then Time
      when :date                           then Date
      when :text, :string, :binary, :ascii then String
      when :boolean                        then Object
      when :uuid                           then ::Cql::Uuid
      when :list, :set                     then Array
      when :map                            then Hash
      end
    end

    # Casts value (which can be a String) to an appropriate instance.
    def type_cast(value)
      return nil if value.nil?
      return coder.load(value) if encoded?

      klass = self.class

      case type
      when :string, :text        then value
      when :ascii                then value.force_encoding('ascii')
      when :integer              then klass.value_to_integer(value)
      when :float                then value.to_f
      when :decimal              then klass.value_to_decimal(value)
      when :datetime, :timestamp then klass.string_to_time(value)
      when :time                 then klass.string_to_dummy_time(value)
      when :date                 then klass.value_to_date(value)
      when :binary               then klass.binary_to_string(value)
      when :boolean              then klass.value_to_boolean(value)
      when :uuid, :timeuuid      then klass.value_to_uuid(value)
      when :list                 then klass.value_to_list(value)
      when :set                  then klass.value_to_set(value)
      when :map                  then klass.value_to_map(value)
      else value
      end
    end

    # Returns the human name of the column name.
    #
    # ===== Examples
    #  Column.new('sales_stage', ...).human_name # => 'Sales stage'
    def human_name
      Base.human_attribute_name(@name)
    end

    def extract_default(default)
      type_cast(default)
    end

    # Used to convert from Strings to BLOBs
    def string_to_binary(value)
      self.class.string_to_binary(value)
    end

    class << self
      # Used to convert from Strings to BLOBs
      def string_to_binary(value)
        # TODO: Figure out what Cassandra's blobs look like
        value
      end

      # Used to convert from BLOBs to Strings
      def binary_to_string(value)
        # TODO: Figure out what Cassandra's blobs look like
        value
      end

      def value_to_date(value)
        if value.is_a?(String)
          return nil if value.empty?
          fast_string_to_date(value) || fallback_string_to_date(value)
        elsif value.respond_to?(:to_date)
          value.to_date
        else
          value
        end
      end

      def string_to_time(string)
        return string unless string.is_a?(String)
        return nil if string.empty?

        fast_string_to_time(string) || fallback_string_to_time(string)
      end
      
      def string_to_dummy_time(string)
        return string unless string.is_a?(String)
        return nil if string.empty?

        dummy_time_string = "2000-01-01 #{string}"

        fast_string_to_time(dummy_time_string) || begin
          time_hash = Date._parse(dummy_time_string)
          return nil if time_hash[:hour].nil?
          new_time(*time_hash.values_at(:year, :mon, :mday, :hour, :min, :sec, :sec_fraction))
        end
      end

      # convert something to a boolean
      def value_to_boolean(value)
        if value.is_a?(String) && value.empty?
          nil
        else
          TRUE_VALUES.include?(value)
        end
      end

      # Used to convert values to integer.
      def value_to_integer(value)
        case value
        when TrueClass, FalseClass
          value ? 1 : 0
        else
          value.to_i rescue nil
        end
      end

      # convert something to a BigDecimal
      def value_to_decimal(value)
        # Using .class is faster than .is_a? and
        # subclasses of BigDecimal will be handled
        # in the else clause
        if value.class == BigDecimal
          value
        elsif value.respond_to?(:to_d)
          value.to_d
        else
          value.to_s.to_d
        end
      end

      protected
        # '0.123456' -> 123456
        # '1.123456' -> 123456
        def microseconds(time)
          time[:sec_fraction] ? (time[:sec_fraction] * 1_000_000).to_i : 0
        end

        def new_date(year, mon, mday)
          if year && year != 0
            Date.new(year, mon, mday) rescue nil
          end
        end

        def new_time(year, mon, mday, hour, min, sec, microsec, offset = nil)
          # Treat 0000-00-00 00:00:00 as nil.
          return nil if year.nil? || (year == 0 && mon == 0 && mday == 0)

          if offset
            time = Time.utc(year, mon, mday, hour, min, sec, microsec) rescue nil
            return nil unless time

            time -= offset
            Base.default_timezone == :utc ? time : time.getlocal
          else
            Time.public_send(Base.default_timezone, year, mon, mday, hour, min, sec, microsec) rescue nil
          end
        end

        def fast_string_to_date(string)
          if string =~ Format::ISO_DATE
            new_date $1.to_i, $2.to_i, $3.to_i
          end
        end

        # Doesn't handle time zones.
        def fast_string_to_time(string)
          if string =~ Format::ISO_DATETIME
            microsec = ($7.to_r * 1_000_000).to_i
            new_time $1.to_i, $2.to_i, $3.to_i, $4.to_i, $5.to_i, $6.to_i, microsec
          end
        end

        def fallback_string_to_date(string)
          new_date(*::Date._parse(string, false).values_at(:year, :mon, :mday))
        end

        def fallback_string_to_time(string)
          time_hash = Date._parse(string)
          time_hash[:sec_fraction] = microseconds(time_hash)

          new_time(*time_hash.values_at(:year, :mon, :mday, :hour, :min, :sec, :sec_fraction))
        end
    end
    
    private
      def cql_type(field_type, options)
        options[:cql_type] || case type
        when :integer                        then 'int'
        when :time, :date                    then 'timestamp' 
        when :binary                         then 'blob'
        when :list                           then "list<#{options[:type] || text}>"
        when :set                            then "set<#{options[:type] || text}>"
        when :map                            then "map<#{options[:from_type] || text}, #{options[:to_type] || text}>"
        when :string                         then 'text'
        else field_type.to_s
        end
      end
      
      def solr_type(field_type, options)
        options[:solr_type] || case type
        when :integer                        then 'int'
        when :decimal                        then 'double'
        when :timestamp, :time               then 'date'
        when :list, :set                     then options[:type].to_s || 'string'
        when :map                            then options[:to_type].to_s || 'string'
        else field_type.to_s
        end
      end
  end
end