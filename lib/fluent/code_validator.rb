#
# Fluent
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#

require "parser/current"

module Fluent
  module Validator
    class DependencyModuleValidator
      include AST::Sexp

      DENIED_MODULES = ["yajl/json_gem"]
      PLUGIN_BASES = [:Buffer, :Input, :Filter, :Formatter, :Metrics, :Output, :Parser, :Storage, :ServiceDiscovery]

      def initialize
        @parser = Parser::CurrentRuby.new
      end

      def parse_class(node)
        sexp = select_class(node, :Plugin)
        if sexp
          # s(:class,
          #   s(:const, s(:const, nil, :Plugin), xxx)
          #   s(:const, s(:const, nil, :Plugin), xxx)
          #   s(:begin
          #      s(...
          # Then, skip base class until :begin
          sexp.children[2].children.each do |child|
            case child.type
            when :def
              # s(:def,
              #   xxx,
              #   s(:args),
              #   s(....
              # Then, skip method and argument
              child.children[2..].each do |code|
                DENIED_MODULES.each do |deny|
                  if has_denied_module?(code, deny)
                    raise RuntimeError.new("Unreliable module <#{deny}> is used in <#{path}>")
                  end
                end
              end
            end
          end
        end
      end

      def select_module(node, mod)
        # Module expression
        #
        # s(:module,
        #   s(:const, nil, :Fluent)
        if node and node.type == :module
          if node.children[0] == s(:const, nil, mod)
            return node
          else
            node.children.each do |child|
              sexp = select_module(child, mod)
              return sexp if sexp
            end
          end
        end
        nil
      end

      def select_class(node, klass)
        # Class expression
        #
        # s(:class,
        #  s(:const, s(:const, nil, :Plugin), xxx),
        #  s(:const, s(:const, nil, :Plugin), :Output),
        #  s(:begin,...)
        case node.type
        when :class
          if node.children[0].to_a.first == s(:const, nil, :Plugin) and
            node.children[1].to_a.first == s(:const, nil, :Plugin) and
            PLUGIN_BASES.include?(node.children[1].to_a.last)
            return node
          end
        when :const
          nil # skip
        else
          node.children.each do |child|
            sexp = select_class(child, klass)
            return sexp if sexp
          end
        end
      end

      def validate(path)
        buffer = Parser::Source::Buffer.new('(string)', source: File.read(path))
        @parser.parse(buffer).children.each do |node|
          next unless node
          sexp = select_module(node, :Fluent)
          if sexp
            sexp.children.each do |child|
              next unless child
              parse_class(child)
            end
          end
        end
        true
      end
    end

    def has_denied_module?(code, deny)
      case code.type
      when :send
        # Check require 'xxxx'
        if code == s(:send, nil, :require, s(:str, deny))
          return true
        end
=begin
      when :begin
        code.children.each do |c|
          ret = has_denied_module?(c, deny)
          return ret if ret
        end
=end
      when :args
        # skip method argument
      else
        code.children.each do |c|
          ret = has_denied_module?(c, deny)
          return ret if ret
        end
      end
      nil
    end
  end
end
