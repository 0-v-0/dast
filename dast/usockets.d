module dast.usockets;

import libusockets;
import std.typecons;

pragma(LDC_no_moduleinfo);
pragma(LDC_no_typeinfo):

private alias CB = extern (C) void function(us_loop_t* loop);

alias integrate = us_loop_integrate;

@nogc struct EventLoop(T = void[0]) {
	alias LoopCallback = extern (C) void function(typeof(this) loop);

	private us_loop_t* loop;
	// 需要保证EventLoop和us_loop_t*的大小一致
	enum uint extSize = T.sizeof;

	@property handle() => loop;
	alias handle this;

	@disable this();

	this(us_loop_t* handle) {
		loop = handle;
	}

	this(typeof(null)) {
		this(LoopCallback.init);
	}

	this(LoopCallback onWakeUp,
		LoopCallback onPre = null,
		LoopCallback onPost = null) {
		if (!onWakeUp)
			onWakeUp = &noop;
		if (!onPre)
			onPre = &noop;
		if (!onPost)
			onPost = &noop;
		loop = us_create_loop(null, cast(CB)onWakeUp, cast(CB)onPre, cast(CB)onPost, extSize);
	}

	void run() => us_loop_run(loop);

	void wakeup() => us_wakeup_loop(loop);

	@property ref data() @trusted => *cast(T*)us_loop_ext(loop);
	@property long iteration() const => us_loop_iteration_number(loop);

	void free() => us_loop_free(loop);

	auto timer(int fallthrough = 0, int extSize = 0)
		=> us_create_timer(loop, fallthrough, extSize);

	extern (C) static void noop(typeof(this)) {
	}
}

template eventLoop(T = void[0]) {
	alias LoopCallback = extern (C) void function(EventLoop!T loop);

	auto eventLoop(LoopCallback onWakeUp = null,
		LoopCallback onPre = null,
		LoopCallback onPost = null) => EventLoop!T(onWakeUp, onPre, onPost);
}

struct SSLOptions {
	string key;
	string cert;
	string passphrase;
	string dhParams;
	string caFile;
	string sslCiphers;
	bool preferLowMemoryUsage;
}

// 将函数参数第一个类型替换为第二个类型参数，返回这个类型
private template ReplaceFirstParam(F, T) {
	import std.traits;

	static if (isFunctionPointer!F) {
		alias ReplaceFirstParam = SetFunctionAttributes!(
			T function(T, Parameters!F[1 .. $]), functionLinkage!F, functionAttributes!F);
	} else static if (isDelegate!F) {
		alias ReplaceFirstParam = SetFunctionAttributes!(
			T delegate(T, Parameters!F[1 .. $]), functionLinkage!F, functionAttributes!F);
	} else
		static assert(0, "Unsupported type");
}

private alias R(T) = ReplaceFirstParam!(T, us_socket_t*);

/++
Socket context
Params:
	T: User data type
	S: Socket data type
	SSL: Whether to use SSL
 +/
@nogc struct Context(CT = void[0], ST = void[0], bool SSL = false) {
	private alias S = Socket,
	OnSocketOpen = extern (C) S function(S socket, int isClient, char* ip, int ipLength),
	OnSocketClose = extern (C) S function(S socket, int code, void* reason),
	OnSocketData = extern (C) S function(S socket, char* data, int length),
	OnSocketEnd = extern (C) S function(S socket),
	OnSocketWritable = OnSocketEnd,
	OnSocketTimeout = OnSocketEnd;
	private us_socket_context_t* context;
	enum int extSize = CT.sizeof;
	enum ssl = SSL;

	@property handle() => context;
	alias handle this;

	@property ref data() @trusted => *cast(CT*)us_socket_context_ext(ssl, context);

	@property loop() const
		=> EventLoop!()(us_socket_context_loop(0, context));

	this(us_socket_context_t* handle) {
		context = handle;
	}

	this(us_loop_t* loop, SSLOptions sslOptions = SSLOptions()) {
		us_socket_context_options_t options = {
			sslOptions.key.ptr,
			sslOptions.cert.ptr,
			sslOptions.passphrase.ptr,
			sslOptions.dhParams.ptr,
			sslOptions.caFile.ptr,
			sslOptions.sslCiphers.ptr,
			sslOptions.preferLowMemoryUsage,
		};
		context = us_create_socket_context(ssl, loop, extSize, options);
	}

	void free() => us_socket_context_free(ssl, context);

	void onOpen(OnSocketOpen onOpen)
		=> us_socket_context_on_open(ssl, context, cast(R!OnSocketOpen)onOpen);

	void onData(OnSocketData onData)
		=> us_socket_context_on_data(ssl, context, cast(R!OnSocketData)onData);

	void onWritable(OnSocketWritable onWritable)
		=> us_socket_context_on_writable(ssl, context, cast(R!OnSocketWritable)onWritable);

	void onTimeout(OnSocketTimeout onTimeout)
		=> us_socket_context_on_timeout(ssl, context, cast(R!OnSocketTimeout)onTimeout);

	void onClose(OnSocketClose onClose)
		=> us_socket_context_on_close(ssl, context, cast(R!OnSocketClose)onClose);

	void onEnd(OnSocketEnd onEnd)
		=> us_socket_context_on_end(ssl, context, cast(R!OnSocketEnd)onEnd);

	auto listen(string host, ushort port)
		=> Listener(
			us_socket_context_listen(ssl, context, host.ptr, port, 0, ST.sizeof), ssl);

	struct Socket {
		private us_socket_t* socket;

		@property handle() => socket;
		alias handle this;

		@property ref data() => *cast(ST*)us_socket_ext(ssl, socket);

		@property bool isShutdown() const
			=> us_socket_is_shut_down(ssl, socket) != 0;

		@property bool isEstablished() const
			=> us_socket_is_established(ssl, socket) != 0;

		@property context() const
			=> Context(us_socket_context(ssl, socket));

		@property timeout(uint secs) => us_socket_timeout(ssl, socket, secs);

		@disable this();

		this(us_socket_t* handle) {
			socket = handle;
		}

		auto close(int code = 0, void* reason = null)
			=> Socket(us_socket_close(ssl, socket, code, reason));

		void shutdown() => us_socket_shutdown(ssl, socket);

		void shutdownRead() => us_socket_shutdown_read(ssl, socket);

		void flush() => us_socket_flush(0, socket);

		int write(const(void)[] data, bool more = false)
			=> us_socket_write(ssl, socket, cast(const char*)data.ptr, cast(int)data.length, more);
	}
}

struct Listener {
	private us_listen_socket_t* socket;
	bool ssl;

	@disable this();

	@property handle() => socket;
	alias handle this;

	this(us_listen_socket_t* handle, bool ssl) {
		socket = handle;
		this.ssl = ssl;
	}

	T opCast(T : bool)() const => socket !is null;

	void close() => us_listen_socket_close(ssl, socket);
}
