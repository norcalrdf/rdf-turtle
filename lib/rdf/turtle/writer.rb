require 'rdf/n3/patches/graph_properties'

module RDF::Turtle
  ##
  # A Turtle serialiser in Ruby
  #
  # Note that the natural interface is to write a whole graph at a time.
  # Writing statements or Triples will create a graph to add them to
  # and then serialize the graph.
  #
  # @example Obtaining a Turtle writer class
  #   RDF::Writer.for(:n3)         #=> RDF::Turtle::Writer
  #   RDF::Writer.for("etc/test.n3")
  #   RDF::Writer.for("etc/test.ttl")
  #   RDF::Writer.for(:file_name      => "etc/test.n3")
  #   RDF::Writer.for(:file_name      => "etc/test.ttl")
  #   RDF::Writer.for(:file_extension => "n3")
  #   RDF::Writer.for(:file_extension => "ttl")
  #   RDF::Writer.for(:content_type   => "text/n3")
  #   RDF::Writer.for(:content_type   => "text/turtle")
  #
  # @example Serializing RDF graph into an Turtle file
  #   RDF::Turtle::Writer.open("etc/test.n3") do |writer|
  #     writer << graph
  #   end
  #
  # @example Serializing RDF statements into an Turtle file
  #   RDF::Turtle::Writer.open("etc/test.n3") do |writer|
  #     graph.each_statement do |statement|
  #       writer << statement
  #     end
  #   end
  #
  # @example Serializing RDF statements into an Turtle string
  #   RDF::Turtle::Writer.buffer do |writer|
  #     graph.each_statement do |statement|
  #       writer << statement
  #     end
  #   end
  #
  # The writer will add prefix definitions, and use them for creating @prefix definitions, and minting QNames
  #
  # @example Creating @base and @prefix definitions in output
  #   RDF::Turtle::Writer.buffer(:base_uri => "http://example.com/", :prefixes => {
  #       nil => "http://example.com/ns#",
  #       :foaf => "http://xmlns.com/foaf/0.1/"}
  #   ) do |writer|
  #     graph.each_statement do |statement|
  #       writer << statement
  #     end
  #   end
  #
  # @author [Gregg Kellogg](http://kellogg-assoc.com/)
  class Writer < RDF::Writer
    format RDF::Turtle::Format

    # @return [Graph] Graph of statements serialized
    attr_accessor :graph
    # @return [URI] Base URI used for relativizing URIs
    attr_accessor :base_uri
    
    ##
    # Initializes the Turtle writer instance.
    #
    # @param  [IO, File] output
    #   the output stream
    # @param  [Hash{Symbol => Object}] options
    #   any additional options
    # @option options [Encoding] :encoding     (Encoding::UTF_8)
    #   the encoding to use on the output stream (Ruby 1.9+)
    # @option options [Boolean]  :canonicalize (false)
    #   whether to canonicalize literals when serializing
    # @option options [Hash]     :prefixes     (Hash.new)
    #   the prefix mappings to use (not supported by all writers)
    # @option options [#to_s]    :base_uri     (nil)
    #   the base URI to use when constructing relative URIs
    # @option options [Integer]  :max_depth      (3)
    #   Maximum depth for recursively defining resources, defaults to 3
    # @option options [Boolean]  :standard_prefixes   (false)
    #   Add standard prefixes to @prefixes, if necessary.
    # @option options [String]   :default_namespace (nil)
    #   URI to use as default namespace, same as prefixes[nil]
    # @yield  [writer] `self`
    # @yieldparam  [RDF::Writer] writer
    # @yieldreturn [void]
    # @yield  [writer]
    # @yieldparam [RDF::Writer] writer
    def initialize(output = $stdout, options = {}, &block)
      super do
        @graph = RDF::Graph.new
        @uri_to_qname = {}
        @uri_to_prefix = {}
        if block_given?
          case block.arity
            when 0 then instance_eval(&block)
            else block.call(self)
          end
        end
      end
    end

    ##
    # Write whole graph
    #
    # @param  [Graph] graph
    # @return [void]
    def write_graph(graph)
      @graph = graph
    end

    ##
    # Addes a statement to be serialized
    # @param  [RDF::Statement] statement
    # @return [void]
    def write_statement(statement)
      @graph.insert(statement)
    end

    ##
    # Addes a triple to be serialized
    # @param  [RDF::Resource] subject
    # @param  [RDF::URI]      predicate
    # @param  [RDF::Value]    object
    # @return [void]
    # @raise  [NotImplementedError] unless implemented in subclass
    # @abstract
    def write_triple(subject, predicate, object)
      @graph.insert(Statement.new(subject, predicate, object))
    end

    ##
    # Outputs the Turtle representation of all stored triples.
    #
    # @return [void]
    # @see    #write_triple
    def write_epilogue
      @max_depth = @options[:max_depth] || 3
      @base_uri = RDF::URI(@options[:base_uri])
      @debug = @options[:debug]

      self.reset

      add_debug "\nserialize: graph: #{@graph.size}"

      preprocess
      start_document

      order_subjects.each do |subject|
        unless is_done?(subject)
          statement(subject)
        end
      end
    end
    
    # Return a QName for the URI, or nil. Adds namespace of QName to defined prefixes
    # @param [RDF::Resource] resource
    # @return [String, nil] value to use to identify URI
    def get_qname(resource)
      case resource
      when RDF::Node
        return resource.to_s
      when RDF::URI
        uri = resource.to_s
      else
        return nil
      end

      add_debug "get_qname(#{resource}), std? #{RDF::Vocabulary.each.to_a.detect {|v| uri.index(v.to_uri.to_s) == 0}}"
      qname = case
      when @uri_to_qname.has_key?(uri)
        return @uri_to_qname[uri]
      when u = @uri_to_prefix.keys.detect {|u| uri.index(u.to_s) == 0}
        # Use a defined prefix
        prefix = @uri_to_prefix[u]
        prefix(prefix, u) unless u.to_s.empty? # Define for output
        add_debug "get_qname: add prefix #{prefix.inspect} => #{u}"
        uri.sub(u.to_s, "#{prefix}:")
      when @options[:standard_prefixes] && vocab = RDF::Vocabulary.each.to_a.detect {|v| uri.index(v.to_uri.to_s) == 0}
        prefix = vocab.__name__.to_s.split('::').last.downcase
        @uri_to_prefix[vocab.to_uri.to_s] = prefix
        prefix(prefix, vocab.to_uri) # Define for output
        add_debug "get_qname: add standard prefix #{prefix.inspect} => #{vocab.to_uri}"
        uri.sub(vocab.to_uri.to_s, "#{prefix}:")
      else
        nil
      end
      
      # Make sure qname is a valid qname
      if qname
        md = QNAME.match(qname)
        qname = nil unless md.to_s.length == qname.length
      end

      @uri_to_qname[uri] = qname
    rescue Addressable::URI::InvalidURIError => e
      raise RDF::WriterError, "Invalid URI #{resource.inspect}: #{e.message}"
    end
    
    # Take a hash from predicate uris to lists of values.
    # Sort the lists of values.  Return a sorted list of properties.
    # @param [Hash{String => Array<Resource>}] properties A hash of Property to Resource mappings
    # @return [Array<String>}] Ordered list of properties. Uses predicate_order.
    def sort_properties(properties)
      properties.keys.each do |k|
        properties[k] = properties[k].sort do |a, b|
          a_li = a.to_s.index(RDF._.to_s) == 0 ? a.to_s.match(/\d+$/).to_s.to_i : a.to_s
          b_li = b.to_s.index(RDF._.to_s) == 0 ? b.to_s.match(/\d+$/).to_s.to_i : b.to_s
          
          a_li <=> b_li
        end
      end
      
      # Make sorted list of properties
      prop_list = []
      
      predicate_order.each do |prop|
        next unless properties[prop]
        prop_list << prop.to_s
      end
      
      properties.keys.sort.each do |prop|
        next if prop_list.include?(prop.to_s)
        prop_list << prop.to_s
      end
      
      add_debug "sort_properties: #{prop_list.to_sentence}"
      prop_list
    end

    ##
    # Returns the N-Triples representation of a literal.
    #
    # @param  [RDF::Literal, String, #to_s] literal
    # @param  [Hash{Symbol => Object}] options
    # @return [String]
    def format_literal(literal, options = {})
      literal = literal.dup.canonicalize! if @options[:canonicalize]
      case literal
      when RDF::Literal
        case literal.datatype
        when RDF::XSD.boolean, RDF::XSD.integer, RDF::XSD.decimal
          literal.to_s
        when RDF::XSD.double
          literal.to_s.sub('E', 'e')  # Favor lower case exponent
        else
          text = quoted(literal.value)
          text << "@#{literal.language}" if literal.has_language?
          text << "^^#{format_uri(literal.datatype)}" if literal.has_datatype?
          text
        end
      else
        quoted(literal.to_s)
      end
    end
    
    ##
    # Returns the Turtle representation of a URI reference.
    #
    # @param  [RDF::URI] literal
    # @param  [Hash{Symbol => Object}] options
    # @return [String]
    def format_uri(uri, options = {})
      md = relativize(uri)
      add_debug("relativize(#{uri.inspect}) => #{md.inspect}") if md != uri.to_s
      md != uri.to_s ? "<#{md}>" : (get_qname(uri) || "<#{uri}>")
    end
    
    ##
    # Returns the Turtle representation of a blank node.
    #
    # @param  [RDF::Node] node
    # @param  [Hash{Symbol => Object}] options
    # @return [String]
    def format_node(node, options = {})
      "_:%s" % node.id
    end
    
    protected
    # Output @base and @prefix definitions
    def start_document
      @started = true
      
      @output.write("#{indent}@base <#{@base_uri}> .\n") unless @base_uri.to_s.empty?
      
      add_debug("start_document: #{prefixes.inspect}")
      prefixes.keys.sort_by(&:to_s).each do |prefix|
        @output.write("#{indent}@prefix #{prefix}: <#{prefixes[prefix]}> .\n")
      end
    end
    
    # If @base_uri is defined, use it to try to make uri relative
    # @param [#to_s] uri
    # @return [String]
    def relativize(uri)
      uri = uri.to_s
      @base_uri ? uri.sub(@base_uri.to_s, "") : uri
    end

    # Defines rdf:type of subjects to be emitted at the beginning of the graph. Defaults to rdfs:Class
    # @return [Array<URI>]
    def top_classes; [RDF::RDFS.Class]; end

    # Defines order of predicates to to emit at begninning of a resource description. Defaults to
    # [rdf:type, rdfs:label, dc:title]
    # @return [Array<URI>]
    def predicate_order; [RDF.type, RDF::RDFS.label, RDF::DC.title]; end
    
    # Order subjects for output. Override this to output subjects in another order.
    #
    # Uses #top_classes and #base_uri.
    # @return [Array<Resource>] Ordered list of subjects
    def order_subjects
      seen = {}
      subjects = []
      
      # Start with base_uri
      if base_uri && @subjects.keys.include?(base_uri)
        subjects << base_uri
        seen[base_uri] = true
      end
      
      # Add distinguished classes
      top_classes.each do |class_uri|
        graph.query(:predicate => RDF.type, :object => class_uri).map {|st| st.subject}.sort.uniq.each do |subject|
          add_debug "order_subjects: #{subject.inspect}"
          subjects << subject
          seen[subject] = true
        end
      end
      
      # Sort subjects by resources over bnodes, ref_counts and the subject URI itself
      recursable = @subjects.keys.
        select {|s| !seen.include?(s)}.
        map {|r| [r.is_a?(RDF::Node) ? 1 : 0, ref_count(r), r]}.
        sort
      
      subjects += recursable.map{|r| r.last}
    end
    
    # Perform any preprocessing of statements required
    def preprocess
      # Load defined prefixes
      (@options[:prefixes] || {}).each_pair do |k, v|
        @uri_to_prefix[v.to_s] = k
      end
      @options[:prefixes] = {}  # Will define actual used when matched

      prefix(nil, @options[:default_namespace]) if @options[:default_namespace]

      @graph.each {|statement| preprocess_statement(statement)}
    end
    
    # Perform any statement preprocessing required. This is used to perform reference counts and determine required
    # prefixes.
    # @param [Statement] statement
    def preprocess_statement(statement)
      #add_debug "preprocess: #{statement.inspect}"
      references = ref_count(statement.object) + 1
      @references[statement.object] = references
      @subjects[statement.subject] = true
      
      # Pre-fetch qnames, to fill prefixes
      get_qname(statement.subject)
      get_qname(statement.predicate)
      get_qname(statement.object)
      get_qname(statement.object.datatype) if statement.object.literal? && statement.object.datatype

      @references[statement.predicate] = ref_count(statement.predicate) + 1
    end
    
    # Return the number of times this node has been referenced in the object position
    # @return [Integer]
    def ref_count(node)
      @references.fetch(node, 0)
    end

    # Returns indent string multiplied by the depth
    # @param [Integer] modifier Increase depth by specified amount
    # @return [String] A number of spaces, depending on current depth
    def indent(modifier = 0)
      " " * (@depth + modifier)
    end

    # Reset internal helper instance variables
    def reset
      @depth = 0
      @lists = {}
      @namespaces = {}
      @references = {}
      @serialized = {}
      @subjects = {}
      @shortNames = {}
      @started = false
    end

    ##
    # Use single- or multi-line quotes. If literal contains \t, \n, or \r, use a multiline quote,
    # otherwise, use a single-line
    # @param  [String] string
    # @return [String]
    def quoted(string)
      if string.to_s.match(/[\t\n\r]/)
        string = string.gsub('\\', '\\\\').gsub('"""', '\\"""')
        %("""#{string}""")
      else
        "\"#{escaped(string)}\""
      end
    end

    private
    
    # Add debug event to debug array, if specified
    #
    # @param [String] message::
    def add_debug(message)
      STDERR.puts message if ::RDF::Turtle::debug?
      @debug << message if @debug.is_a?(Array)
    end

    # Checks if l is a valid RDF list, i.e. no nodes have other properties.
    def is_valid_list(l)
      props = @graph.properties(l)
      #add_debug "is_valid_list: #{props.inspect}"
      return false unless props.has_key?(RDF.first.to_s) || l == RDF.nil
      while l && l != RDF.nil do
        #add_debug "is_valid_list(length): #{props.length}"
        return false unless props.has_key?(RDF.first.to_s) && props.has_key?(RDF.rest.to_s)
        n = props[RDF.rest.to_s]
        #add_debug "is_valid_list(n): #{n.inspect}"
        return false unless n.is_a?(Array) && n.length == 1
        l = n.first
        props = @graph.properties(l)
      end
      #add_debug "is_valid_list: valid"
      true
    end
    
    def do_list(l)
      add_debug "do_list: #{l.inspect}"
      position = :subject
      while l do
        p = @graph.properties(l)
        item = p.fetch(RDF.first.to_s, []).first
        if item
          path(item, position)
          subject_done(l)
          position = :object
        end
        l = p.fetch(RDF.rest.to_s, []).first
      end
    end
    
    def p_list(node, position)
      return false if !is_valid_list(node)
      #add_debug "p_list: #{node.inspect}, #{position}"

      @output.write(position == :subject ? "(" : " (")
      @depth += 2
      do_list(node)
      @depth -= 2
      @output.write(')')
    end
    
    def p_squared?(node, position)
      node.is_a?(RDF::Node) &&
        !@serialized.has_key?(node) &&
        ref_count(node) <= 1
    end
    
    def p_squared(node, position)
      return false unless p_squared?(node, position)

      #add_debug "p_squared: #{node.inspect}, #{position}"
      subject_done(node)
      @output.write(position == :subject ? '[' : ' [')
      @depth += 2
      predicate_list(node)
      @depth -= 2
      @output.write(']')
      
      true
    end
    
    def p_default(node, position)
      #add_debug "p_default: #{node.inspect}, #{position}"
      l = (position == :subject ? "" : " ") + format_value(node)
      @output.write(l)
    end
    
    def path(node, position)
      add_debug "path: #{node.inspect}, pos: #{position}, []: #{is_valid_list(node)}, p2?: #{p_squared?(node, position)}, rc: #{ref_count(node)}"
      raise RDF::WriterError, "Cannot serialize node '#{node}'" unless p_list(node, position) || p_squared(node, position) || p_default(node, position)
    end
    
    def verb(node)
      add_debug "verb: #{node.inspect}"
      if node == RDF.type
        @output.write(" a")
      else
        path(node, :predicate)
      end
    end
    
    def object_list(objects)
      add_debug "object_list: #{objects.inspect}"
      return if objects.empty?

      objects.each_with_index do |obj, i|
        @output.write(",\n#{indent(2)}") if i > 0
        path(obj, :object)
      end
    end
    
    def predicate_list(subject)
      properties = @graph.properties(subject)
      prop_list = sort_properties(properties) - [RDF.first.to_s, RDF.rest.to_s]
      add_debug "predicate_list: #{prop_list.inspect}"
      return if prop_list.empty?

      prop_list.each_with_index do |prop, i|
        begin
          @output.write(";\n#{indent(2)}") if i > 0
          prop[0, 2] == "_:"
          verb(prop[0, 2] == "_:" ? RDF::Node.new(prop.split(':').last) : RDF::URI.intern(prop))
          object_list(properties[prop])
        rescue Addressable::URI::InvalidURIError => e
          add_debug "Predicate #{prop.inspect} is an invalid URI: #{e.message}"
        end
      end
    end
    
    def s_squared?(subject)
      ref_count(subject) == 0 && subject.is_a?(RDF::Node) && !is_valid_list(subject)
    end
    
    def s_squared(subject)
      return false unless s_squared?(subject)
      
      add_debug "s_squared: #{subject.inspect}"
      @output.write("\n#{indent} [")
      @depth += 1
      predicate_list(subject)
      @depth -= 1
      @output.write("] .")
      true
    end
    
    def s_default(subject)
      @output.write("\n#{indent}")
      path(subject, :subject)
      predicate_list(subject)
      @output.write(" .")
      true
    end
    
    def statement(subject)
      add_debug "statement: #{subject.inspect}, s2?: #{s_squared?(subject)}"
      subject_done(subject)
      s_squared(subject) || s_default(subject)
    end
    
    def is_done?(subject)
      @serialized.include?(subject)
    end
    
    # Mark a subject as done.
    def subject_done(subject)
      @serialized[subject] = true
    end
  end
end