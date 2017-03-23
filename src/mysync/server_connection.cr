require "./endpoint"
require "monocypher"
require "socket"
require "./network"
require "./package"

module MySync
  enum ConnectionCommand
    LoginReceived
    PacketReceived
    Close
  end

  class GameConnection
    getter socket
    getter received
    getter control
    getter last_message : Time
    getter endpoint : EndPoint?

    def initialize(@address : Address, @socket : UDPSocket,
                   @endpoint_factory : EndPointFactory,
                   @server : UDPGameServer)
      @last_message = Time.now
      @received = Package.new(MAX_RAW_SIZE) # TODO - remove small tail?
      @received_decrypted = Package.new(MAX_PACKAGE_SIZE)
      @tosend = Package.new(MAX_RAW_SIZE)
      @header = @tosend.to_unsafe.as(UInt32*)

      @control = Channel(ConnectionCommand).new
      @symmetric_key = Crypto::SymmetricKey.new
    end

    def should_die(at_time : Time) : Bool
      return true if at_time - @last_message > @server.disconnect_delay # timeout
      return false unless a = @endpoint                                 # not authentificated
      a.requested_disconnect
    end

    # TODO - send packages asynchronously?

    private def process_data_packet
      return unless point = @endpoint # connection must be already established
      # first it decrypts and check
      return if @received.size - Crypto::OVERHEAD_SYMMETRIC <= 0
      @received_decrypted.size = @received.size - Crypto::OVERHEAD_SYMMETRIC
      return unless Crypto.decrypt(
                      key: @symmetric_key,
                      input: @received.slice,
                      output: @received_decrypted.slice)
      # then pass to endpoint
      @last_message = Time.now
      point.process_receive(@received_decrypted.slice)
      send_response point.process_sending, is_login: false
    end

    private def process_login_packet
      # here is encrypted packet with client public key as additional data
      return if @received.size <= Crypto::PublicKey.size + Crypto::OVERHEAD_SYMMETRIC
      @received_decrypted.size = @received.size - Crypto::OVERHEAD_SYMMETRIC - Crypto::PublicKey.size
      akey = Crypto::PublicKey.from_bytes @received.slice[0, Crypto::PublicKey.size]
      @symmetric_key = @server.gen_key(akey)
      return unless Crypto.decrypt(
                      key: @symmetric_key,
                      input: @received.slice[Crypto::PublicKey.size, @received.size - Crypto::PublicKey.size],
                      # additional: @received.slice[0, Crypto::PublicKey.size],
                      output: @received_decrypted.slice)
      tuple = @endpoint_factory.new_endpoint(@received_decrypted.slice)
      return unless tuple
      @endpoint = tuple[:endpoint]
      # now init rpc connection
      tuple[:endpoint].rpc_connection = CannonInterface.new tuple[:endpoint], @server.rpc_manager
      # and send response
      send_response tuple[:response], is_login: true
    end

    private def send_response(data, *, is_login : Bool)
      # then encrypt
      @tosend.size = data.size + Crypto::OVERHEAD_SYMMETRIC + 4
      @header.value = is_login ? RIGHT_LOGIN_SIGN : RIGHT_SIGN
      Crypto.encrypt(key: @symmetric_key, input: data, output: @tosend.slice[4, @tosend.size - 4])
      # then send back
      begin
        @socket.send(@tosend.slice, @address)
      rescue ex : Errno
        if ex.errno == Errno::ECONNREFUSED
          # well, message didn't pass
          p ex.inspect
        end
      end
    end

    def execute
      loop do
        cmd = @control.receive
        case cmd
        when ConnectionCommand::LoginReceived
          process_login_packet
        when ConnectionCommand::PacketReceived
          process_data_packet
        when ConnectionCommand::Close
          if point = @endpoint
            point.on_disconnect
          end
          return
        end
      end
    end
  end
end
