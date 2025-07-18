#
# Fluentd
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

require 'fluent/plugin_helper/event_loop'

require 'serverengine'
require 'cool.io'
require 'socket'
require 'ipaddr'
require 'fcntl'
require 'openssl'

require_relative 'socket_option'
require_relative 'cert_option'

module Fluent
  module PluginHelper
    module Server
      include Fluent::PluginHelper::EventLoop
      include Fluent::PluginHelper::SocketOption
      include Fluent::PluginHelper::CertOption

      # This plugin helper doesn't support these things for now:
      # * TCP/TLS keepalive
      # * TLS session cache/tickets
      # * unix domain sockets

      # stop     : [-]
      # shutdown : detach server event handler from event loop (event_loop)
      # close    : close listening sockets
      # terminate: remote all server instances

      attr_reader :_servers # for tests

      def server_wait_until_start
        # event_loop_wait_until_start works well for this
      end

      def server_wait_until_stop
        sleep 0.1 while @_servers.any?{|si| si.server.attached? }
        @_servers.each{|si| si.server.close rescue nil }
      end

      PROTOCOLS = [:tcp, :udp, :tls, :unix]
      CONNECTION_PROTOCOLS = [:tcp, :tls, :unix]

      # server_create_connection(:title, @port) do |conn|
      #   # on connection
      #   source_addr = conn.remote_host
      #   source_port = conn.remote_port
      #   conn.data do |data|
      #     # on data
      #     conn.write resp # ...
      #     conn.close
      #   end
      # end
      def server_create_connection(title, port, proto: nil, bind: '0.0.0.0', shared: true, backlog: nil, tls_options: nil, **socket_options, &block)
        proto ||= (@transport_config && @transport_config.protocol == :tls) ? :tls : :tcp

        raise ArgumentError, "BUG: title must be a symbol" unless title && title.is_a?(Symbol)
        raise ArgumentError, "BUG: port must be an integer" unless port && port.is_a?(Integer)
        raise ArgumentError, "BUG: invalid protocol name" unless PROTOCOLS.include?(proto)
        raise ArgumentError, "BUG: cannot create connection for UDP" unless CONNECTION_PROTOCOLS.include?(proto)

        raise ArgumentError, "BUG: tls_options is available only for tls" if tls_options && proto != :tls

        raise ArgumentError, "BUG: block not specified which handles connection" unless block_given?
        raise ArgumentError, "BUG: block must have just one argument" unless block.arity == 1

        if proto == :tcp || proto == :tls
          socket_options[:linger_timeout] ||= @transport_config&.linger_timeout || 0
        end

        socket_options[:receive_buffer_size] ||= @transport_config&.receive_buffer_size

        socket_option_validate!(proto, **socket_options)
        socket_option_setter = ->(sock){ socket_option_set(sock, **socket_options) }

        case proto
        when :tcp
          server = server_create_for_tcp_connection(shared, bind, port, backlog, socket_option_setter, &block)
        when :tls
          transport_config = if tls_options
                               server_create_transport_section_object(tls_options)
                             elsif @transport_config && @transport_config.protocol == :tls
                               @transport_config
                             else
                               raise ArgumentError, "BUG: TLS transport specified, but certification options are not specified"
                             end
          server = server_create_for_tls_connection(shared, bind, port, transport_config, backlog, socket_option_setter, &block)
        when :unix
          raise "not implemented yet"
        else
          raise "unknown protocol #{proto}"
        end

        server_attach(title, proto, port, bind, shared, server)
      end

      # server_create(:title, @port) do |data|
      #   # ...
      # end
      # server_create(:title, @port) do |data, conn|
      #   # ...
      # end
      # server_create(:title, @port, proto: :udp, max_bytes: 2048) do |data, sock|
      #   sock.remote_host
      #   sock.remote_port
      #   # ...
      # end
      def server_create(title, port, proto: nil, bind: '0.0.0.0', shared: true, socket: nil, backlog: nil, tls_options: nil, max_bytes: nil, flags: 0, **socket_options, &callback)
        proto ||= (@transport_config && @transport_config.protocol == :tls) ? :tls : :tcp

        raise ArgumentError, "BUG: title must be a symbol" unless title && title.is_a?(Symbol)
        raise ArgumentError, "BUG: port must be an integer" unless port && port.is_a?(Integer)
        raise ArgumentError, "BUG: invalid protocol name" unless PROTOCOLS.include?(proto)

        raise ArgumentError, "BUG: socket option is available only for udp" if socket && proto != :udp
        raise ArgumentError, "BUG: tls_options is available only for tls" if tls_options && proto != :tls

        raise ArgumentError, "BUG: block not specified which handles received data" unless block_given?
        raise ArgumentError, "BUG: block must have 1 or 2 arguments" unless callback.arity == 1 || callback.arity == 2

        if proto == :tcp || proto == :tls
          socket_options[:linger_timeout] ||= @transport_config&.linger_timeout || 0
        end

        socket_options[:receive_buffer_size] ||= @transport_config&.receive_buffer_size

        unless socket
          socket_option_validate!(proto, **socket_options)
          socket_option_setter = ->(sock){ socket_option_set(sock, **socket_options) }
        end

        if proto != :tcp && proto != :tls && proto != :unix # options to listen/accept connections
          raise ArgumentError, "BUG: backlog is available for tcp/tls" if backlog
        end
        if proto != :udp # UDP options
          raise ArgumentError, "BUG: max_bytes is available only for udp" if max_bytes
          raise ArgumentError, "BUG: flags is available only for udp" if flags != 0
        end

        case proto
        when :tcp
          server = server_create_for_tcp_connection(shared, bind, port, backlog, socket_option_setter) do |conn|
            conn.data(&callback)
          end
        when :tls
          transport_config = if tls_options
                               server_create_transport_section_object(tls_options)
                             elsif @transport_config && @transport_config.protocol == :tls
                               @transport_config
                             else
                               raise ArgumentError, "BUG: TLS transport specified, but certification options are not specified"
                             end
          server = server_create_for_tls_connection(shared, bind, port, transport_config, backlog, socket_option_setter) do |conn|
            conn.data(&callback)
          end
        when :udp
          raise ArgumentError, "BUG: max_bytes must be specified for UDP" unless max_bytes
          if socket
            sock = socket
            close_socket = false
          else
            sock = server_create_udp_socket(shared, bind, port)
            socket_option_setter.call(sock)
            close_socket = true
          end
          server = EventHandler::UDPServer.new(sock, max_bytes, flags, close_socket, @log, @under_plugin_development, &callback)
        when :unix
          raise "not implemented yet"
        else
          raise "BUG: unknown protocol #{proto}"
        end

        server_attach(title, proto, port, bind, shared, server)
      end

      def server_create_tcp(title, port, **kwargs, &callback)
        server_create(title, port, proto: :tcp, **kwargs, &callback)
      end

      def server_create_udp(title, port, **kwargs, &callback)
        server_create(title, port, proto: :udp, **kwargs, &callback)
      end

      def server_create_tls(title, port, **kwargs, &callback)
        server_create(title, port, proto: :tls, **kwargs, &callback)
      end

      def server_create_unix(title, port, **kwargs, &callback)
        server_create(title, port, proto: :unix, **kwargs, &callback)
      end

      ServerInfo = Struct.new(:title, :proto, :port, :bind, :shared, :server)

      def server_attach(title, proto, port, bind, shared, server)
        @_servers << ServerInfo.new(title, proto, port, bind, shared, server)
        event_loop_attach(server)
      end

      def server_create_for_tcp_connection(shared, bind, port, backlog, socket_option_setter, &block)
        sock = server_create_tcp_socket(shared, bind, port)
        socket_option_setter.call(sock)
        close_callback = ->(conn){ @_server_mutex.synchronize{ @_server_connections.delete(conn) } }
        server = Coolio::TCPServer.new(sock, nil, EventHandler::TCPServer, socket_option_setter, close_callback, @log, @under_plugin_development, block) do |conn|
          unless conn.closing
            @_server_mutex.synchronize do
              @_server_connections << conn
            end
          end
        end
        server.listen(backlog) if backlog
        server
      end

      def server_create_for_tls_connection(shared, bind, port, conf, backlog, socket_option_setter, &block)
        context = cert_option_create_context(conf.version, conf.insecure, conf.ciphers, conf)
        sock = server_create_tcp_socket(shared, bind, port)
        socket_option_setter.call(sock)
        close_callback = ->(conn){ @_server_mutex.synchronize{ @_server_connections.delete(conn) } }
        server = Coolio::TCPServer.new(sock, nil, EventHandler::TLSServer, context, socket_option_setter, close_callback, @log, @under_plugin_development, block) do |conn|
          unless conn.closing
            @_server_mutex.synchronize do
              @_server_connections << conn
            end
          end
        end
        server.listen(backlog) if backlog
        server
      end

      SERVER_TRANSPORT_PARAMS = [
        :protocol, :version, :min_version, :max_version, :ciphers, :insecure,
        :ca_path, :cert_path, :private_key_path, :private_key_passphrase, :client_cert_auth,
        :ca_cert_path, :ca_private_key_path, :ca_private_key_passphrase,
        :cert_verifier, :generate_private_key_length,
        :generate_cert_country, :generate_cert_state, :generate_cert_state,
        :generate_cert_locality, :generate_cert_common_name,
        :generate_cert_expiration, :generate_cert_digest,
        :ensure_fips,
      ]

      def server_create_transport_section_object(opts)
        transport_section = configured_section_create(:transport)
        SERVER_TRANSPORT_PARAMS.each do |param|
          if opts.has_key?(param)
            transport_section[param] = opts[param]
          end
        end
        transport_section
      end

      module ServerTransportParams
        include Fluent::Configurable
        config_section :transport, required: false, multi: false, init: true, param_name: :transport_config do
          config_argument :protocol, :enum, list: [:tcp, :tls], default: :tcp

          ### Socket Params ###

          desc "The max size of socket receive buffer. SO_RCVBUF"
          config_param :receive_buffer_size, :size, default: nil

          # SO_LINGER 0 to send RST rather than FIN to avoid lots of connections sitting in TIME_WAIT at src.
          # Set positive value if needing to send FIN on closing on non-Windows.
          # (On Windows, Fluentd can send FIN with zero `linger_timeout` since Fluentd doesn't set 0 to SO_LINGER on Windows.
          # See `socket_option.rb`.)
          # NOTE:
            # Socket-options can be specified from each plugin as needed, so most of them is not defined here for now.
            # This is because there is no positive reason to do so.
            # `linger_timeout` option in particular needs to be defined here
            # although it can be specified from each plugin as well.
            # This is because this helper fixes the default value to `0` for its own reason
            # and it has a critical effect on the behavior.
          desc 'The timeout time used to set linger option.'
          config_param :linger_timeout, :integer, default: 0

          ### TLS Params ###

          config_param :version, :enum, list: Fluent::TLS::SUPPORTED_VERSIONS, default: Fluent::TLS::DEFAULT_VERSION
          config_param :min_version, :enum, list: Fluent::TLS::SUPPORTED_VERSIONS, default: nil
          config_param :max_version, :enum, list: Fluent::TLS::SUPPORTED_VERSIONS, default: nil
          config_param :ciphers, :string, default: Fluent::TLS::CIPHERS_DEFAULT
          config_param :insecure, :bool, default: false
          config_param :ensure_fips, :bool, default: false

          # Cert signed by public CA
          config_param :ca_path, :string, default: nil
          config_param :cert_path, :string, default: nil
          config_param :private_key_path, :string, default: nil
          config_param :private_key_passphrase, :string, default: nil, secret: true
          config_param :client_cert_auth, :bool, default: false

          # Cert generated and signed by private CA Certificate
          config_param :ca_cert_path, :string, default: nil
          config_param :ca_private_key_path, :string, default: nil
          config_param :ca_private_key_passphrase, :string, default: nil, secret: true

          config_param :cert_verifier, :string, default: nil

          # Options for generating certs by private CA certs or self-signed
          config_param :generate_private_key_length, :integer, default: 2048
          config_param :generate_cert_country, :string, default: 'US'
          config_param :generate_cert_state, :string, default: 'CA'
          config_param :generate_cert_locality, :string, default: 'Mountain View'
          config_param :generate_cert_common_name, :string, default: nil
          config_param :generate_cert_expiration, :time, default: 10 * 365 * 86400 # 10years later
          config_param :generate_cert_digest, :enum, list: [:sha1, :sha256, :sha384, :sha512], default: :sha256
        end
      end

      def self.included(mod)
        mod.include ServerTransportParams
      end

      def initialize
        super
        @_servers = []
        @_server_connections = []
        @_server_mutex = Mutex.new
      end

      def configure(conf)
        super

        if @transport_config
          if @transport_config.protocol == :tls
            cert_option_server_validate!(@transport_config)
          end
        end
      end

      def stop
        @_server_mutex.synchronize do
          @_servers.each do |si|
            si.server.detach if si.server.attached?
            # to refuse more connections: (connected sockets are still alive here)
            si.server.close rescue nil
          end
        end

        super
      end

      def shutdown
        # When it invokes conn.cose, it reduces elements in @_server_connections by close_callback,
        # and it reduces the number of loops. This prevents the connection closing.
        # So, it requires invoking #dup to avoid the problem.
        @_server_connections.dup.each do |conn|
          conn.close rescue nil
        end

        super
      end

      def terminate
        @_servers = []
        super
      end

      def server_socket_manager_client
        socket_manager_path = ENV['SERVERENGINE_SOCKETMANAGER_PATH']
        if Fluent.windows?
          socket_manager_path = socket_manager_path.to_i
        end
        ServerEngine::SocketManager::Client.new(socket_manager_path)
      end

      def server_create_tcp_socket(shared, bind, port)
        sock = if shared
                 server_socket_manager_client.listen_tcp(bind, port)
               else
                 # TCPServer.new doesn't set IPV6_V6ONLY flag, so use Addrinfo class instead.
                 # backlog will be set by the caller, we don't need to set backlog here
                 tsock = Addrinfo.tcp(bind, port).listen
                 tsock.autoclose = false
                 TCPServer.for_fd(tsock.fileno)
               end
        # close-on-exec is set by default in Ruby 2.0 or later (, and it's unavailable on Windows)
        sock.fcntl(Fcntl::F_SETFL, Fcntl::O_NONBLOCK) # nonblock
        sock
      end

      def server_create_udp_socket(shared, bind, port)
        sock = if shared
                 server_socket_manager_client.listen_udp(bind, port)
               else
                 # UDPSocket.new doesn't set IPV6_V6ONLY flag, so use Addrinfo class instead.
                 usock = Addrinfo.udp(bind, port).bind
                 usock.autoclose = false
                 UDPSocket.for_fd(usock.fileno)
               end
        # close-on-exec is set by default in Ruby 2.0 or later (, and it's unavailable on Windows)
        sock.fcntl(Fcntl::F_SETFL, Fcntl::O_NONBLOCK) # nonblock
        sock
      end

      # Use string "?" for port, not integer or nil. "?" is clear than -1 or nil in the log.
      PEERADDR_FAILED = ["?", "?", "name resolution failed", "?"]

      class CallbackSocket
        def initialize(server_type, sock, enabled_events = [], close_socket: true)
          @server_type = server_type
          @sock = sock
          @peeraddr = nil
          @enabled_events = enabled_events
          @close_socket = close_socket
        end

        def remote_addr
          @peeraddr[3]
        end

        def remote_host
          @peeraddr[2]
        end

        def remote_port
          @peeraddr[1]
        end

        def send(data, flags = 0)
          @sock.send(data, flags)
        end

        def write(data)
          raise "not implemented here"
        end

        def close_after_write_complete
          @sock.close_after_write_complete = true
        end

        def close
          @sock.close if @close_socket
        end

        def data(&callback)
          on(:data, &callback)
        end

        def on(event, &callback)
          raise "BUG: this event is disabled for #{@server_type}: #{event}" unless @enabled_events.include?(event)
          case event
          when :data
            @sock.data(&callback)
          when :write_complete
            cb = ->(){ callback.call(self) }
            @sock.on_write_complete(&cb)
          when :close
            cb = ->(){ callback.call(self) }
            @sock.on_close(&cb)
          else
            raise "BUG: unknown event: #{event}"
          end
        end
      end

      class TCPCallbackSocket < CallbackSocket
        ENABLED_EVENTS = [:data, :write_complete, :close]

        attr_accessor :buffer

        def initialize(sock)
          super("tcp", sock, ENABLED_EVENTS)
          @peeraddr = (@sock.peeraddr rescue PEERADDR_FAILED)
          @buffer = ''
        end

        def write(data)
          @sock.write(data)
        end
      end

      class TLSCallbackSocket < CallbackSocket
        ENABLED_EVENTS = [:data, :write_complete, :close]

        attr_accessor :buffer

        def initialize(sock)
          super("tls", sock, ENABLED_EVENTS)
          @peeraddr = (@sock.to_io.peeraddr rescue PEERADDR_FAILED)
          @buffer = ''
        end

        def write(data)
          @sock.write(data)
        end
      end

      class UDPCallbackSocket < CallbackSocket
        ENABLED_EVENTS = []

        def initialize(sock, peeraddr, **kwargs)
          super("udp", sock, ENABLED_EVENTS, **kwargs)
          @peeraddr = peeraddr
        end

        def remote_addr
          @peeraddr[3]
        end

        def remote_host
          @peeraddr[2]
        end

        def remote_port
          @peeraddr[1]
        end

        def write(data)
          @sock.send(data, 0, @peeraddr[3], @peeraddr[1])
        end
      end

      module EventHandler
        class UDPServer < Coolio::IO
          attr_writer :close_after_write_complete # dummy for consistent method call in callbacks

          def initialize(sock, max_bytes, flags, close_socket, log, under_plugin_development, &callback)
            raise ArgumentError, "socket must be a UDPSocket: sock = #{sock}" unless sock.is_a?(UDPSocket)

            super(sock)

            @sock = sock
            @max_bytes = max_bytes
            @flags = flags
            @close_socket = close_socket
            @log = log
            @under_plugin_development = under_plugin_development
            @callback = callback

            on_readable_impl = case @callback.arity
                               when 1 then :on_readable_without_sock
                               when 2 then :on_readable_with_sock
                               else
                                 raise "BUG: callback block must have 1 or 2 arguments"
                               end
            self.define_singleton_method(:on_readable, method(on_readable_impl))
          end

          def on_readable_without_sock
            begin
              data = @sock.recv(@max_bytes, @flags)
            rescue Errno::EAGAIN, Errno::EWOULDBLOCK, Errno::EINTR, Errno::ECONNRESET, IOError, Errno::EBADF
              return
            rescue Errno::EMSGSIZE
              # Windows ONLY: This happens when the data size is larger than `@max_bytes`.
              @log.info "A received data was ignored since it was too large."
              return
            end
            @callback.call(data)
          rescue => e
            @log.error "unexpected error in processing UDP data", error: e
            @log.error_backtrace
            raise if @under_plugin_development
          end

          def on_readable_with_sock
            begin
              data, addr = @sock.recvfrom(@max_bytes)
            rescue Errno::EAGAIN, Errno::EWOULDBLOCK, Errno::EINTR, Errno::ECONNRESET, IOError, Errno::EBADF
              return
            rescue Errno::EMSGSIZE
              # Windows ONLY: This happens when the data size is larger than `@max_bytes`.
              @log.info "A received data was ignored since it was too large."
              return
            end
            @callback.call(data, UDPCallbackSocket.new(@sock, addr, close_socket: @close_socket))
          rescue => e
            @log.error "unexpected error in processing UDP data", error: e
            @log.error_backtrace
            raise if @under_plugin_development
          end
        end

        class TCPServer < Coolio::TCPSocket
          attr_reader :closing
          attr_writer :close_after_write_complete

          def initialize(sock, socket_option_setter, close_callback, log, under_plugin_development, connect_callback)
            raise ArgumentError, "socket must be a TCPSocket: sock=#{sock}" unless sock.is_a?(TCPSocket)

            socket_option_setter.call(sock)

            @_handler_socket = sock
            super(sock)

            @log = log
            @under_plugin_development = under_plugin_development

            @connect_callback = connect_callback
            @data_callback = nil
            @close_callback = close_callback

            @callback_connection = nil
            @close_after_write_complete = false
            @closing = false

            @mutex = Mutex.new # to serialize #write and #close
          end

          def to_io
            @_handler_socket
          end

          def data(&callback)
            raise "data callback can be registered just once, but registered twice" if self.singleton_methods.include?(:on_read)
            @data_callback = callback
            on_read_impl = case callback.arity
                           when 1 then :on_read_without_connection
                           when 2 then :on_read_with_connection
                           else
                             raise "BUG: callback block must have 1 or 2 arguments"
                           end
            self.define_singleton_method(:on_read, method(on_read_impl))
          end

          def write(data)
            @mutex.synchronize do
              super
            end
          end

          def on_writable
            super
            close if @close_after_write_complete
          end

          def on_connect
            @callback_connection = TCPCallbackSocket.new(self)
            @connect_callback.call(@callback_connection)
            unless @data_callback
              raise "connection callback must call #data to set data callback"
            end
          end

          def on_read_without_connection(data)
            @data_callback.call(data)
          rescue => e
            @log.error "unexpected error on reading data", host: @callback_connection.remote_host, port: @callback_connection.remote_port, error: e
            @log.error_backtrace
            close rescue nil
            raise if @under_plugin_development
          end

          def on_read_with_connection(data)
            @data_callback.call(data, @callback_connection)
          rescue => e
            @log.error "unexpected error on reading data", host: @callback_connection.remote_host, port: @callback_connection.remote_port, error: e
            @log.error_backtrace
            close rescue nil
            raise if @under_plugin_development
          end

          def close
            @mutex.synchronize do
              return if @closing
              @closing = true
              @close_callback.call(self)
              super
            end
          end
        end

        class TLSServer < Coolio::Socket
          attr_reader :closing
          attr_writer :close_after_write_complete

          # It can't use Coolio::TCPSocket, because Coolio::TCPSocket checks that underlying socket (1st argument of super) is TCPSocket.
          def initialize(sock, context, socket_option_setter, close_callback, log, under_plugin_development, connect_callback)
            raise ArgumentError, "socket must be a TCPSocket: sock=#{sock}" unless sock.is_a?(TCPSocket)

            socket_option_setter.call(sock)
            @_handler_socket = OpenSSL::SSL::SSLSocket.new(sock, context)
            @_handler_socket.sync_close = true
            @_handler_write_buffer = ''.force_encoding('ascii-8bit')
            @_handler_accepted = false
            super(@_handler_socket)

            @log = log
            @under_plugin_development = under_plugin_development

            @connect_callback = connect_callback
            @data_callback = nil
            @close_callback = close_callback

            @callback_connection = nil
            @close_after_write_complete = false
            @closing = false

            @mutex = Mutex.new # to serialize #write and #close
          end

          def to_io
            @_handler_socket.to_io
          end

          def data(&callback)
            raise "data callback can be registered just once, but registered twice" if self.singleton_methods.include?(:on_read)
            @data_callback = callback
            on_read_impl = case callback.arity
                           when 1 then :on_read_without_connection
                           when 2 then :on_read_with_connection
                           else
                             raise "BUG: callback block must have 1 or 2 arguments"
                           end
            self.define_singleton_method(:on_read, method(on_read_impl))
          end

          def write(data)
            @mutex.synchronize do
              @_handler_write_buffer << data
              schedule_write
              data.bytesize
            end
          end

          def try_tls_accept
            return true if @_handler_accepted

            begin
              result = @_handler_socket.accept_nonblock(exception: false) # this method call actually try to do handshake via TLS
              if result == :wait_readable || result == :wait_writable
                # retry accept_nonblock: there aren't enough data in underlying socket buffer
              else
                @_handler_accepted = true

                @callback_connection = TLSCallbackSocket.new(self)
                @connect_callback.call(@callback_connection)
                unless @data_callback
                  raise "connection callback must call #data to set data callback"
                end

                return true
              end
            rescue Errno::EPIPE, Errno::ECONNRESET, Errno::ETIMEDOUT, Errno::ECONNREFUSED, Errno::EHOSTUNREACH => e
              peeraddr = (@_handler_socket.peeraddr rescue PEERADDR_FAILED)
              @log.trace "unexpected error before accepting TLS connection",
                         addr: peeraddr[3], host: peeraddr[2], port: peeraddr[1], error: e
              close rescue nil
            rescue OpenSSL::SSL::SSLError => e
              peeraddr = (@_handler_socket.peeraddr rescue PEERADDR_FAILED)
              # Use same log level as on_readable
              @log.warn "unexpected error before accepting TLS connection by OpenSSL",
                        addr: peeraddr[3], host: peeraddr[2], port: peeraddr[1], error: e
              close rescue nil
            end

            false
          end

          def on_connect
            try_tls_accept
          end

          def on_readable
            if try_tls_accept
              super
            end
          rescue IO::WaitReadable, IO::WaitWritable
            # ignore and return with doing nothing
          rescue OpenSSL::SSL::SSLError => e
            @log.warn "close socket due to unexpected ssl error: #{e}"
            close rescue nil
          end

          def on_writable
            begin
              @mutex.synchronize do
                # Consider write_nonblock with {exception: false} when IO::WaitWritable error happens frequently.
                written_bytes = @_handler_socket.write_nonblock(@_handler_write_buffer)
                @_handler_write_buffer.slice!(0, written_bytes)
              end

              # No need to call `super` in a synchronized context because TLSServer doesn't use the inner buffer(::IO::Buffer) of Coolio::IO.
              # Instead of using Coolio::IO's inner buffer, TLSServer has own buffer(`@_handler_write_buffer`). See also TLSServer#write.
              # Actually, the only reason calling `super` here is call Coolio::IO#disable_write_watcher.
              # If `super` is called in a synchronized context, it could cause a mutex recursive locking since Coolio::IO#on_write_complete
              # eventually calls TLSServer#close which try to get a lock.
              super

              close if @close_after_write_complete
            rescue IO::WaitWritable, IO::WaitReadable
              return
            rescue Errno::EINTR
              return
            rescue SystemCallError, IOError, SocketError
              # SystemCallError catches Errno::EPIPE & Errno::ECONNRESET amongst others.
              close rescue nil
              return
            rescue OpenSSL::SSL::SSLError => e
              @log.debug "unexpected SSLError while writing data into socket connected via TLS", error: e
            end
          end

          def on_read_without_connection(data)
            @data_callback.call(data)
          rescue => e
            @log.error "unexpected error on reading data", host: @callback_connection.remote_host, port: @callback_connection.remote_port, error: e
            @log.error_backtrace
            close rescue nil
            raise if @under_plugin_development
          end

          def on_read_with_connection(data)
            @data_callback.call(data, @callback_connection)
          rescue => e
            @log.error "unexpected error on reading data", host: @callback_connection.remote_host, port: @callback_connection.remote_port, error: e
            @log.error_backtrace
            close rescue nil
            raise if @under_plugin_development
          end

          def close
            @mutex.synchronize do
              return if @closing
              @closing = true
              @close_callback.call(self)
              super
            end
          end
        end
      end
    end
  end
end
