module Excon
  class Connection
    include Utils

    attr_reader :data

    def connection
      Excon.display_warning('Excon::Connection#connection is deprecated use Excon::Connection#data instead.')
      @data
    end
    def connection=(new_params)
      Excon.display_warning('Excon::Connection#connection= is deprecated. Use of this method may cause unexpected results.')
      @data = new_params
    end

    def params
      Excon.display_warning('Excon::Connection#params is deprecated use Excon::Connection#data instead.')
      @data
    end
    def params=(new_params)
      Excon.display_warning('Excon::Connection#params= is deprecated. Use of this method may cause unexpected results.')
      @data = new_params
    end

    def proxy
      Excon.display_warning('Excon::Connection#proxy is deprecated use Excon::Connection#data[:proxy] instead.')
      @data[:proxy]
    end
    def proxy=(new_proxy)
      Excon.display_warning('Excon::Connection#proxy= is deprecated. Use of this method may cause unexpected results.')
      @data[:proxy] = new_proxy
    end

    # Initializes a new Connection instance
    #   @param [Hash<Symbol, >] params One or more optional params
    #     @option params [String] :body Default text to be sent over a socket. Only used if :body absent in Connection#request params
    #     @option params [Hash<Symbol, String>] :headers The default headers to supply in a request. Only used if params[:headers] is not supplied to Connection#request
    #     @option params [String] :host The destination host's reachable DNS name or IP, in the form of a String
    #     @option params [String] :path Default path; appears after 'scheme://host:port/'. Only used if params[:path] is not supplied to Connection#request
    #     @option params [Fixnum] :port The port on which to connect, to the destination host
    #     @option params [Hash]   :query Default query; appended to the 'scheme://host:port/path/' in the form of '?key=value'. Will only be used if params[:query] is not supplied to Connection#request
    #     @option params [String] :scheme The protocol; 'https' causes OpenSSL to be used
    #     @option params [String] :socket The path to the unix socket (required for 'unix://' connections)
    #     @option params [String] :ciphers Only use the specified SSL/TLS cipher suites; use OpenSSL cipher spec format e.g. 'HIGH:!aNULL:!3DES' or 'AES256-SHA:DES-CBC3-SHA'
    #     @option params [String] :proxy Proxy server; e.g. 'http://myproxy.com:8888'
    #     @option params [Fixnum] :retry_limit Set how many times we'll retry a failed request.  (Default 4)
    #     @option params [Class] :instrumentor Responds to #instrument as in ActiveSupport::Notifications
    #     @option params [String] :instrumentor_name Name prefix for #instrument events.  Defaults to 'excon'
    def initialize(params = {})
      @data = Excon.defaults.dup
      # merge does not deep-dup, so make sure headers is not the original
      @data[:headers] = @data[:headers].dup

      # the same goes for :middlewares
      @data[:middlewares] = @data[:middlewares].dup

      params = validate_params(:connection, params)
      @data.merge!(params)

      unless @data[:scheme] == UNIX
        no_proxy_env = ENV["no_proxy"] || ENV["NO_PROXY"] || ""
        no_proxy_list = no_proxy_env.scan(/\*?\.?([^\s,:]+)(?::(\d+))?/i).map { |s| [s[0], s[1]] }
        unless no_proxy_list.index { |h| /(^|\.)#{h[0]}$/.match(@data[:host]) && (h[1].nil? || h[1].to_i == @data[:port]) }
          if @data[:scheme] == HTTPS && (ENV.has_key?('https_proxy') || ENV.has_key?('HTTPS_PROXY'))
            @data[:proxy] = setup_proxy(ENV['https_proxy'] || ENV['HTTPS_PROXY'])
          elsif (ENV.has_key?('http_proxy') || ENV.has_key?('HTTP_PROXY'))
            @data[:proxy] = setup_proxy(ENV['http_proxy'] || ENV['HTTP_PROXY'])
          elsif @data.has_key?(:proxy)
            @data[:proxy] = setup_proxy(@data[:proxy])
          end
        end
      end

      if @data[:proxy]
        @data[:headers]['Proxy-Connection'] ||= 'Keep-Alive'
        # https credentials happen in handshake
        if @data[:scheme] == 'http' && (@data[:proxy][:user] || @data[:proxy][:password])
          user, pass = Utils.unescape_form(@data[:proxy][:user].to_s), Utils.unescape_form(@data[:proxy][:password].to_s)
          auth = ['' << user.to_s << ':' << pass.to_s].pack('m').delete(Excon::CR_NL)
          @data[:headers]['Proxy-Authorization'] = 'Basic ' << auth
        end
      end

      if ENV.has_key?('EXCON_DEBUG') || ENV.has_key?('EXCON_STANDARD_INSTRUMENTOR')
        @data[:instrumentor] = Excon::StandardInstrumentor
      end

      # Use Basic Auth if url contains a login
      if @data[:user] || @data[:password]
        user, pass = Utils.unescape_form(@data[:user].to_s), Utils.unescape_form(@data[:password].to_s)
        @data[:headers]['Authorization'] ||= 'Basic ' << ['' << user.to_s << ':' << pass.to_s].pack('m').delete(Excon::CR_NL)
      end

      @socket_key = '' << @data[:scheme]
      if @data[:scheme] == UNIX
        if @data[:host]
          raise ArgumentError, "The `:host` parameter should not be set for `unix://` connections.\n" +
                               "When supplying a `unix://` URI, it should start with `unix:/` or `unix:///`."
        elsif !@data[:socket]
          raise ArgumentError, 'You must provide a `:socket` for `unix://` connections'
        else
          @socket_key << '://' << @data[:socket]
        end
      else
        @socket_key << '://' << @data[:host] << port_string(@data)
      end
      reset
    end

    def error_call(datum)
      if datum[:error]
        raise(datum[:error])
      end
    end

    def request_call(datum)
      begin
        if datum.has_key?(:response)
          # we already have data from a middleware, so bail
          return datum
        else
          socket.data = datum
          # start with "METHOD /path"
          request = datum[:method].to_s.upcase << ' '
          if datum[:proxy]
            request << datum[:scheme] << '://' << datum[:host] << port_string(datum)
          end
          request << datum[:path]

          # add query to path, if there is one
          request << query_string(datum)

          # finish first line with "HTTP/1.1\r\n"
          request << HTTP_1_1

          if datum.has_key?(:request_block)
            datum[:headers]['Transfer-Encoding'] = 'chunked'
          else
            body = datum[:body].is_a?(String) ? StringIO.new(datum[:body]) : datum[:body]

            # The HTTP spec isn't clear on it, but specifically, GET requests don't usually send bodies;
            # if they don't, sending Content-Length:0 can cause issues.
            unless datum[:method].to_s.casecmp('GET') == 0 && body.nil?
              unless datum[:headers].has_key?('Content-Length')
                datum[:headers]['Content-Length'] = detect_content_length(body)
              end
            end
          end

          if datum[:response_block]
            datum[:headers]['TE'] = 'trailers'
          else
            datum[:headers]['TE'] = 'trailers, deflate, gzip'
          end
          datum[:headers]['Connection'] = datum[:persistent] ? 'TE' : 'TE, close'

          # add headers to request
          datum[:headers].each do |key, values|
            [values].flatten.each do |value|
              request << key.to_s << ': ' << value.to_s << CR_NL
            end
          end

          # add additional "\r\n" to indicate end of headers
          request << CR_NL
          socket.write(request) # write out request + headers

          if datum.has_key?(:request_block)
            while true # write out body with chunked encoding
              chunk = datum[:request_block].call
              if FORCE_ENC
                chunk.force_encoding('BINARY')
              end
              if chunk.length > 0
                socket.write(chunk.length.to_s(16) << CR_NL << chunk << CR_NL)
              else
                socket.write('0' << CR_NL << CR_NL)
                break
              end
            end
          elsif !body.nil? # write out body
            if body.respond_to?(:binmode)
              body.binmode
            end
            if body.respond_to?(:pos=)
              body.pos = 0
            end
            while chunk = body.read(datum[:chunk_size])
              socket.write(chunk)
            end
          end
        end
      rescue => error
        case error
        when Excon::Errors::StubNotFound, Excon::Errors::Timeout
          raise(error)
        else
          raise(Excon::Errors::SocketError.new(error))
        end
      end

      datum
    end

    def response_call(datum)
      if datum.has_key?(:response_block) && !datum[:response][:body].empty?
        response_body = datum[:response][:body].dup
        content_length = remaining = response_body.bytesize
        while remaining > 0
          datum[:response_block].call(response_body.slice!(0, [datum[:chunk_size], remaining].min), [remaining - datum[:chunk_size], 0].max, content_length)
          remaining -= datum[:chunk_size]
        end
      end
      datum
    end

    # Sends the supplied request to the destination host.
    #   @yield [chunk] @see Response#self.parse
    #   @param [Hash<Symbol, >] params One or more optional params, override defaults set in Connection.new
    #     @option params [String] :body text to be sent over a socket
    #     @option params [Hash<Symbol, String>] :headers The default headers to supply in a request
    #     @option params [String] :path appears after 'scheme://host:port/'
    #     @option params [Hash]   :query appended to the 'scheme://host:port/path/' in the form of '?key=value'
    def request(params={}, &block)
      params = validate_params(:request, params)
      # @data has defaults, merge in new params to override
      datum = @data.merge(params)
      datum[:headers] = @data[:headers].merge(datum[:headers] || {})

      if datum[:scheme] == UNIX
        datum[:headers]['Host']   ||= '' << datum[:socket]
      else
        datum[:headers]['Host']   ||= '' << datum[:host] << port_string(datum)
      end
      datum[:retries_remaining] ||= datum[:retry_limit]

      # if path is empty or doesn't start with '/', insert one
      unless datum[:path][0, 1] == '/'
        datum[:path] = datum[:path].dup.insert(0, '/')
      end

      if block_given?
        Excon.display_warning('Excon requests with a block are deprecated, pass :response_block instead.')
        datum[:response_block] = Proc.new
      end

      if datum[:idempotent]
        if datum[:request_block]
          Excon.display_warning('Excon requests with a :request_block can not be :idempotent.')
          datum[:idempotent] = false
        end
        if datum[:pipeline]
          Excon.display_warning("Excon requests can not be :idempotent when pipelining.")
          datum[:idempotent] = false
        end
      end

      datum[:connection] = self

      datum[:stack] = datum[:middlewares].map do |middleware|
        lambda {|stack| middleware.new(stack)}
      end.reverse.inject(self) do |middlewares, middleware|
        middleware.call(middlewares)
      end
      datum = datum[:stack].request_call(datum)

      unless datum[:pipeline]
        datum = response(datum)

        if datum[:persistent]
          if key = datum[:response][:headers].keys.detect {|k| k.casecmp('Connection') == 0 }
            if split_header_value(datum[:response][:headers][key]).any? {|t| t.casecmp('close') }
              reset
            end
          end
        else
          reset
        end

        Excon::Response.new(datum[:response])
      else
        datum
      end
    rescue => error
      reset
      datum[:error] = error
      if datum[:stack]
        datum[:stack].error_call(datum)
      else
        raise error
      end
    end

    # Sends the supplied requests to the destination host using pipelining.
    #   @pipeline_params [Array<Hash>] pipeline_params An array of one or more optional params, override defaults set in Connection.new, see #request for details
    def requests(pipeline_params)
      pipeline_params.each {|params| params.merge!(:pipeline => true, :persistent => true) }
      pipeline_params.last.merge!(:persistent => @data[:persistent])

      responses = pipeline_params.map do |params|
        request(params)
      end.map do |datum|
        Excon::Response.new(response(datum)[:response])
      end

      if @data[:persistent]
        if key = responses.last[:headers].keys.detect {|k| k.casecmp('Connection') == 0 }
          if split_header_value(responses.last[:headers][key]).any? {|t| t.casecmp('close') }
            reset
          end
        end
      else
        reset
      end

      responses
    end

    def reset
      if old_socket = sockets.delete(@socket_key)
        old_socket.close rescue nil
      end
    end

    # Generate HTTP request verb methods
    Excon::HTTP_VERBS.each do |method|
      class_eval <<-DEF, __FILE__, __LINE__ + 1
        def #{method}(params={}, &block)
          request(params.merge!(:method => :#{method}), &block)
        end
      DEF
    end

    def retry_limit=(new_retry_limit)
      Excon.display_warning('Excon::Connection#retry_limit= is deprecated, pass :retry_limit to the initializer.')
      @data[:retry_limit] = new_retry_limit
    end

    def retry_limit
      Excon.display_warning('Excon::Connection#retry_limit is deprecated, use Excon::Connection#data[:retry_limit].')
      @data[:retry_limit] ||= DEFAULT_RETRY_LIMIT
    end

    def inspect
      vars = instance_variables.inject({}) do |accum, var|
        accum.merge!(var.to_sym => instance_variable_get(var))
      end
      if vars[:'@data'][:headers].has_key?('Authorization')
        vars[:'@data'] = vars[:'@data'].dup
        vars[:'@data'][:headers] = vars[:'@data'][:headers].dup
        vars[:'@data'][:headers]['Authorization'] = REDACTED
      end
      if vars[:'@data'][:password]
        vars[:'@data'] = vars[:'@data'].dup
        vars[:'@data'][:password] = REDACTED
      end
      inspection = '#<Excon::Connection:'
      inspection << (object_id << 1).to_s(16)
      vars.each do |key, value|
        inspection << ' ' << key.to_s << '=' << value.inspect
      end
      inspection << '>'
      inspection
    end

    private

    def detect_content_length(body)
      if body.respond_to?(:size)
        # IO object: File, Tempfile, StringIO, etc.
        body.size
      elsif body.respond_to?(:stat)
        # for 1.8.7 where file does not have size
        body.stat.size
      else
        0
      end
    end

    def validate_params(validation, params)
      valid_keys = case validation
      when :connection
        valid_connection_keys(params)
      when :request
        valid_request_keys(params)
      end
      invalid_keys = params.keys - valid_keys
      unless invalid_keys.empty?
        Excon.display_warning("Invalid Excon #{validation} keys: #{invalid_keys.map(&:inspect).join(', ')}")
        # FIXME: for now, just warn, don't mutate, give things (ie fog) a chance to catch up
        #params = params.dup
        #invalid_keys.each {|key| params.delete(key) }
      end
      params
    end

    def response(datum={})
      datum[:stack].response_call(datum)
    rescue => error
      case error
      when Excon::Errors::HTTPStatusError, Excon::Errors::Timeout
        raise(error)
      else
        raise(Excon::Errors::SocketError.new(error))
      end
    end

    def socket
      sockets[@socket_key] ||= if @data[:scheme] == HTTPS
        Excon::SSLSocket.new(@data)
      elsif @data[:scheme] == UNIX
        Excon::UnixSocket.new(@data)
      else
        Excon::Socket.new(@data)
      end
    end

    def sockets
      Thread.current[:_excon_sockets] ||= {}
    end

    def setup_proxy(proxy)
      case proxy
      when String
        uri = URI.parse(proxy)
        unless uri.host and uri.port and uri.scheme
          raise Excon::Errors::ProxyParseError, "Proxy is invalid"
        end
        {
          :host       => uri.host,
          :password   => uri.password,
          :port       => uri.port,
          :scheme     => uri.scheme,
          :user       => uri.user
        }
      else
        proxy
      end
    end
  end
end
