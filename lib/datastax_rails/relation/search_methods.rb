module DatastaxRails
  # +Relation+ methods for incrementally building up a search query.
  module SearchMethods
    # By default, Cassandra will throw an error if you try to set a where condition
    # on either a column with no index or on more than one column that isn't part
    # of the primary key. If you are confident that the number of records that need
    # to be searched is low, then you can instruct it to ignore the warning.  Generally
    # you only want to do this when either the number of records in the table is very
    # small or when one of the other where conditions that has an index will reduce the
    # number of records to a small number.
    #
    #   Model.where(:name => 'johndoe', :active => true).allow_filtering
    #
    # NOTE that this only applies when doing a search via a cassandra index.
    #
    # @return [DatastaxRails::Relation] a new Relation object
    def allow_filtering
      clone.tap do |r|
        r.allow_filtering_value = true
      end
    end

    # The default consistency level for DSR is QUORUM when searching by ID.
    # For all searches using SOLR, the default consistency is ONE.  Use this
    # to override it in either case.
    #
    #   Model.consistency(:local_quorum).find("12345")
    #
    # Note that Solr searches don't allow you to specify the consistency level.
    # DSR sort of gets around this by taking the search results and then going
    # to Cassandra to retrieve the objects by ID using the consistency you specified.
    # However, it is possible that you might not get all of the records you are
    # expecting if the SOLR node you were talking to hasn't been updated yet with
    # the results. In practice, this should not happen for records that were created
    # over your connection, but it is possible for other connections to create records
    # that you can't see yet.
    #
    # Valid consistency levels are:
    # * :any
    # * :one
    # * :quorum
    # * :local_quorum (if using Network Topology)
    # * :each_quorum (if using Network Topology)
    # * :all
    #
    # @param level [Symbol, String] the level to set the consistency at
    # @return [DatastaxRails::Relation] a new Relation object
    def consistency(level)
      level = level
      unless self.valid_consistency?(level)
        fail ArgumentError, "'#{level}' is not a valid Cassandra consistency level"
      end

      clone.tap do |r|
        r.consistency_value = level
      end
    end

    # Normally special characters (other than wild cards) are escaped before the search
    # is submitted.  If you want to handle escaping yourself because you need to use
    # those special characters, then just include this in your chain.
    #
    #   Model.dont_escape.where(:name => "(some stuff I don\'t want escaped)")
    #
    # Note that fulltext searches are NEVER escaped.  Use Relation.solr_escape if you
    # want that done.
    #
    # @return [DatastaxRails::Relation] a new Relation object
    def dont_escape
      clone.tap do |r|
        r.escape_value = false
      end
    end

    # Used to extend a scope with additional methods, either through
    # a module or a block provided
    #
    # The object returned is a relation which can be further extended
    #
    # @param modules [Proc] one or more proc objects
    # @return [DatastaxRails::Relation] a new Relation object
    def extending(*modules)
      modules << Module.new(&Proc.new) if block_given?

      return self if modules.empty?

      clone.tap do |r|
        r.send(:apply_modules, modules.flatten)
      end
    end

    # Limit a single page to +value+ records
    #
    #   Model.limit(1)
    #   Model.per_page(50)
    #
    # Normally DatastaxRails searches are paginated at a really high number
    # so as to effectively disable pagination.  However, you can cause
    # all requests to be paginated on a per-model basis by overriding the
    # +default_page_size+ class method in your model:
    #
    #   class Model < DatastaxRails::Base
    #     def self.default_page_size
    #       30
    #     end
    #   end
    #
    # @param value [String, Fixnum] the number of records to include on a page
    # @return [DatastaxRails::Relation] a new Relation object
    def limit(value)
      clone.tap do |r|
        r.per_page_value = value.to_i
      end
    end
    alias_method :per_page, :limit

    # Sets the page number to retrieve
    #
    #   Model.page(2)
    #
    # @param value [String, Fixnum] the page number to retrieve
    # @return [DatastaxRails::Relation] a new Relation object
    def page(value)
      clone.tap do |r|
        r.page_value = value.to_i
      end
    end

    # WillPaginate compatible method for paginating
    #
    #   Model.paginate(page: 2, per_page: 10)
    #
    # @param options [Hash] the options to pass to paginate
    # @option options [String, Fixnum] :page the page number to retrieve
    # @option options [String, Fixnum] :per_page the number of records to include on a page
    # @return [DatastaxRails::Relation] a new Relation object
    def paginate(options = {})
      options = options.reverse_merge(page: 1, per_page: 30)
      clone.tap do |r|
        r.page_value = options[:page]
        r.per_page_value = options[:per_page]
      end
    end

    # Group results by a given attribute only returning the top results
    # for each group. In Lucene, this is often referred to as Field Collapsing.
    #
    # This modifies the behavior of pagination. When using a group, +per_page+ will
    # specify the number of results returned *for each group*. In addition, +page+
    # will move all groups forward by one page possibly resulting in some groups
    # showing up empty if they have fewer matching entires than others.
    #
    # When grouping is being used, the sort values will be used to sort results within
    # a given group. Any sorting of the groups themselves will need to be handled
    # after-the-fact as the groups are returned as hash of Collection objects.
    #
    # Because SOLR is doing the grouping work, we can only group on single-valued
    # fields (i.e., not +text+ or collections). In the future, SOLR may
    # support grouping on multi-valued fields.
    #
    # NOTE: Group names will be lower-cased
    #
    #   Model.group(:program_id)
    #
    # The object the hash entries point to will be a DatastaxRails::Collection
    #
    # @param attribute [Symbol, String] the attribute to group by
    # @return [DatastaxRails::Relation] a new Relation object
    def group(attribute)
      return self if attribute.blank?

      clone.tap do |r|
        r.group_value = attribute
      end
    end

    # Orders the result set by a particular attribute.  Note that text fields
    # may not be used for ordering as they are tokenized.  Valid candidates
    # are fields of type +string+, +integer+, +long+, +float+, +double+, and
    # +time+.  In addition, the symbol +:score+ can be used to sort on the
    # relevance rating returned by Solr.  The default direction is ascending
    # but may be reversed by passing a hash where the field is the key and
    # the value is :desc
    #
    #   Model.order(:name)
    #   Model.order(name: :desc)
    #
    # WARNING: If this call is combined with #with_cassandra, you can only
    # order on the cluster_by column.  If this doesn't mean anything to you,
    # then you probably don't want to use these together.
    #
    # @param attribute [Symbol, String, Hash] the attribute to sort by and optionally the direction to sort in
    # @return [DatastaxRails::Relation] a new Relation object
    def order(attribute)
      return self if attribute.blank?

      clone.tap do |r|
        r.order_values << (attribute.is_a?(Hash) ? attribute : { attribute.to_sym => :asc })
      end
    end

    # Orders the result set in memory after all matching records have been
    # retrieved.
    #
    # This means that limit is ignored until the end.  ALL matching records WILL
    # be retrieved and sorted before taking #limit records and returning them to
    # the caller.
    #
    # Why would you do this?  If you are retrieving records from a cassandra index
    # but don't have the appropriate clustering order you can use this, but you should
    # only do so if you are confident that the number of records returned will be low.
    #
    # A warning will be printed to the log if this results in a very inefficient operation.
    #
    # USE WITH CARE!!!!!!
    #
    # @param attribute [Symbol, String, Hash] the attribute to sort by and optionally the direction to sort in
    # @return [DatastaxRails::Relation] a new Relation object
    def slow_order(attribute)
      return self if attribute.blank?
      clone.tap do |r|
        r.slow_order_values << (attribute.is_a?(Hash) ? attribute : { attribute.to_sym => :asc })
      end
    end

    # Works in two unique ways.
    #
    # _First_: takes a block so it can be used just like Array#select.
    #
    #   Model.scoped.select { |m| m.field == value }
    #
    # This will build an array of objects from the database for the scope,
    # converting them into an array and iterating through them using Array#select.
    #
    # _Second_: Modifies the query so that only certain fields are retrieved:
    #
    #   >> Model.select(:field)
    #   => [#<Model field:value>]
    #
    # Although in the above example it looks as though this method returns an
    # array, it actually returns a relation object and can have other query
    # methods appended to it, such as the other methods in DatastaxRails::SearchMethods.
    #
    # This method will also take multiple parameters:
    #
    #   >> Model.select(:field, :other_field, :and_one_more)
    #   => [#<Model field: "value", other_field: "value", and_one_more: "value">]
    #
    # Any attributes that do not have fields retrieved by a select
    # will return `nil` when the getter method for that attribute is used:
    #
    #   >> Model.select(:field).first.other_field
    #   => nil
    #
    # The exception to this rule is when an attribute is lazy-loaded (e.g., binary).
    # In that case, it is never retrieved until you call the getter method.
    def select(*fields)
      if block_given?
        to_a.select { |*block_args| yield(*block_args) }
      else
        railse ArgumentError, 'Call this with at least one field' if fields.empty?
        clone.tap do |r|
          r.select_values += fields
        end
      end
    end

    # Reverses the order of the results. The following are equivalent:
    #
    #   Model.order(:name).reverse_order
    #   Model.order(name: :desc)
    #
    #   Model.order(:name).reverse_order.reverse_order
    #   Model.order(name: :asc)
    #
    # @return [DatastaxRails::Relation] a new Relation object
    def reverse_order
      clone.tap do |r|
        r.reverse_order_value == !r.reverse_order_value
      end
    end

    # By default, DatastaxRails uses the LuceneQueryParser. disMax
    # is also supported. eDisMax probably works as well.
    #
    # *This only applies to fulltext queries*
    #
    #   Model.query_parser('disMax').fulltext("john smith")
    #
    # @param parser [String] the parser to use for the fulltext query
    # @param options [Hash] options to pass to the query parser
    #   (see http://wiki.apache.org/solr/ExtendedDisMax for details)
    # @return [DatastaxRails::Relation] a new Relation object
    def query_parser(parser, options = {})
      return self if parser.blank?

      clone.tap do |r|
        r.query_parser_value = { parser => options }
      end
    end

    # Have SOLR compute stats for a given numeric field.  Status computed include:
    # * min
    # * max
    # * sum
    # * sum of squares
    # * mean
    # * standard deviation
    #
    #   Model.compute_stats(:price)
    #   Model.compute_stats(:price, :quantity)
    #
    # NOTE: This is only compatible with solr queries.  It will be ignored when
    # a CQL query is made.
    #
    # @param fields [Symbol] the field to compute stats on
    # @return [DatastaxRails::Relation] a new Relation object
    def compute_stats(*fields)
      return self if fields.empty?

      clone.tap do |r|
        r.stats_values += Array.wrap(fields)
      end
    end

    # By default, DatastaxRails will try to pick the right method of performing
    # a search.  You can use this method to force it to make the query via SOLR.
    #
    # NOTE that the time between when a record is placed into Cassandra and when
    # it becomes available in SOLR is not guaranteed to be insignificant.  It's
    # very possible to insert a new record and not find it when immediately doing
    # a SOLR search for it.
    #
    # @return [DatastaxRails::Relation] a new Relation object
    def with_solr
      clone.tap do |r|
        r.use_solr_value = true
      end
    end

    # By default, DatastaxRails will try to pick the right method of performing
    # a search.  You can use this method to force it to make the query via
    # cassandra.
    #
    # NOTE that this method assumes that you have all the proper secondary indexes
    # in place before you attempt to use it.  If not, you will get an error.
    #
    # @return [DatastaxRails::Relation] a new Relation object
    def with_cassandra
      clone.tap do |r|
        r.use_solr_value = false
      end
    end

    # Specifies restrictions (scoping) on the result set. Expects a hash
    # in the form +attribute: value+ for equality comparisons.
    #
    #   Model.where(group_id: '1234', active: true)
    #
    # The value of the comparison does not need to be a scalar.  For example:
    #
    #   Model.where(name: ["Bob", "Tom", "Sally"]) # Finds where name is any of the three names
    #   Model.where(age: 18..65) # Finds where age is anywhere in the range
    #
    # Inequality comparisons such as greater_than and less_than are
    # specified via chaining:
    #
    #   Model.where(:created_at).greater_than(1.day.ago)
    #   Model.where(:age).less_than(65)
    #
    # There is an alternate form of specifying greater than/less than queries
    # that can be done with a single call.  This is useful for remote APIs and
    # such.
    #
    #   Model.where(:created_at => {greater_than: 1.day.ago})
    #   Model.where(:age => {less_than: 65})
    #
    # NOTE: Due to the way SOLR handles range queries, all greater/less than
    # queries are actually greater/less than or equal to queries.
    # There is no way to perform a strictly greater/less than query.
    #
    # @param attribute [Symbol, String, Hash] a hash of conditions or a single attribute that will be followed by
    #   greater_than or less_than
    # @return [DatastaxRails::Relation] a new Relation object
    def where(attribute)
      return self if attribute.blank?
      if attribute.is_a?(Symbol) || attribute.is_a?(String)
        WhereProxy.new(self, attribute)
      else
        clone.tap do |r|
          attributes = attribute.dup
          attributes.each do |k, v|
            if v.is_a?(Hash)
              comp, value = v.first
              if (comp.to_s == 'greater_than')
                r.greater_than_values << { k => value }
              elsif (comp.to_s == 'less_than')
                r.less_than_values << { k => value }
              else
                r.where_values << { k => value }
              end
              attributes.delete(k)
            end
          end
          r.where_values << attributes unless attributes.empty?
        end
      end
    end

    # Specifies restrictions (scoping) that should not match the result set.
    # Expects a hash in the form +attribute: value+.
    #
    #   Model.where_not(group_id: '1234', active: false)
    #
    # Passing an array will search for records where none of the array entries
    # are present
    #
    #   Model.where_not(group_id: ['1234', '5678'])
    #
    # The above would find all models where group id is neither 1234 or 5678.
    #
    # @param attribute [Symbol, String, Hash] a hash of conditions or a single attribute that will be followed by
    #   greater_than or less_than
    # @return [DatastaxRails::Relation, DatastaxRails::SearchMethods::WhereProxy] a new Relation object
    #   or a proxy object if just an attribute was passed
    def where_not(attribute)
      return self if attribute.blank?

      if attribute.is_a?(Symbol)
        WhereProxy.new(self, attribute, true)
      else
        clone.tap do |r|
          attributes = attribute.dup
          attributes.each do |k, v|
            if v.is_a?(Hash)
              comp, value = v.first
              if (comp.to_s == 'greater_than')
                r.less_than_values << { k => value }
              elsif (comp.to_s == 'less_than')
                r.greater_than_values << { k => value }
              else
                r.where_not_values << { k => value }
              end
              attributes.delete(k)
            end
          end
          r.where_not_values << attributes unless attributes.empty?
        end
      end
    end

    # Specifies a full text search string to be processed by SOLR
    #
    #   Model.fulltext("john smith")
    #
    # You can also pass in an options hash with the following options:
    #
    # * :fields => list of fields to search instead of the default of all fields
    #
    #   Model.fulltext("john smith", fields: [:title])
    #
    # @param query [String] a fulltext query to pass to solr
    # @param opts [Hash] an optional options hash to modify the fulltext query
    # @option opts [Array] :fields list of fields to search instead of the default of all text fields (not-implemented)
    # @return [DatastaxRails::Relation] a new Relation object
    def fulltext(query, opts = {})
      return self if query.blank?

      opts[:query] = downcase_query(query)

      clone.tap do |r|
        r.fulltext_values << opts
      end
    end

    # Enables highlighting on specific fields when used with full
    # text searching. In order for highlighting to work, the highlighted
    # field(s) *must* be +:stored+
    #
    #   Model.fulltext("ruby on rails").highlight(:tags, :body)
    #   Model.fulltext("pizza").highlight(:description, snippets: 3, fragsize: 150)
    #
    # In addition to the array of field names to highlight, you can pass in an
    # options hash with the following options:
    #
    # * :snippets => number of highlight snippets to return
    # * :fragsize => number of characters for each snippet length
    # * :pre_tag => text which appears before a highlighted term
    # * :post_tag => text which appears after a highlighted term
    # * :merge_contiguous => collapse contiguous fragments into a single fragment
    # * :use_fast_vector => enables the Solr FastVectorHighlighter
    #
    # Note: When enabling +:use_fast_vector+, the highlighted fields must be also have
    # +:term_vectors+, +:term_positions+, and +:term_offsets+ enabled.
    # For more information about these options, refer to Solr's wiki
    # on HighlightingParameters[http://http://wiki.apache.org/solr/HighlightingParameters].
    #
    # @overload highlight(*args, opts)
    #   Highlights the full text search terms for the specified fields with the
    #   given options
    #   @param [Array] args list of field names to be highlighted
    #   @param [Hash] opts an options hash to configure the Solr highlighter
    #   @option opts [Integer] :snippets number of highlighted snippets to return
    #   @option opts [Integer] :fragsize number of characters for each snippet length
    #   @option opts [Integer] :max_analyzed_chars number of characters to analyze looking for snippets
    #   @option opts [String] :pre_tag text which appears before a highlighted term
    #   @option opts [String] :post_tag text which appears after a highlighted term
    #   @option opts [true, false] :merge_contiguous collapse contiguous fragments into a single fragment
    #   @option opts [true, false] :use_fast_vector enables the Solr FastVectorHighlighter
    #   @return [DatastaxRails::Relation] a new Relation object
    # @overload highlight(*args)
    #   Highlights the full text search terms for the specified fields
    #   @param [Array] args list of field names to be highlighted
    #   @return [DatastaxRails::Relation] a new Relation object
    def highlight(*args)
      return self if args.blank?

      opts = args.last.is_a?(Hash) ? args.pop : {}

      clone.tap do |r|
        opts[:fields] = r.highlight_options[:fields] || []
        opts[:fields] |= args # Union unique field names
        r.highlight_options.merge! opts
      end
    end

    # @see where
    def less_than(_value)
      fail(ArgumentError, '#less_than can only be called after an appropriate where call. ' \
                          'e.g. where(:created_at).less_than(1.day.ago)')
    end

    # @see where
    def greater_than(_value)
      fail(ArgumentError, '#greater_than can only be called after an appropriate where call. ' \
                          'e.g. where(:created_at).greater_than(1.day.ago)')
    end

    # Formats a value for solr (assuming this is a solr query).
    # rubocop:disable Metrics/CyclomaticComplexity
    # rubocop:disable Metrics/PerceivedComplexity
    def solr_format(attribute, value)
      return value unless use_solr_value
      column = attribute.is_a?(DatastaxRails::Column) ? attribute : klass.column_for_attribute(attribute)
      # value = column.type_cast_for_solr(value)
      case
      when value.is_a?(Time) || value.is_a?(DateTime) || value.is_a?(Date)
        column.type_cast_for_solr(value)
      when value.is_a?(Array) || value.is_a?(Set)
        value = value.to_a.compact if column.primary
        value.map { |v| column.type_cast_for_solr(v, column.options[:holds]).to_s.gsub(/ /, '\\ ') }.join(' OR ')
      when value.is_a?(Fixnum)
        value < 0 ? "\\#{value}" : value
      when value.is_a?(Range)
        "[#{solr_format(attribute, value.first)} TO #{solr_format(attribute, value.last)}]"
      when value.is_a?(String)
        solr_escape(downcase_query(value.gsub(/ /, '\\ ')))
      when value.is_a?(FalseClass), value.is_a?(TrueClass)
        value.to_s
        # when value.is_a?(::Cql::Uuid)
        # value.to_s
      else
        value
      end
    end

    # WhereProxy objects act as a placeholder for queries in which #where does not include a value.
    # In this case, #where must be chained with #greater_than, #less_than, or #equal_to to return
    # a new relation.
    class WhereProxy #:nodoc:
      def initialize(relation, attribute, invert = false) #:nodoc:
        @relation, @attribute, @invert = relation, attribute, invert
      end

      def equal_to(value) #:nodoc:
        @relation.clone.tap do |r|
          if @invert
            r.where_not_values << { @attribute => value }
          else
            r.where_values << { @attribute => value }
          end
        end
      end

      def greater_than(value) #:nodoc:
        @relation.clone.tap do |r|
          if @invert
            r.less_than_values << { @attribute => value }
          else
            r.greater_than_values << { @attribute => value }
          end
        end
      end

      def less_than(value) #:nodoc:
        @relation.clone.tap do |r|
          if @invert
            r.greater_than_values << { @attribute => value }
          else
            r.less_than_values << { @attribute => value }
          end
        end
      end
    end
  end
end
