require 'rdf'
require 'ebnf'

module RDF
  ##
  # **`RDF::Turtle`** is an Turtle plugin for RDF.rb.
  #
  # @example Requiring the `RDF::Turtle` module
  #   require 'rdf/turtle'
  #
  # @example Parsing RDF statements from an Turtle file
  #   RDF::Turtle::Reader.open("etc/foaf.ttl") do |reader|
  #     reader.each_statement do |statement|
  #       puts statement.inspect
  #     end
  #   end
  #
  # @see http://rubydoc.info/github/ruby-rdf/rdf/master/frames
  # @see http://dvcs.w3.org/hg/rdf/raw-file/default/rdf-turtle/index.html
  #
  # @author [Gregg Kellogg](http://greggkellogg.net/)
  module Turtle
    require  'rdf/turtle/format'
    autoload :Reader,     'rdf/turtle/reader'
    autoload :Terminals,  'rdf/turtle/terminals'
    autoload :VERSION,    'rdf/turtle/version'
    autoload :Writer,     'rdf/turtle/writer'

    def self.debug?; @debug; end
    def self.debug=(value); @debug = value; end
  end
end
