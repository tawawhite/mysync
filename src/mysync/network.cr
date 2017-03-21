require "socket"
require "monocypher"
require "./endpoint"

# TODO: alias PoorManEvent = Channel(Nil)
# TODO: utilize inplace encrypt\decrypt

module MySync
  alias Address = Socket::IPAddress
  alias AddressHash = LibC::Sockaddr
  RIGHT_SIGN       = 0xC4AC7BEu32
  RIGHT_LOGIN_SIGN = 0xC4AC7BFu32

  MAX_RAW_SIZE = MAX_PACKAGE_SIZE + 4 + Crypto::OVERHEAD_SYMMETRIC
  MIN_RAW_SIZE = 4 + Crypto::OVERHEAD_SYMMETRIC

  def self.addr_hash(addr : Address) : AddressHash
    addr.to_unsafe.value
  end
end
