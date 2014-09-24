# High-performance rate limiter

`limiter` is a library for an Erlang application to control the rate
of requests to a resource with limited capacity, such as a
database. The library learns the real capacity the resource is able to
service and will ensure you do not exceed this. If more requests
arrive than the resource can handle, limiter will ensure they block
(with a configurable timeout) until they can be serviced.

`limiter` is a great fit for high-volume applications where you desire
sustained throughput close to the real capacity. If you desire
low-latency, you may configure a short timeout which ensures the
request always succeeds or fails in time to meet your latency
requirement. You should not mix low and high latency requests in the
same instance.

## Usage

You need to provide a module that implements the `limiter_handler`
behaviour. The only required function is `do(Request)` which should
execute the request and must return `{ok, Response}` or `{error,
Reason}`. You can indicate overload with the error reason `overload`.

## Architecture

## Performance

## Related work

