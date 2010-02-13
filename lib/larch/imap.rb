# The Larch::IMAP class is a delegating wrapper for (but not a subclass of) the
# Net::IMAP class.
class Larch::IMAP
  attr_reader :capability, :options, :quirks, :uri

  def self.const_missing(name)
    unless Net::IMAP.const_defined?(name)
      raise NameError, "uninitialized constant Larch::IMAP::#{name}"
    end

    Net::IMAP.const_get(name)
  end

  # Creates a new Larch::IMAP object, but doesn't open a connection.
  #
  # The _uri_ parameter must be an IMAP URI with an 'imap' or 'imaps' scheme,
  # a username and password, and a hostname at a minimum. Unless a custom port
  # is specified, port 143 will be used for 'imap' and port 993 for 'imaps'.
  #
  # The path portion of the URI may be used to specify an IMAP mailbox that
  # should be selected by default. The '/' character in the path will be
  # translated automatically into whatever mailbox hierarchy delimiter the
  # server claims to support.
  #
  # In addition to the URI, the following options may be specified as hash
  # params:
  #
  # [:max_retries]
  #   After a recoverable error occurs, retry the operation up to this many
  #   times. Default is 3.
  #
  # [:read_only]
  #   Open mailboxes in read-only mode (EXAMINE) by default.
  #
  # [:ssl_certs]
  #   Path to a trusted certificate bundle to use to verify server SSL
  #   certificates. You can download a bundle of certificate authority root
  #   certs at http://curl.haxx.se/ca/cacert.pem (it's up to you to verify that
  #   this bundle hasn't been tampered with, however; don't trust it blindly).
  #
  # [:ssl_verify]
  #   If +true+, server SSL certificates will be verified against the trusted
  #   certificate bundle specified in +ssl_certs+. By default, server SSL
  #   certificates are not verified.
  def initialize(uri, options = {})
    @uri = uri.is_a?(URI) ? uri : URI(uri)

    raise ArgumentError, "not a valid IMAP URI: #{uri}" unless @uri.scheme == 'imap' || @uri.scheme == 'imaps'
    raise ArgumentError, "URI must include a host" unless @uri.host
    raise ArgumentError, "URI must include a username and password" unless @uri.user && @uri.password

    @authenticated = false
    @capability    = []
    @conn          = nil
    @options       = {:max_retries => 3, :ssl_verify => false}.merge(options)
    @quirks        = {}

    # Net::IMAP instance methods that don't require authentication.
    @noauth = [
      :add_response_handler, :capability, :client_thread, :greeting, :login,
      :logout, :remove_response_handler, :response_handlers, :responses,
      :starttls
    ]
  end

  # Logs into the IMAP server using the best available authentication method and
  # the username and password specified in the current URI. Returns +false+ if
  # not connected, +true+ if authentication was successful or if already
  # authenticated.
  #
  # The following authentication methods will be tried, in this order, if the
  # server claims to support them:
  #
  #   - CRAM-MD5
  #   - LOGIN
  #   - PLAIN
  #
  # If the server does not support any of these authentication methods, a
  # Larch::IMAP::NoSupportedAuthMethod exception will be raised.
  def authenticate
    raise NotConnected, "must connect before authenticating" if disconnected?
    return true if @authenticated

    auth_methods  = []
    methods_tried = []

    ['PLAIN', 'LOGIN', 'CRAM-MD5'].each do |method|
      auth_methods << method if @capability.include?("AUTH=#{method}")
    end

    # Remove PLAIN and LOGIN from the list if the capability list includes
    # LOGINDISABLED, in order to avoid sending the user's credentials in the
    # clear when we know the server won't accept them.
    if @capability.include?('LOGINDISABLED')
      auth_methods.delete('PLAIN')
      auth_methods.delete('LOGIN')
    end

    begin
      methods_tried << method = auth_methods.pop

      response = if method == 'PLAIN'
        @conn.login(username, password)
      else
        @conn.authenticate(method, username, password)
      end

    rescue Net::IMAP::BadResponseError,
           Net::IMAP::NoResponseError => e

      retry unless auth_methods.empty?

      raise e, "#{e.message} (tried #{methods_tried.join(', ')})"
    end

    update_capability(response)

    @authenticated = true
  end

  # Returns +true+ if connected and authenticated.
  def authenticated?
    connected? && @authenticated
  end

  # Sends a CLOSE command to close the currently selected mailbox. If the
  # mailbox is in read/write mode (SELECTed), the CLOSE command will permanently
  # expunge all messages with the <code>\Deleted</code> flag set.
  def close
    require_auth
    response = @conn.close
    @uri.path = ''
    response
  end

  # Opens a connection to the IMAP server. If a connection is already open, it
  # will be closed and reopened.
  def connect
    @authenticated = false

    @conn = Net::IMAP.new(host, port, ssl?,
        ssl? && @options[:ssl_verify] ? options[:ssl_certs] : nil,
        @options[:ssl_verify])

    check_quirks

    # If this is Yahoo! Mail, we have to send a special command before it'll let
    # us authenticate.
    if @quirks[:yahoo]
      @conn.instance_eval { send_command('ID ("guid" "1")') }
    end

    # Capability check must come after the Yahoo! hack, since Yahoo! doesn't
    # send a capability list in the greeting or respond to CAPABILITY before the
    # hack.
    update_capability(@conn.greeting)

    true
  end

  # Returns +true+ if connected to the server.
  def connected?
    !disconnected?
  end

  # Disconnects from the server.
  def disconnect
    if connected?
      @authenticated = false
      @conn.disconnect
      @conn = nil
    end
  end

  # Returns +true+ if disconnected from the server.
  def disconnected?
    !@conn || @conn.disconnected?
  end

  # Sends an EXAMINE command to select the specified _mailbox_. Works just like
  # #select, except the mailbox is opened in read-only mode.
  def examine(mailbox)
    require_auth

    response  = @conn.examine(mailbox)
    @uri.path = "/#{CGI.escape(Net::IMAP.decode_utf7(mailbox))}"

    response
  end

  # Gets the IMAP hostname.
  def host
    @uri.host
  end

  # Gets the current IMAP mailbox, or +nil+ if there isn't one. If _utf7_ is
  # +true+, the mailbox will be returned as a modified UTF-7 string.
  def mailbox(utf7 = false)
    mb = @uri.path[1..-1]
    mb = mb.nil? || mb.empty? ? nil : CGI.unescape(mb)
    mb && utf7 ? Net::IMAP.encode_utf7(mb) : mb
  end

  def method_missing(name, *args, &block)
    unless Net::IMAP.method_defined?(name)
      raise NoMethodError, "undefined method `#{name}' for Larch::IMAP"
    end

    require_auth unless @noauth.include?(name)
    @conn.send(name, *args, &block)
  end

  # Gets the IMAP password.
  def password
    CGI.unescape(@uri.password)
  end

  # Gets the IMAP port number.
  def port
    @uri.port || (ssl? ? 993 : 143)
  end

  # Connects, authenticates, opens the mailbox specified in the URI (if any),
  # executes the given block, retries if a recoverable error occurs, raises an
  # exception if an unrecoverable error occurs.
  def safely
    retries = 0

    begin
      start

      yield

    rescue Errno::ECONNABORTED,
           Errno::ECONNREFUSED,
           Errno::ECONNRESET,
           Errno::ENOTCONN,
           Errno::EPIPE,
           Errno::ETIMEDOUT,
           IOError,
           Net::IMAP::ByeResponseError,
           OpenSSL::SSL::SSLError,
           SocketError => e

      raise unless (retries += 1) <= @options[:max_retries]

      # Special check to ensure that we don't retry on OpenSSL certificate
      # verification errors.
      raise if e.is_a?(OpenSSL::SSL::SSLError) && e.message =~ /certificate verify failed/

      @conn          = nil
      @authenticated = false

      sleep 1 * retries
      retry
    end
  end

  # Sends a SELECT command to select the specified _mailbox_.
  def select(mailbox)
    require_auth

    response  = @conn.select(mailbox)
    @uri.path = "/#{CGI.escape(Net::IMAP.decode_utf7(mailbox))}"

    response
  end

  # Starts an IMAP session by connecting, authenticating, and opening the
  # mailbox specified in the current URI (if any). If already connected and
  # authenticated, this method will simply attempt to open the mailbox.
  def start
    connect unless connected?
    authenticate unless authenticated?

    if mb = mailbox(true)
      @options[:read_only] ? examine(mb) : select(mb)
    end
  end

  # Gets the SSL status.
  def ssl?
    @uri.scheme == 'imaps'
  end

  # Gets the IMAP username.
  def username
    CGI.unescape(@uri.user)
  end

  private

  # Tries to identify server implementations with certain quirks that we'll need
  # to work around.
  def check_quirks
    return unless @conn &&
        @conn.greeting.kind_of?(Net::IMAP::UntaggedResponse) &&
        @conn.greeting.data.kind_of?(Net::IMAP::ResponseText)

    if @conn.greeting.data.text =~ /^Gimap ready/
      @quirks[:gmail] = true
    elsif host =~ /^imap(?:-ssl)?\.mail\.yahoo\.com$/
      @quirks[:yahoo] = true
    end
  end

  def require_connection
    raise NotConnected, "not connected" unless connected?
  end

  def require_auth
    require_connection
    raise NotAuthenticated, "not authenticated" unless authenticated?
  end

  # Looks for a capability list in the specified IMAP _response_, or sends a
  # CAPABILITY request if no response is given or if the given response doesn't
  # contain a capability list.
  #
  # Updates @capability with the results and returns it.
  def update_capability(response = nil)
    if response.is_a?(Net::IMAP::UntaggedResponse) ||
        response.is_a?(Net::IMAP::TaggedResponse)

      if (data = response.data).is_a?(Net::IMAP::ResponseText) &&
          data.code.is_a?(Net::IMAP::ResponseCode) &&
          data.code.name == 'CAPABILITY'

        return @capability = data.code.data.split(' ')
      end
    end

    require_connection

    @capability = @conn.capability
  end

  class Error < Larch::Error; end
  class NoSupportedAuthMethod < Error; end
  class NotAuthenticated < Error; end
  class NotConnected < Error; end
end
