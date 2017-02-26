module MySync
  abstract class AbstractEndPoint
    getter requested_disconnect : Bool

    def initialize
      @requested_disconnect = false
    end

    abstract def process_receive(data : Bytes) : Nil
    abstract def process_sending : Bytes

    def on_disconnect
    end
  end

  module EndPointFactory
    abstract def new_endpoint(authdata : Bytes) : {endpoint: AbstractEndPoint, response: Bytes}?
  end
end