/*
  Authored by Alex Hultman, 2018-2019.
  Intellectual property of third-party.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

	  http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
 */

/* 512kb shared receive buffer */

enum LIBUS_RECV_BUFFER_LENGTH = 524_288;
/* A timeout granularity of 4 seconds means give or take 4 seconds from set timeout */

enum LIBUS_TIMEOUT_GRANULARITY = 4;
/* 32 byte padding of receive buffer ends */

enum LIBUS_RECV_BUFFER_PADDING = 32;
/* Guaranteed alignment of extension memory */

enum LIBUS_EXT_ALIGNMENT = 16;

/* Define what a socket descriptor is based on platform */

version(Windows)
{
	import core.sys.windows.winsock2;

	alias LIBUS_SOCKET_DESCRIPTOR = SOCKET;
}
else
{
	alias LIBUS_SOCKET_DESCRIPTOR = int;
}

extern (C):
@nogc nothrow:

enum
{
	LIBUS_LISTEN_DEFAULT,
	LIBUS_LISTEN_EXCLUSIVE_PORT,
}
/* Library types publicly available */

struct us_socket_t;
struct us_timer_t;
struct us_socket_context_t;
struct us_loop_t;
struct us_poll_t;
struct us_udp_socket_t;
struct us_udp_packet_buffer_t;
/* Extra for io_uring */

char* us_socket_send_buffer(
	int ssl,
	us_socket_t* s
);
/* Public interface for UDP sockets */

/* Peeks data and length of UDP payload */

char* us_udp_packet_buffer_payload(
	us_udp_packet_buffer_t* buf,
	int index
);
int us_udp_packet_buffer_payload_length(
	us_udp_packet_buffer_t* buf,
	int index
);
/* Copies out local (received destination) ip (4 or 16 bytes) of received packet */

int us_udp_packet_buffer_local_ip(
	us_udp_packet_buffer_t* buf,
	int index,
	char* ip
);
/* Get the bound port in host byte order */

int us_udp_socket_bound_port(us_udp_socket_t* s
);
/* Peeks peer addr (sockaddr) of received packet */

char* us_udp_packet_buffer_peer(
	us_udp_packet_buffer_t* buf,
	int index
);
/* Peeks ECN of received packet */

int us_udp_packet_buffer_ecn(
	us_udp_packet_buffer_t* buf,
	int index
);
/* Receives a set of packets into specified packet buffer */

int us_udp_socket_receive(
	us_udp_socket_t* s,
	us_udp_packet_buffer_t* buf
);
void us_udp_buffer_set_packet_payload(
	us_udp_packet_buffer_t* send_buf,
	int index,
	int offset,
	void* payload,
	int length,
	void* peer_addr
);
int us_udp_socket_send(
	us_udp_socket_t* s,
	us_udp_packet_buffer_t* buf,
	int num
);
/* Allocates a packet buffer that is reuable per thread. Mutated by us_udp_socket_receive. */

us_udp_packet_buffer_t* us_create_udp_packet_buffer();
/* Creates a (heavy-weight) UDP socket with a user space ring buffer. Again, this one is heavy weight and
  shoud be reused. One entire QUIC server can be implemented using only one single UDP socket so weight
  is not a concern as is the case for TCP sockets which are 1-to-1 with TCP connections. */

//struct us_udp_socket_t *us_create_udp_socket(struct us_loop_t *loop, void (*read_cb)(struct us_udp_socket_t *), unsigned short port);

//struct us_udp_socket_t *us_create_udp_socket(struct us_loop_t *loop, void (*data_cb)(struct us_udp_socket_t *, struct us_udp_packet_buffer_t *, int), void (*drain_cb)(struct us_udp_socket_t *), char *host, unsigned short port);

us_udp_socket_t* us_create_udp_socket(
	us_loop_t* loop,
	us_udp_packet_buffer_t* buf,
	void function(us_udp_socket_t*, us_udp_packet_buffer_t*, int) data_cb,
	void function(us_udp_socket_t*) drain_cb,
	const(char)* host,
	ushort port,
	void* user
);
/* This one is ugly, should be ext! not user */

void* us_udp_socket_user(us_udp_socket_t* s);
/* Binds the UDP socket to an interface and port */

int us_udp_socket_bind(
	us_udp_socket_t* s,
	const(char)* hostname,
	uint port
);
/* Public interfaces for timers */

/* Create a new high precision, low performance timer. May fail and return null */

us_timer_t* us_create_timer(
	us_loop_t* loop,
	int fallthrough,
	uint ext_size
);
/* Returns user data extension for this timer */

void* us_timer_ext(us_timer_t* timer);
/* */

void us_timer_close(us_timer_t* timer
);
/* Arm a timer with a delay from now and eventually a repeat delay.
  Specify 0 as repeat delay to disable repeating. Specify both 0 to disarm. */

void us_timer_set(
	us_timer_t* timer,
	void function(us_timer_t*) cb,
	int ms,
	int repeat_ms
);
/* Returns the loop for this timer */

us_loop_t* us_timer_loop(us_timer_t* t);
/* Public interfaces for contexts */

struct us_socket_context_options_t
{
	const(char)* key_file_name;
	const(char)* cert_file_name;
	const(char)* passphrase;
	const(char)* dh_params_file_name;
	const(char)* ca_file_name;
	const(char)* ssl_ciphers;
	int ssl_prefer_low_memory_usage;
}
/* Return 15-bit timestamp for this context */

ushort us_socket_context_timestamp(
	int ssl,
	us_socket_context_t* context
);
/* Adds SNI domain and cert in asn1 format */

void us_socket_context_add_server_name(
	int ssl,
	us_socket_context_t* context,
	const(char)* hostname_pattern,
	us_socket_context_options_t options,
	void* user
);
void us_socket_context_remove_server_name(
	int ssl,
	us_socket_context_t* context,
	const(char)* hostname_pattern
);
void us_socket_context_on_server_name(
	int ssl,
	us_socket_context_t* context,
	void function(us_socket_context_t*, const(char)*) cb
);
void* us_socket_server_name_userdata(
	int ssl,
	us_socket_t* s
);
void* us_socket_context_find_server_name_userdata(
	int ssl,
	us_socket_context_t* context,
	const(char)* hostname_pattern
);
/* Returns the underlying SSL native handle, such as SSL_CTX or nullptr */

void* us_socket_context_get_native_handle(
	int ssl,
	us_socket_context_t* context
);
/* A socket context holds shared callbacks and user data extension for associated sockets */

us_socket_context_t* us_create_socket_context(
	int ssl,
	us_loop_t* loop,
	int ext_size,
	us_socket_context_options_t options
);
/* Delete resources allocated at creation time. */

void us_socket_context_free(
	int ssl,
	us_socket_context_t* context
);
/* Setters of various async callbacks */

void us_socket_context_on_pre_open(
	int ssl,
	us_socket_context_t* context,
	int function(int*) SOCKET
);
void us_socket_context_on_open(
	int ssl,
	us_socket_context_t* context,
	us_socket_t* function(us_socket_t*, int, char*, int) on_open
);
void us_socket_context_on_close(
	int ssl,
	us_socket_context_t* context,
	us_socket_t* function(us_socket_t*, int, void*) on_close
);
void us_socket_context_on_data(
	int ssl,
	us_socket_context_t* context,
	us_socket_t* function(us_socket_t*, char*, int) on_data
);
void us_socket_context_on_writable(
	int ssl,
	us_socket_context_t* context,
	us_socket_t* function(us_socket_t*) on_writable
);
void us_socket_context_on_timeout(
	int ssl,
	us_socket_context_t* context,
	us_socket_t* function(us_socket_t*) on_timeout
);
void us_socket_context_on_long_timeout(
	int ssl,
	us_socket_context_t* context,
	us_socket_t* function(us_socket_t*) on_timeout
);
/* This one is only used for when a connecting socket fails in a late stage. */

void us_socket_context_on_connect_error(
	int ssl,
	us_socket_context_t* context,
	us_socket_t* function(us_socket_t*, int) on_connect_error
);
/* Emitted when a socket has been half-closed */

void us_socket_context_on_end(
	int ssl,
	us_socket_context_t* context,
	us_socket_t* function(us_socket_t*) on_end
);
/* Returns user data extension for this socket context */

void* us_socket_context_ext(
	int ssl,
	us_socket_context_t* context
);
/* Closes all open sockets, including listen sockets. Does not invalidate the socket context. */

void us_socket_context_close(
	int ssl,
	us_socket_context_t* context
);
/* Listen for connections. Acts as the main driving cog in a server. Will call set async callbacks. */

struct us_listen_socket_t;
us_listen_socket_t* us_socket_context_listen(
	int ssl,
	us_socket_context_t* context,
	const(char)* host,
	int port,
	int options,
	int socket_ext_size
);
us_listen_socket_t* us_socket_context_listen_unix(
	int ssl,
	us_socket_context_t* context,
	const(char)* path,
	int options,
	int socket_ext_size
);
/* listen_socket.c/.h */

void us_listen_socket_close(
	int ssl,
	us_listen_socket_t* ls
);
/* Adopt a socket which was accepted either internally, or from another accept() outside libusockets */

us_socket_t* us_adopt_accepted_socket(
	int ssl,
	us_socket_context_t* context,
	int client_fd,
	uint socket_ext_size,
	char* addr_ip,
	int addr_ip_length
);
/* Land in on_open or on_connection_error or return null or return socket */

us_socket_t* us_socket_context_connect(
	int ssl,
	us_socket_context_t* context,
	const(char)* host,
	int port,
	const(char)* source_host,
	int options,
	int socket_ext_size
);
us_socket_t* us_socket_context_connect_unix(
	int ssl,
	us_socket_context_t* context,
	const(char)* server_path,
	int options,
	int socket_ext_size
);
/* Is this socket established? Can be used to check if a connecting socket has fired the on_open event yet.
  Can also be used to determine if a socket is a listen_socket or not, but you probably know that already. */

int us_socket_is_established(
	int ssl,
	const us_socket_t* s
);
/* Cancel a connecting socket. Can be used together with us_socket_timeout to limit connection times.
  Entirely destroys the socket - this function works like us_socket_close but does not trigger on_close event since
  you never got the on_open event first. */

us_socket_t* us_socket_close_connecting(
	int ssl,
	us_socket_t* s
);
/* Returns the loop for this socket context. */

us_loop_t* us_socket_context_loop(
	int ssl,
	const us_socket_context_t* context
);
/* Invalidates passed socket, returning a new resized socket which belongs to a different socket context.
  Used mainly for "socket upgrades" such as when transitioning from HTTP to WebSocket. */

us_socket_t* us_socket_context_adopt_socket(
	int ssl,
	us_socket_context_t* context,
	us_socket_t* s,
	int ext_size
);
/* Create a child socket context which acts much like its own socket context with its own callbacks yet still relies on the
  parent socket context for some shared resources. Child socket contexts should be used together with socket adoptions and nothing else. */

us_socket_context_t* us_create_child_socket_context(
	int ssl,
	us_socket_context_t* context,
	int context_ext_size
);
/* Public interfaces for loops */

/* Returns a new event loop with user data extension */

us_loop_t* us_create_loop(
	void* hint,
	void function(us_loop_t*) wakeup_cb,
	void function(us_loop_t*) pre_cb,
	void function(us_loop_t*) post_cb,
	uint ext_size
);
/* Frees the loop immediately */

void us_loop_free(us_loop_t* loop);
/* Returns the loop user data extension */

void* us_loop_ext(us_loop_t* loop);
/* Blocks the calling thread and drives the event loop until no more non-fallthrough polls are scheduled */

void us_loop_run(us_loop_t* loop);
/* Signals the loop from any thread to wake up and execute its wakeup handler from the loop's own running thread.
  This is the only fully thread-safe function and serves as the basis for thread safety */

void us_wakeup_loop(us_loop_t* loop);
/* Hook up timers in existing loop */

void us_loop_integrate(us_loop_t* loop);
/* Returns the loop iteration number */

long us_loop_iteration_number(const us_loop_t* loop);
/* Public interfaces for polls */

/* A fallthrough poll does not keep the loop running, it falls through */

us_poll_t* us_create_poll(
	us_loop_t* loop,
	int fallthrough,
	uint ext_size
);
/* After stopping a poll you must manually free the memory */

void us_poll_free(
	us_poll_t* p,
	us_loop_t* loop
);
/* Associate this poll with a socket descriptor and poll type */

void us_poll_init(
	us_poll_t* p,
	int fd,
	int poll_type
);
/* Start, change and stop polling for events */

void us_poll_start(
	us_poll_t* p,
	us_loop_t* loop,
	int events
);
void us_poll_change(
	us_poll_t* p,
	us_loop_t* loop,
	int events
);
void us_poll_stop(
	us_poll_t* p,
	us_loop_t* loop
);
/* Return what events we are polling for */

int us_poll_events(us_poll_t* p
);
/* Returns the user data extension of this poll */

void* us_poll_ext(us_poll_t* p);
int us_poll_fd(us_poll_t* p);
/* Resize an active poll */

us_poll_t* us_poll_resize(
	us_poll_t* p,
	us_loop_t* loop,
	uint ext_size
);
/* Public interfaces for sockets */

/* Returns the underlying native handle for a socket, such as SSL or file descriptor.
  In the case of file descriptor, the value of pointer is fd. */

void* us_socket_get_native_handle(
	int ssl,
	us_socket_t* s
);
/* Write up to length bytes of data. Returns actual bytes written.
  Will call the on_writable callback of active socket context on failure to write everything off in one go.
  Set hint msg_more if you have more immediate data to write. */

int us_socket_write(
	int ssl,
	us_socket_t* s,
	const(char)* data,
	int length,
	int msg_more
);
/* Special path for non-SSL sockets. Used to send header and payload in one go. Works like us_socket_write. */

int us_socket_write2(
	int ssl,
	us_socket_t* s,
	const(char)* header,
	int header_length,
	const(char)* payload,
	int payload_length
);
/* Set a low precision, high performance timer on a socket. A socket can only have one single active timer
  at any given point in time. Will remove any such pre set timer */

void us_socket_timeout(
	int ssl,
	us_socket_t* s,
	uint seconds
);
/* Set a low precision, high performance timer on a socket. Suitable for per-minute precision. */

void us_socket_long_timeout(
	int ssl,
	us_socket_t* s,
	uint minutes
);
/* Return the user data extension of this socket */

void* us_socket_ext(
	int ssl,
	us_socket_t* s
);
/* Return the socket context of this socket */

us_socket_context_t* us_socket_context(
	int ssl,
	const us_socket_t* s
);
/* Withdraw any msg_more status and flush any pending data */

void us_socket_flush(
	int ssl,
	us_socket_t* s
);
/* Shuts down the connection by sending FIN and/or close_notify */

void us_socket_shutdown(
	int ssl,
	us_socket_t* s
);
/* Shuts down the connection in terms of read, meaning next event loop
  iteration will catch the socket being closed. Can be used to defer closing
  to next event loop iteration. */

void us_socket_shutdown_read(
	int ssl,
	us_socket_t* s
);
/* Returns whether the socket has been shut down or not */

int us_socket_is_shut_down(
	int ssl,
	const us_socket_t* s
);
/* Returns whether this socket has been closed. Only valid if memory has not yet been released. */

int us_socket_is_closed(
	int ssl,
	const us_socket_t* s
);
/* Immediately closes the socket */

us_socket_t* us_socket_close(
	int ssl,
	us_socket_t* s,
	int code,
	void* reason
);
/* Returns local port or -1 on failure. */

int us_socket_local_port(
	int ssl,
	us_socket_t* s
);
/* Returns remote ephemeral port or -1 on failure. */

int us_socket_remote_port(
	int ssl,
	us_socket_t* s
);
/* Copy remote (IP) address of socket, or fail with zero length. */

void us_socket_remote_address(
	int ssl,
	us_socket_t* s,
	char* buf,
	int* length
);

/* Decide what eventing system to use by default */
version = LIBUS_USE_LIBUV;
