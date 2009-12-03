require 'digest/md5'
require 'active_support/core_ext/module/delegation'

module ActionDispatch # :nodoc:
  # Represents an HTTP response generated by a controller action. One can use
  # an ActionDispatch::Response object to retrieve the current state
  # of the response, or customize the response. An Response object can
  # either represent a "real" HTTP response (i.e. one that is meant to be sent
  # back to the web browser) or a test response (i.e. one that is generated
  # from integration tests). See CgiResponse and TestResponse, respectively.
  #
  # Response is mostly a Ruby on Rails framework implement detail, and
  # should never be used directly in controllers. Controllers should use the
  # methods defined in ActionController::Base instead. For example, if you want
  # to set the HTTP response's content MIME type, then use
  # ActionControllerBase#headers instead of Response#headers.
  #
  # Nevertheless, integration tests may want to inspect controller responses in
  # more detail, and that's when Response can be useful for application
  # developers. Integration test methods such as
  # ActionDispatch::Integration::Session#get and
  # ActionDispatch::Integration::Session#post return objects of type
  # TestResponse (which are of course also of type Response).
  #
  # For example, the following demo integration "test" prints the body of the
  # controller response to the console:
  #
  #  class DemoControllerTest < ActionDispatch::IntegrationTest
  #    def test_print_root_path_to_console
  #      get('/')
  #      puts @response.body
  #    end
  #  end
  class Response < Rack::Response
    attr_accessor :request, :blank

    attr_writer :header, :sending_file
    alias_method :headers=, :header=

    def initialize
      @status = 200
      @header = {}
      @cache_control = {}

      @writer = lambda { |x| @body << x }
      @block = nil
      @length = 0

      @body, @cookie = [], []
      @sending_file = false

      yield self if block_given?
    end

    def cache_control
      @cache_control ||= {}
    end

    def status=(status)
      @status = status.to_i
    end

    # The response code of the request
    def response_code
      @status
    end

    # Returns a String to ensure compatibility with Net::HTTPResponse
    def code
      @status.to_s
    end

    def message
      StatusCodes::STATUS_CODES[@status]
    end
    alias_method :status_message, :message

    def body
      str = ''
      each { |part| str << part.to_s }
      str
    end

    EMPTY = " "

    def body=(body)
      @blank = true if body == EMPTY
      @body = body.respond_to?(:to_str) ? [body] : body
    end

    def body_parts
      @body
    end

    def location
      headers['Location']
    end
    alias_method :redirect_url, :location

    def location=(url)
      headers['Location'] = url
    end

    # Sets the HTTP response's content MIME type. For example, in the controller
    # you could write this:
    #
    #  response.content_type = "text/plain"
    #
    # If a character set has been defined for this response (see charset=) then
    # the character set information will also be included in the content type
    # information.
    attr_accessor :charset, :content_type

    def last_modified
      if last = headers['Last-Modified']
        Time.httpdate(last)
      end
    end

    def last_modified?
      headers.include?('Last-Modified')
    end

    def last_modified=(utc_time)
      headers['Last-Modified'] = utc_time.httpdate
    end

    def etag
      @etag
    end

    def etag?
      @etag
    end

    def etag=(etag)
      key = ActiveSupport::Cache.expand_cache_key(etag)
      @etag = %("#{Digest::MD5.hexdigest(key)}")
    end

    CONTENT_TYPE    = "Content-Type"

    cattr_accessor(:default_charset) { "utf-8" }

    def assign_default_content_type_and_charset!
      return if headers[CONTENT_TYPE].present?

      @content_type ||= Mime::HTML
      @charset      ||= self.class.default_charset

      type = @content_type.to_s.dup
      type << "; charset=#{@charset}" unless @sending_file

      headers[CONTENT_TYPE] = type
    end

    def to_a
      assign_default_content_type_and_charset!
      handle_conditional_get!
      self["Set-Cookie"] = @cookie.join("\n")
      self["ETag"]       = @etag if @etag
      super
    end

    alias prepare! to_a

    def each(&callback)
      if @body.respond_to?(:call)
        @writer = lambda { |x| callback.call(x) }
        @body.call(self, self)
      else
        @body.each { |part| callback.call(part.to_s) }
      end

      @writer = callback
      @block.call(self) if @block
    end

    def write(str)
      str = str.to_s
      @writer.call str
      str
    end

    # Returns the response cookies, converted to a Hash of (name => value) pairs
    #
    #   assert_equal 'AuthorOfNewPage', r.cookies['author']
    def cookies
      cookies = {}
      if header = @cookie
        header = header.split("\n") if header.respond_to?(:to_str)
        header.each do |cookie|
          if pair = cookie.split(';').first
            key, value = pair.split("=").map { |v| Rack::Utils.unescape(v) }
            cookies[key] = value
          end
        end
      end
      cookies
    end

    def set_cookie(key, value)
      case value
      when Hash
        domain  = "; domain="  + value[:domain]    if value[:domain]
        path    = "; path="    + value[:path]      if value[:path]
        # According to RFC 2109, we need dashes here.
        # N.B.: cgi.rb uses spaces...
        expires = "; expires=" + value[:expires].clone.gmtime.
          strftime("%a, %d-%b-%Y %H:%M:%S GMT")    if value[:expires]
        secure = "; secure"  if value[:secure]
        httponly = "; HttpOnly" if value[:httponly]
        value = value[:value]
      end
      value = [value]  unless Array === value
      cookie = Rack::Utils.escape(key) + "=" +
        value.map { |v| Rack::Utils.escape v }.join("&") +
        "#{domain}#{path}#{expires}#{secure}#{httponly}"

      @cookie << cookie
    end

    def delete_cookie(key, value={})
      @cookie.reject! { |cookie|
        cookie =~ /\A#{Rack::Utils.escape(key)}=/
      }

      set_cookie(key,
                 {:value => '', :path => nil, :domain => nil,
                   :expires => Time.at(0) }.merge(value))
    end

    private
      def handle_conditional_get!
        if etag? || last_modified? || !@cache_control.empty?
          set_conditional_cache_control!
        elsif nonempty_ok_response?
          self.etag = @body

          if request && request.etag_matches?(etag)
            self.status = 304
            self.body = []
          end

          set_conditional_cache_control!
        else
          headers["Cache-Control"] = "no-cache"
        end
      end

      def nonempty_ok_response?
        @status == 200 && string_body?
      end

      def string_body?
        !@blank && @body.respond_to?(:all?) && @body.all? { |part| part.is_a?(String) }
      end

      DEFAULT_CACHE_CONTROL = "max-age=0, private, must-revalidate"

      def set_conditional_cache_control!
        control = @cache_control

        if control.empty?
          headers["Cache-Control"] = DEFAULT_CACHE_CONTROL
        elsif @cache_control[:no_cache]
          headers["Cache-Control"] = "no-cache"
        else
          extras  = control[:extras]
          max_age = control[:max_age]

          options = []
          options << "max-age=#{max_age.to_i}" if max_age
          options << (control[:public] ? "public" : "private")
          options << "must-revalidate" if control[:must_revalidate]
          options.concat(extras) if extras

          headers["Cache-Control"] = options.join(", ")
        end

      end
  end
end
