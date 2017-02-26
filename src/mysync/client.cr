require "./endpoint_interface"
require "monocypher"
require "socket"
require "./network"
require "./package"

module MySync
  class UDPGameClient
    getter socket

    def initialize(@endpoint : AbstractEndPoint, @address : Address)
      @socket = UDPSocket.new
      @socket.read_timeout = Time::Span.new(0, 0, 1)
      @socket.connect @address
      @raw_received = Bytes.new(MAX_PACKAGE_SIZE)
      @received_decrypted = Package.new(MAX_PACKAGE_SIZE)
      @tosend = Package.new(MAX_PACKAGE_SIZE)
      @tosend_header = @tosend.to_unsafe.as(UInt32*)
      @nonce = Crypto::Nonce.new
      @symmetric_key = Crypto::SymmetricKey.new
      @received_header = @raw_received.to_unsafe.as(UInt32*)
    end

    # TODO - send packages asynchronously?
    private def package_received(package : Bytes)
      # first it decrypts and check
      return if package.size <= Crypto::OVERHEAD_SYMMETRIC
      @received_decrypted.size = package.size - Crypto::OVERHEAD_SYMMETRIC
      return unless Crypto.symmetric_decrypt(key: @symmetric_key, input: package, output: @received_decrypted.slice)
      # then pass to endpoint
      @endpoint.process_receive(@received_decrypted.slice)
    end

    private def try_receive
      @socket.receive(@raw_received)
    rescue
      {0, nil}
    end

    private def reading_fiber
      loop do
        size, ip = try_receive
        next if size < 4
        next if size > MAX_PACKAGE_SIZE
        next if @received_header.value != RIGHT_SIGN
        package_received @raw_received[4, size - 4]
      end
    end

    def login(public_key : Crypto::PublicKey, authdata : Bytes) : Bytes?
      # we encrypt symmetric_key and auth data with server's public key
      plaintext = Bytes.new(Crypto::SymmetricKey.size + authdata.size)
      plaintext[0, Crypto::SymmetricKey.size].copy_from @symmetric_key.to_slice
      plaintext[Crypto::SymmetricKey.size, authdata.size].copy_from authdata
      @tosend.size = plaintext.size + Crypto::OVERHEAD_ANONYMOUS + 4
      Crypto.asymmetric_encrypt(their_public: public_key, input: plaintext, output: @tosend.slice[4, @tosend.size - 4])
      # send it to server
      @tosend_header.value = RIGHT_SIGN
      begin
        @socket.send(@tosend.slice, @address)
      rescue ex : Errno
        return nil
      end
      # wait for response
      size, ip = @socket.receive(@raw_received)
      return nil if size < 4
      return nil if size > MAX_PACKAGE_SIZE
      return nil if @received_header.value != RIGHT_SIGN
      package = @raw_received[4, size - 4]
      # decrypt it with symmetric_key
      return nil if package.size < Crypto::OVERHEAD_SYMMETRIC
      @received_decrypted.size = package.size - Crypto::OVERHEAD_SYMMETRIC
      return nil unless Crypto.symmetric_decrypt(key: @symmetric_key, input: package, output: @received_decrypted.slice)
      # all is fine, copy data to output and start listening
      data = Bytes.new(@received_decrypted.size)
      data.copy_from @received_decrypted.slice
      spawn { reading_fiber }
      return data
    end

    def send_data
      data = @endpoint.process_sending
      # then encrypt
      @nonce.reroll
      @tosend.size = data.size + Crypto::OVERHEAD_SYMMETRIC + 4
      Crypto.symmetric_encrypt(key: @symmetric_key, nonce: @nonce, input: data, output: @tosend.slice[4, @tosend.size - 4])
      # then send back
      @tosend_header.value = RIGHT_SIGN
      begin
        @socket.send(@tosend.slice, @address)
      rescue ex : Errno
        if ex.errno == Errno::ECONNREFUSED
          # well, message didn't pass
          p ex.inspect
        end
      end
    end
  end
end