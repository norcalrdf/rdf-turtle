require 'rdf'
require 'rdf/ll1/lexer'

module RDF::LL1
  ##
  # A Generic LL1 parser using a lexer and branch tables defined using the SWAP tool chain (modified).
  module Parser
    ##
    # @attr [Integer] lineno
    attr_reader :lineno

    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def production_handlers; @production_handlers || {}; end
      def production_recovery; @production_recovery || {}; end
      def terminal_handlers; @terminal_handlers || {}; end
      def patterns; @patterns || []; end
      def unescape_terms; @unescape_terms || []; end

      ##
      # Defines a production called during different phases of parsing
      # with data from previous production along with data defined for the
      # current production
      #
      # @param [Symbol] term
      #   Term which is a key in the branch table
      # @param [Hash] options
      # @option options [Regexp] :recover_to
      #   Regular expression used to forward the input stream to the end of the production.
      # @yield [reader, phase, input, current]
      # @yieldparam [RDF::Reader] reader
      #   Reader instance
      # @yieldparam [Symbol] phase
      #   Phase of parsing, one of :start, or :finish
      # @yieldparam [Hash] input
      #   A Hash containing input from the parent production
      # @yieldparam [Hash] current
      #   A Hash defined for the current production, during :start
      #   may be initialized with data to pass to further productions,
      #   during :finish, it contains data placed by earlier productions
      # @yieldparam [Prod] block
      #   Block passed to initialization for yielding to calling reader.
      #   Should conform to the yield specs for #initialize
      # Yield to generate a triple
      def production(term, options = {}, &block)
        @production_handlers ||= {}
        @production_handlers[term] = block if block_given?
        @production_recovery ||= {}
        @production_recovery[term] = options[:recover_to] if options[:recover_to]
      end

      ##
      # Defines the pattern for a terminal node and a block to be invoked
      # when ther terminal is encountered. If the block is missing, the
      # value of the terminal will be placed on the input hash to be returned
      # to a previous production.
      #
      # @param [Symbol, String] term
      #   Defines a terminal production, which appears as within a sequence in the branch table
      # @param [Regexp] regexp
      #   Pattern used to scan for this terminal
      # @param [Hash] options
      # @option options [Boolean] :unescape
      #   Cause strings and codepoints to be unescaped.
      # @yield [reader, term, token, input]
      # @yieldparam [RDF::Reader] reader
      #   Reader instance
      # @yieldparam [Symbol] term
      #   A symbol indicating the production which referenced this terminal
      # @yieldparam [String] token
      #   The scanned token
      # @yieldparam [Hash] input
      #   A Hash containing input from the parent production
      # @yieldparam [Prod] block
      #   Block passed to initialization for yielding to calling reader.
      #   Should conform to the yield specs for #initialize
      def terminal(term, regexp, options = {}, &block)
        @patterns ||= []
        @patterns << [term, regexp]  # Passed in order to define evaulation sequence
        @terminal_handlers ||= {}
        @terminal_handlers[term] = block if block_given?
        @unescape_terms ||= []
        @unescape_terms << term if options[:unescape]
      end
    end

    ##
    # Initializes a new parser instance.
    #
    # Attempts to recover from errors.
    #
    # @example
    #   require 'rdf/ll1/parser'
    #   
    #   class Reader << RDF::Reader
    #     include RDF::LL1::Parser
    #     
    #     branch      RDF::Turtle::Reader::BRANCH
    #     
    #     ##
    #     # Defines a production called during different phases of parsing
    #     # with data from previous production along with data defined for the
    #     # current production
    #     #
    #     # Yield to generate a triple
    #     production :object do |reader, phase, input, current|
    #       object = current[:resource]
    #       yield :statement, RDF::Statement.new(input[:subject], input[:predicate], object)
    #     end
    #     
    #     ##
    #     # Defines the pattern for a terminal node
    #     terminal :BLANK_NODE_LABEL, %r(_:(#{PN_LOCAL})) do |reader, production, token, input|
    #       input[:BLANK_NODE_LABEL] = RDF::Node.new(token)
    #     end
    #     
    #     ##
    #     # Iterates the given block for each RDF statement in the input.
    #     #
    #     # @yield  [statement]
    #     # @yieldparam [RDF::Statement] statement
    #     # @return [void]
    #     def each_statement(&block)
    #       @callback = block
    #   
    #       parse(START.to_sym) do |context, *data|
    #         case context
    #         when :statement
    #           yield *data
    #         end
    #       end
    #     end
    #     
    #   end
    #
    # @param  [String, #to_s]          input
    # @param [Symbol, #to_s] prod The starting production for the parser.
    #   It may be a URI from the grammar, or a symbol representing the local_name portion of the grammar URI.
    # @param  [Hash{Symbol => Object}] options
    # @option options [Hash{Symbol,String => Hash{Symbol,String => Array<Symbol,String>}}] :branch
    #   LL1 branch table.
    # @option options [HHash{Symbol,String => Array<Symbol,String>}] :first ({})
    #   Lists valid terminals that can precede each production (for error recovery).
    # @option options [HHash{Symbol,String => Array<Symbol,String>}] :follow ({})
    #   Lists valid terminals that can follow each production (for error recovery).
    # @option options [Boolean]  :validate     (false)
    #   whether to validate the parsed statements and values. If not validating,
    #   the parser will attempt to recover from errors.
    # @option options [Boolean] :progress
    #   Show progress of parser productions
    # @option options [Boolean] :debug
    #   Detailed debug output
    # @yield [context, *data]
    #   Yields for to return data to reader
    # @yieldparam [:statement, :trace] context
    #   Context for block
    # @yieldparam [Symbol] *data
    #   Data specific to the call
    # @return [RDF::LL1::Parser]
    # @see http://cs.adelaide.edu.au/~charles/lt/Lectures/07-ErrorRecovery.pdf
    def parse(input = nil, prod = nil, options = {}, &block)
      @options = options.dup
      @branch  = options[:branch]
      @first  = options[:first] ||= {}
      @follow  = options[:follow] ||= {}
      @lexer   = input.is_a?(Lexer) ? input : Lexer.new(input, self.class.patterns, @options.merge(:unescape_terms => self.class.unescape_terms))
      @productions = []
      @parse_callback = block
      @recovering = false
      @error_log = []
      terminals = self.class.patterns.map(&:first)  # Get defined terminals to help with branching

      # Unrecoverable errors
      raise Error, "Branch table not defined" unless @branch && @branch.length > 0
      raise Error, "Starting production not defined" unless prod

      @prod_data = [{}]
      prod = RDF::URI(prod).fragment.to_sym unless prod.is_a?(Symbol)
      todo_stack = [{:prod => prod, :terms => nil}]

      while !todo_stack.empty?
        pushed = false
        if todo_stack.last[:terms].nil?
          todo_stack.last[:terms] = []
          cur_prod = todo_stack.last[:prod]

          # Get the next token, raises Error if the token is invalid
          # and we are in error recovery
          begin
            token = skip_until_valid(todo_stack, (@first[cur_prod] || []))
          
            # At this point, token is either nil, in the first set of the production,
            # or in the follow set of this production or any previous production
            debug("parse(production)") do
              "token #{token.inspect}, " + 
              "prod #{cur_prod.inspect}, " + 
              "depth #{depth}"
            end
          
            # Got an opened production
            onStart(cur_prod)
            break if token.nil?
          
            if prod_branch = @branch[cur_prod]
              sequence = prod_branch[token.representation]
              debug("parse(production)") do
                "token #{token.inspect} " +
                "prod #{cur_prod.inspect}, " + 
                "prod_branch #{prod_branch.keys.inspect}, " +
                "sequence #{sequence.inspect}"
              end

              if sequence.nil?
                if prod_branch.has_key?(:"ebnf:empty")
                  debug("parse(production)") {"empty sequence for ebnf:empty"}
                else
                  # If there is no sequence for this production, we're
                  # in error recovery, and _token_ has been advanced to
                  # the point where it can reasonably follow this production
                end
              end
              todo_stack.last[:terms] += sequence if sequence
            else
              # Is this a fatal error?
              error("parse(fatal?)", "No branches found for #{cur_prod.inspect}",
                :production => cur_prod, :token => token)
              raise "Should not be possible to not find a branch for #{cur_prod}"
            end
          rescue Recover
            # In recovery due to input mismatch. Sequence for this production
            # should be empty, so nothing really to do
          end
        end
        
        debug("parse(terms)") {"todo #{todo_stack.last.inspect}, depth #{depth}"}
        begin
          while !todo_stack.last[:terms].to_a.empty?
            # Get the next term in this sequence
            term = todo_stack.last[:terms].shift
            debug("parse(token)") {"accept #{term.inspect}"}

            if (token = accept(term))
              debug("parse(token)") {"token #{token.inspect}, term #{term.inspect}"}
              onToken(term, token)
            elsif terminals.include?(term)
              skip_until_valid(todo_stack, [term])
            else
              # If it's not a string (a symbol), it is a non-terminal and we push the new state
              # Make sure that the next token is valid for this production
              #skip_until_valid(todo_stack, (@first[term] || []))
              todo_stack << {:prod => term, :terms => nil}
              debug("parse(push)") {"term #{term.inspect}, depth #{depth}"}
              pushed = true
              break
            end
          end
        rescue Recover
          # Enters recovery
        end

        # After completing the last production in a sequence, pop down until we find a production
        #
        # If in recovery mode, continue popping until we find a production with
        # an error recovery regexp
        while !pushed && !todo_stack.empty? &&
              (todo_stack.last[:terms].to_a.empty? || @recovering)
          debug("parse(pop)") {"todo #{todo_stack.last.inspect}, depth #{depth}, recovering? #{@recovering.inspect}"}
          prod = todo_stack.last[:prod]
          unless todo_stack.last[:terms].to_a.empty?
            # We're in recovery, skip to the end of this production
            debug("parse(pop)") {"skip rest of production #{todo_stack.last}"}
            @recovering = false
          end
          todo_stack.pop
          onFinish
        end
      end

      token = begin
        @lexer.first
      rescue RDF::LL1::Lexer::Error => e
        @lineno = e.lineno
        e.message
      end

      error("parse(eof)", "Finished processing before end of file", :token => token) if token

      # Continue popping contexts off of the stack
      while !todo_stack.empty?
        debug("parse(eof)") {"stack #{todo_stack.last.inspect}, depth #{depth}"}
        todo_stack.pop
        onFinish
      end
      
      # When all is said and done, raise the error log
      unless @error_log.empty?
        raise Error, @error_log.join("\n\t") 
      end
    end

    def depth; (@productions || []).length; end

  private
    # Start for production
    def onStart(prod)
      handler = self.class.production_handlers[prod]
      @productions << prod
      if handler
        # Create a new production data element, potentially allowing handler
        # to customize before pushing on the @prod_data stack
        progress("#{prod}(:start):#{@prod_data.length}") {@prod_data.last}
        data = {}
        handler.call(self, :start, @prod_data.last, data, @parse_callback)
        @prod_data << data
      else
        progress("#{prod}(:start)", '')
      end
      #puts @prod_data.inspect
    end

    # Finish of production
    def onFinish
      prod = @productions.last
      handler = self.class.production_handlers[prod]
      if handler
        # Pop production data element from stack, potentially allowing handler to use it
        data = @prod_data.pop
        handler.call(self, :finish, @prod_data.last, data, @parse_callback)
        progress("#{prod}(:finish):#{@prod_data.length}") {@prod_data.last}
      else
        progress("#{prod}(:finish)", '')
      end
      @productions.pop
    end

    # A token
    def onToken(prod, token)
      unless @productions.empty?
        parentProd = @productions.last
        handler = self.class.terminal_handlers[prod]
        handler ||= self.class.terminal_handlers[nil] if prod.is_a?(String) # Allows catch-all for simple string terminals
        if handler
          handler.call(self, parentProd, token, @prod_data.last)
          progress("#{prod}(:token)", "", :depth => (depth + 1)) {"#{token.inspect}: #{@prod_data.last}"}
        else
          progress("#{prod}(:token)", "", :depth => (depth + 1)) {token.inspect}
        end
      else
        error("#{parentProd}(:token)", "Token has no parent production", :production => prod)
      end
    end
    
    # Skip through the input stream until something is found that
    # is either valid based on the content of the production stack,
    # or can follow a production in the stack.
    #
    # @param [Array<Hash{}>] todo_stack
    # @param [Array<Symbol, String>] first
    #   Valid tokens that can be used at this point
    # @return [Token]
    # @raise [Recover] if no valid token foun
    def skip_until_valid(todo_stack, first)
      cur_prod = todo_stack.last[:prod]

      token = begin
        get_token
      rescue Recover
        nil
      end

      # If this token can be used by the top production, return it
      # Otherwise, if the banch table allows empty, also return the token
      return token if !@recovering && (
        (@branch[cur_prod] && @branch[cur_prod].has_key?(:"ebnf:empty")) ||
        first.any? {|t| token === t})
      
      # Otherwise, it's an error condition, and skip either until
      # we find a valid token for this production, or until we find
      # something that can follow this production
      expected = first.map {|v| v.inspect}.join(", ")
      error("skip_until_valid", "expected one of #{expected}",
        :production => cur_prod, :token => token)

      debug("recovery", "stack follows:")
      todo_stack.reverse.each do |todo|
        debug("recovery") {"  #{todo[:prod]}: #{@follow[todo[:prod]].inspect}"}
      end

      # Find all follows to the top of the stack
      follows = todo_stack.inject([]) do |follow, todo|
        prod = todo[:prod]
        follow += @follow[prod] || []
      end.uniq
      debug("recovery") {"follows: #{follows.inspect}"}

      # Skip tokens until one is found in first or follows
      while (token = get_token) && (first + follows).none? {|t| token === t}
        skipped = @lexer.shift
        progress("recovery") {"skip #{skipped.inspect}"}
      end
      debug("recovery") {"found #{token.inspect}"}
      
      # If the token is a first, just return it. Otherwise, it is a follow
      # and we need to skip to the end of the production
      #unless first.any? {|t| token == t} || todo_stack.last[:terms].empty?
      #  debug("recovery") {"token in follows, skip past #{todo_stack.last[:terms].inspect}"}
      #  todo_stack.last[:terms] = [] 
      #end
      token
      
      raise Recover
    end

    # @param [String] str Error string
    # @param [Hash] options
    # @option options [URI, #to_s] :production
    # @option options [Token] :token
    def error(node, message, options = {})
      message += ", found #{options[:token].inspect}" if options[:token]
      message += " at line #{@lineno}" if @lineno
      message += ", production = #{options[:production].inspect}" if options[:production] && @options[:debug]
      @error_log << message unless @recovering
      @recovering = true
      debug(node, message, options)
    end

    ##
    # Return the next token, entering error recovery if the token is invalid
    #
    # @return [Token]
    def get_token
      token = begin
        @lexer.first
      rescue RDF::LL1::Lexer::Error => e
        # Recover from lexer error
        @lineno = e.lineno
        error("get_token", e.message, :production => @productions.last)
        raise Recover
      end
      @lineno = token.lineno if token
      token
    end

    ##
    # Progress output when parsing
    # @param [String] node Relevant location associated with message
    # @param [String] message ("")
    # @param [Hash] options
    # @option options [Integer] :depth
    #   Recursion depth for indenting output
    # @yieldreturn [String] added to message
    def progress(node, message = "", options = {})
      return unless @options[:progress] || @options[:debug]
      depth = options[:depth] || self.depth
      message += yield.to_s if block_given?
      if @options[:debug]
        return debug(node, message, options)
      else
        str = "[#{@lineno}]#{' ' * depth}#{node}: #{message}"
        $stderr.puts("[#{@lineno}]#{' ' * depth}#{node}: #{message}")
      end
    end

    ##
    # Progress output when debugging
    # @param [String] node Relevant location associated with message
    # @param [String] message ("")
    # @param [Hash] options
    # @option options [Integer] :depth
    #   Recursion depth for indenting output
    # @yieldreturn [String] added to message
    def debug(node, message = "", options = {})
      return unless @options[:debug]
      depth = options[:depth] || self.depth
      message += yield if block_given?
      str = "[#{@lineno}]#{' ' * depth}#{node}: #{message}"
      case @options[:debug]
      when Array
        @options[:debug] << str
      when TrueClass
        $stderr.puts str
      when :yield
        @parse_callback.call(:trace, node, message, options)
      end
    end

    ##
    # Accept the first token in the input stream if it matches
    # _type\_or\_value_. Return nil otherwise.
    #
    # @param  [Symbol, String] type_or_value
    # @return [Token]
    def accept(type_or_value)
      if (token = get_token) && token === type_or_value
        debug("accept") {"#{token.inspect} === #{type_or_value.inspect}"}
        @lexer.shift
      end
    end
  public

    ##
    # Raised for error recovery during parsing.
    class Recover < StandardError; end

    ##
    # Raised for errors during parsing.
    #
    # @example Raising a parser error
    #   raise Error.new(
    #     "invalid token '%' on line 10",
    #     :token => '%', :lineno => 9, :production => :turtleDoc)
    #
    # @see http://ruby-doc.org/core/classes/StandardError.html
    class Error < StandardError
      ##
      # The current production.
      #
      # @return [Symbol]
      attr_reader :production

      ##
      # The invalid token which triggered the error.
      #
      # @return [String]
      attr_reader :token

      ##
      # The line number where the error occurred.
      #
      # @return [Integer]
      attr_reader :lineno

      ##
      # Initializes a new lexer error instance.
      #
      # @param  [String, #to_s]          message
      # @param  [Hash{Symbol => Object}] options
      # @option options [Symbol]         :production  (nil)
      # @option options [String]         :token  (nil)
      # @option options [Integer]        :lineno (nil)
      def initialize(message, options = {})
        @production = options[:production]
        @token      = options[:token]
        @lineno     = options[:lineno]
        super(message.to_s)
      end
    end # class Error
  end # class Reader
end # module RDF::Turtle
