module dast.async.net.socket;

// NOTE: When working on this module, be sure to run tests with -debug=std_socket
// E.g.: dmd -version=StdUnittest -debug=std_socket -unittest -main -run socket
// This will enable some tests which are too slow or flaky to run as part of CI.

/**
 * Socket primitives.
 */

import core.stdc.stdlib;
import core.stdc.string;
import core.time : dur, Duration;
import std.string : fromStringz;
import std.conv : to;

public import dast.async.net.address;
import dast.async.net.error;

version (iOS)
	version = iOSDerived;
else version (TVOS)
	version = iOSDerived;
else version (WatchOS)
	version = iOSDerived;

	@safe:

version (Windows) {
	pragma(lib, "ws2_32.lib");
	pragma(lib, "wsock32.lib");

	import core.sys.windows.winbase;
	import core.sys.windows.winsock2;

	enum socket_t : SOCKET {
		_init
	}

	// Windows uses int instead of size_t for length arguments.
	// Luckily, the send/recv functions make no guarantee that
	// all the data is sent, so we use that to send at most
	// int.max bytes.
	private int capToInt(size_t size) nothrow @nogc pure
		=> size > size_t(int.max) ? int.max : cast(int)size;
} else version (Posix) {
	version (linux) {
		enum {
			TCP_KEEPIDLE = cast(SocketOption)4,
			TCP_KEEPINTVL = cast(SocketOption)5
		}
	}

	import core.sys.posix.fcntl;
	import core.sys.posix.netinet.tcp;
	import core.sys.posix.sys.socket;
	import core.sys.posix.sys.time;
	import core.sys.posix.unistd;

	enum socket_t : int {
		_init = -1
	}

private:
	enum SOCKET_ERROR = -1;

	enum : int {
		SD_RECEIVE = SHUT_RD,
		SD_SEND = SHUT_WR,
		SD_BOTH = SHUT_RDWR
	}

	size_t capToInt(size_t size) nothrow @nogc pure => size;
} else
	static assert(0, "No socket support for this platform yet.");

version (Windows) {
	shared static this() @system {
		WSADATA wd;

		// Winsock will still load if an older version is present.
		// The version is just a request.
		if (const val = WSAStartup(0x2020, &wd)) // Request Winsock 2.2 for IPv6.
			throw new SocketOSException("Unable to initialize socket library", val);
	}

	shared static ~this() @system nothrow @nogc {
		WSACleanup();
	}
}

/// How a socket is shutdown:
enum SocketShutdown {
	RECEIVE = SD_RECEIVE, /// socket receives are disallowed
	SEND = SD_SEND, /// socket sends are disallowed
	BOTH = SD_BOTH, /// both RECEIVE and SEND
}

// dfmt off

/// Socket flags that may be OR'ed together:
enum SocketFlags: int {
	NONE =		0,				/// no flags specified

	OOB =		MSG_OOB,		/// out-of-band stream data
	PEEK =		MSG_PEEK,		/// peek at incoming data without removing it from the queue, only for receiving
	DONTROUTE =	MSG_DONTROUTE,	/// data should not be subject to routing; this flag may be ignored. Only for sending
}


/// The level at which a socket option is defined:
enum SocketOptionLevel: int {
	SOCKET =	SOL_SOCKET,			/// Socket level
	IP =		ProtocolType.IP,	/// Internet Protocol version 4 level
	ICMP =		ProtocolType.ICMP,	/// Internet Control Message Protocol level
	IGMP =		ProtocolType.IGMP,	/// Internet Group Management Protocol level
	GGP =		ProtocolType.GGP,	/// Gateway to Gateway Protocol level
	TCP =		ProtocolType.TCP,	/// Transmission Control Protocol level
	PUP =		ProtocolType.PUP,	/// PARC Universal Packet Protocol level
	UDP =		ProtocolType.UDP,	/// User Datagram Protocol level
	IDP =		ProtocolType.IDP,	/// Xerox NS protocol level
	RAW =		ProtocolType.RAW,	/// Raw IP packet level
	IPV6 =		ProtocolType.IPV6,	/// Internet Protocol version 6 level
}

/// _Linger information for use with SocketOption.LINGER.
struct Linger {
	linger clinger;

	private alias l_onoff_t = typeof(linger.l_onoff);
	private alias l_linger_t = typeof(linger.l_linger);

pure nothrow @nogc @property:
	/// Nonzero for _on.
	ref inout(l_onoff_t) on() inout return => clinger.l_onoff;

	/// Linger _time.
	ref inout(l_linger_t) time() inout return => clinger.l_linger;
}

/// Specifies a socket option:
enum SocketOption: int
{
	DEBUG =			SO_DEBUG,		/// Record debugging information
	BROADCAST =		SO_BROADCAST,	/// Allow transmission of broadcast messages
	REUSEADDR =		SO_REUSEADDR,	/// Allow local reuse of address
	LINGER =		SO_LINGER,		/// Linger on close if unsent data is present
	OOBINLINE =		SO_OOBINLINE,	/// Receive out-of-band data in band
	SNDBUF =		SO_SNDBUF,		/// Send buffer size
	RCVBUF =		SO_RCVBUF,		/// Receive buffer size
	DONTROUTE =		SO_DONTROUTE,	/// Do not route
	SNDTIMEO =		SO_SNDTIMEO,	/// Send timeout
	RCVTIMEO =		SO_RCVTIMEO,	/// Receive timeout
	ERROR =			SO_ERROR,		/// Retrieve and clear error status
	KEEPALIVE =		SO_KEEPALIVE,	/// Enable keep-alive packets
	ACCEPTCONN =	SO_ACCEPTCONN,	/// Listen
	RCVLOWAT =		SO_RCVLOWAT,	/// Minimum number of input bytes to process
	SNDLOWAT =		SO_SNDLOWAT,	/// Minimum number of output bytes to process
	TYPE =			SO_TYPE,		/// Socket type

	// SocketOptionLevel.TCP:
	TCP_NODELAY =		.TCP_NODELAY,	/// Disable the Nagle algorithm for send coalescing

	// SocketOptionLevel.IPV6:
	IPV6_UNICAST_HOPS =		.IPV6_UNICAST_HOPS,		/// IP unicast hop limit
	IPV6_MULTICAST_IF =		.IPV6_MULTICAST_IF,		/// IP multicast interface
	IPV6_MULTICAST_LOOP =	.IPV6_MULTICAST_LOOP,	/// IP multicast loopback
	IPV6_MULTICAST_HOPS =	.IPV6_MULTICAST_HOPS,	/// IP multicast hops
	IPV6_JOIN_GROUP =		.IPV6_JOIN_GROUP,		/// Add an IP group membership
	IPV6_LEAVE_GROUP =		.IPV6_LEAVE_GROUP,		/// Drop an IP group membership
	IPV6_V6ONLY =			.IPV6_V6ONLY,			/// Treat wildcard bind as AF_INET6-only
}

// dfmt on

version (X86_64) {
	version (LittleEndian) {
		version = CompactPtr;
		enum PtrMask = 0xFF_FF_FF_FF_FF_FF;
	}
}

/**
 * A network communication endpoint using the Berkeley sockets interface.
 */
struct Socket {
private:
	socket_t sock;
	version (CompactPtr) {
		union {
			struct {
				byte[6] pad;
				AddressFamily _family;
			}

			size_t p;
		}

		@property pure nothrow @nogc @system {
			void* ptr()
				=> cast(void*)(p & PtrMask);

			void ptr(void* val) {
				p &= ~PtrMask;
				p |= PtrMask & cast(size_t)val;
			}
		}
	} else {
		void* ptr;
		AddressFamily _family;
	}

	enum BIOFlag = cast(AddressFamily)0x8000;
	version (Windows) {
		alias _close = .closesocket;
	} else version (Posix) {
		alias _close = .close;
	}

	// The WinSock timeouts seem to be effectively skewed by a constant
	// offset of about half a second (value in milliseconds). This has
	// been confirmed on updated (as of Jun 2011) Windows XP, Windows 7
	// and Windows Server 2008 R2 boxes. The unittest below tests this
	// behavior.
	enum WINSOCK_TIMEOUT_SKEW = 500;

	@safe unittest {
		if (runSlowTests)
			softUnittest({
				import std.datetime.stopwatch : StopWatch;
				import std.typecons : Yes;

				enum msecs = 1000;
				auto pair = socketPair();
				auto testSock = pair[0];
				testSock.setOption(SocketOptionLevel.SOCKET,
					SocketOption.RCVTIMEO, dur!"msecs"(msecs));

				auto sw = StopWatch(Yes.autoStart);
				ubyte[1] buf;
				testSock.receive(buf);
				sw.stop();

				Duration readBack = void;
				testSock.getOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, readBack);

				assert(readBack.total!"msecs" == msecs);
				assert(sw.peek().total!"msecs" > msecs - 100 && sw.peek()
					.total!"msecs" < msecs + 100);
			});
	}

	void setSock(socket_t handle)
	in (handle != socket_t.init) {
		sock = handle;

		// Set the option to disable SIGPIPE on send() if the platform
		// has it (e.g. on OS X).
		static if (is(typeof(SO_NOSIGPIPE))) {
			setOption(SocketOptionLevel.SOCKET, cast(SocketOption)SO_NOSIGPIPE, true);
		}
	}

public:
	/**
	 * Returns: The local machine's host name
	 */
	static @property string hostName() @trusted { // getter
		char[256] result = void; // Host names are limited to 255 chars.
		if (ERROR == gethostname(result.ptr, result.length))
			throw new SocketOSException("Unable to obtain host name");
		return cast(string)fromStringz(result.ptr);
	}

	/**
	 * Create a blocking socket. If a single protocol type exists to support
	 * this socket type within the address family, the `ProtocolType` may be
	 * omitted.
	 */
	this(AddressFamily af, SocketType type, ProtocolType protocol = ProtocolType.IP) {
		_family = af;
		const handle = cast(socket_t)socket(af, type, protocol);
		if (handle == socket_t.init)
			throw new SocketOSException("Unable to create socket");
		setSock(handle);
	}

	/**
	 * Create a blocking socket using the parameters from the specified
	 * `AddressInfo` structure.
	 */
	this(in AddressInfo info) {
		this(info.family, info.type, info.protocol);
	}

	nothrow @nogc {
		/// Use an existing socket handle.
		this(socket_t s, AddressFamily af) pure
		in (s != socket_t.init) {
			sock = s;
			_family = af;
		}

		/// Get underlying socket handle.
		@property socket_t handle() const pure => sock;

		/**
		 * Releases the underlying socket handle from the Socket object. Once it
		 * is released, you cannot use the Socket object's methods anymore. This
		 * also means the Socket destructor will no longer close the socket - it
		 * becomes your responsibility.
		 *
		 * To get the handle without releasing it, use the `handle` property.
		 */
		@property socket_t release() pure {
			const h = sock;
			sock = socket_t.init;
			return h;
		}

		/// Get the socket's address family.
		@property AddressFamily addressFamily() const @trusted pure
			=> cast(AddressFamily)(_family & ~BIOFlag);

		/**
	 	 * Get/set socket's blocking flag.
	 	 *
	 	 * When a socket is blocking, calls to receive(), accept(), and send()
	 	 * will block and wait for data/action.
	 	 * A non-blocking socket will immediately return instead of blocking.
	 	 */
		@property bool blocking() @trusted const {
			version (Windows) {
				return (_family & BIOFlag) == 0;
			} else version (Posix) {
				return !(fcntl(handle, F_GETFL, 0) & O_NONBLOCK);
			}
		}
	}
	/// ditto
	@property int blocking(bool byes) @trusted {
		version (Windows) {
			uint num = !byes;
			if (ERROR == ioctlsocket(sock, FIONBIO, &num))
				return errno();
			if (num)
				_family |= BIOFlag;
			else
				_family &= ~BIOFlag;
		} else version (Posix) {
			const x = fcntl(sock, F_GETFL, 0);
			if (-1 == x)
				return errno();
			if (byes)
				x &= ~O_NONBLOCK;
			else
				x |= O_NONBLOCK;
			if (-1 == fcntl(sock, F_SETFL, x))
				return errno();
		}
		return 0;
	}

	/// Property that indicates if this is a valid, alive socket.
	@property bool isAlive() @trusted nothrow const {
		int type = void;
		auto typesize = cast(socklen_t)type.sizeof;
		return !getsockopt(sock, SOL_SOCKET, SO_TYPE, &type, &typesize);
	}

	/**
	 * Accept an incoming connection. If the socket is blocking, `accept`
	 * waits for a connection request. Returns Socket.init if the socket is
	 * unable to _accept. See `accepting` for use with derived classes.
	 */
	Socket accept() @trusted {
		auto newsock = cast(socket_t).accept(sock, null, null);
		if (socket_t.init == newsock)
			return Socket.init;

		//inherits blocking mode
		return Socket(newsock, _family);
	}

	/**
	 * Associate a local address with this socket.
	 *
	 * Params:
	 *     addr = The $(LREF Address) to associate this socket with.
	 *
	 * Throws: $(LREF SocketOSException) when unable to bind the socket.
	 */
	void bind(in Address addr) @trusted
		=> checkError(.bind(sock, addr.name, addr.nameLen),
			"Unable to bind socket");

	/**
	 * Establish a connection. If the socket is blocking, connect waits for
	 * the connection to be made. If the socket is nonblocking, connect
	 * returns immediately and the connection attempt is still in progress.
	 */
	void connect(in Address to) @trusted {
		if (ERROR == .connect(sock, to.name, to.nameLen)) {
			const err = errno();

			version (Windows) {
				if (WSAEWOULDBLOCK == err)
					return;
			} else version (Posix) {
				if (EINPROGRESS == err)
					return;
			} else
				static assert(0);
			throw new SocketOSException("Unable to connect socket", err);
		}
	}

	/**
	 * Listen for an incoming connection. `bind` must be called before you
	 * can `listen`. The `backlog` is a request of how many pending
	 * incoming connections are queued until `accept`ed.
	 */
	void listen(int backlog) @trusted
		=> checkError(.listen(sock, backlog), "Unable to listen on socket");

	nothrow @nogc {
		/// Disables sends and/or receives.
		int shutdown(SocketShutdown how) @trusted
			=> .shutdown(sock, how);

		/**
		 * Immediately drop any connections and release socket resources.
		 * The `Socket` object is no longer usable after `close`.
		 * Calling `shutdown` before `close` is recommended
		 * for connection-oriented sockets.
		 */
		void close() @trusted {
			free(ptr);
			_close(sock);
			sock = socket_t.init;
		}
	}

	/// Remote endpoint `Address`.
	@property Address remoteAddress() @trusted
	out (addr; addr.addressFamily == addressFamily) {
		Address addr = createAddress();
		socklen_t nameLen = addr.nameLen;
		checkError(.getpeername(sock, addr.name, &nameLen),
			"Unable to obtain remote socket address");
		addr.nameLen = nameLen;
		return addr;
	}

	/// Local endpoint `Address`.
	@property Address localAddress() @trusted
	out (addr; addr.addressFamily == addressFamily) {
		Address addr = createAddress();
		socklen_t nameLen = addr.nameLen;
		checkError(.getsockname(sock, addr.name, &nameLen),
			"Unable to obtain local socket address");
		addr.nameLen = nameLen;
		return addr;
	}

	/**
	 * Send or receive error code. See `wouldHaveBlocked`,
	 * `lastSocketError` and `Socket.getErrorText` for obtaining more
	 * information about the error.
	 */
	enum int ERROR = SOCKET_ERROR;

	/**
	 * Send data on the connection. If the socket is blocking and there is no
	 * buffer space left, `send` waits.
	 * Returns: The number of bytes actually sent, or `Socket.ERROR` on
	 * failure.
	 */
	ptrdiff_t send(scope const(void)[] buf, SocketFlags flags) @trusted nothrow {
		static if (is(typeof(MSG_NOSIGNAL))) {
			flags = cast(SocketFlags)(flags | MSG_NOSIGNAL);
		}
		return .send(sock, buf.ptr, capToInt(buf.length), flags);
	}

	/// ditto
	ptrdiff_t send(scope const(void)[] buf) nothrow
		=> send(buf, SocketFlags.NONE);

	/**
	 * Send data to a specific destination Address. If the destination address is
	 * not specified, a connection must have been made and that address is used.
	 * If the socket is blocking and there is no buffer space left, `sendTo` waits.
	 * Returns: The number of bytes actually sent, or `Socket.ERROR` on
	 * failure.
	 */
	ptrdiff_t sendTo(scope const(void)[] buf, SocketFlags flags, in Address to) @trusted {
		static if (is(typeof(MSG_NOSIGNAL))) {
			flags = cast(SocketFlags)(flags | MSG_NOSIGNAL);
		}
		return .sendto(sock, buf.ptr, capToInt(buf.length), flags, to.name, to.nameLen);
	}

	/// ditto
	ptrdiff_t sendTo(scope const(void)[] buf, in Address to)
		=> sendTo(buf, SocketFlags.NONE, to);

	//assumes you connect()ed
	/// ditto
	ptrdiff_t sendTo(scope const(void)[] buf, SocketFlags flags = SocketFlags.NONE) @trusted {
		static if (is(typeof(MSG_NOSIGNAL))) {
			flags = cast(SocketFlags)(flags | MSG_NOSIGNAL);
		}
		return .sendto(sock, buf.ptr, capToInt(buf.length), flags, null, 0);
	}

	/**
	 * Receive data on the connection. If the socket is blocking, `receive`
	 * waits until there is data to be received.
	 * Returns: The number of bytes actually received, `0` if the remote side
	 * has closed the connection, or `Socket.ERROR` on failure.
	 */
	ptrdiff_t receive(scope void[] buf, SocketFlags flags = SocketFlags.NONE) @trusted {
		return buf.length ? .recv(sock, buf.ptr, capToInt(buf.length), flags) : 0;
	}

	/**
	 * Receive data and get the remote endpoint `Address`.
	 * If the socket is blocking, `receiveFrom` waits until there is data to
	 * be received.
	 * Returns: The number of bytes actually received, `0` if the remote side
	 * has closed the connection, or `Socket.ERROR` on failure.
	 */
	ptrdiff_t receiveFrom(scope void[] buf, SocketFlags flags, ref Address from) @trusted {
		if (!buf.length) //return 0 and don't think the connection closed
			return 0;
		if (from.addressFamily != addressFamily)
			from = createAddress();
		socklen_t nameLen = from.nameLen;
		const read = .recvfrom(sock, buf.ptr, capToInt(buf.length), flags, from.name, &nameLen);

		if (read >= 0) {
			from.nameLen = nameLen;
			assert(from.addressFamily == addressFamily);
		}
		return read;
	}

	/// ditto
	ptrdiff_t receiveFrom(scope void[] buf, ref Address from)
		=> receiveFrom(buf, SocketFlags.NONE, from);

	//assumes you connect()ed
	/// ditto
	ptrdiff_t receiveFrom(scope void[] buf, SocketFlags flags = SocketFlags.NONE) @trusted {
		if (!buf.length) //return 0 and don't think the connection closed
			return 0;
		return .recvfrom(sock, buf.ptr, capToInt(buf.length), flags, null, null);
	}

	/**
	 * Get a socket option.
	 * Returns: The number of bytes written to `result`.
	 * The length, in bytes, of the actual result - very different from getsockopt()
	 */
	int getOption(SocketOptionLevel level, SocketOption option, scope void[] result) @trusted {
		auto len = cast(socklen_t)result.length;
		checkError(.getsockopt(sock, level, option, result.ptr, &len),
			"Unable to get socket option");
		return len;
	}

	/// Common case of getting integer and boolean options.
	int getOption(SocketOptionLevel level, SocketOption option, out int result) @trusted {
		return getOption(level, option, (&result)[0 .. 1]);
	}

	/// Get the linger option.
	int getOption(SocketOptionLevel level, SocketOption option, out Linger result) @trusted {
		//return getOption(cast(SocketOptionLevel) SocketOptionLevel.SOCKET, SocketOption.LINGER, (&result)[0 .. 1]);
		return getOption(level, option, (&result.clinger)[0 .. 1]);
	}

	/// Get a timeout (duration) option.
	void getOption(SocketOptionLevel level, SocketOption option, out Duration result) @trusted {
		enforce(option == SocketOption.SNDTIMEO || option == SocketOption.RCVTIMEO,
			new SocketParameterException("Not a valid timeout option: " ~ to!string(option)));
		// WinSock returns the timeout values as a milliseconds DWORD,
		// while Linux and BSD return a timeval struct.
		version (Windows) {
			int msecs;
			getOption(level, option, (&msecs)[0 .. 1]);
			if (option == SocketOption.RCVTIMEO)
				msecs += WINSOCK_TIMEOUT_SKEW;
			result = dur!"msecs"(msecs);
		} else version (Posix) {
			TimeVal tv;
			getOption(level, option, (&tv.ctimeval)[0 .. 1]);
			result = dur!"seconds"(tv.seconds) + dur!"usecs"(tv.microseconds);
		} else
			static assert(0);
	}

	/// Set a socket option.
	void setOption(SocketOptionLevel level, SocketOption option, scope void[] value) @trusted {
		checkError(.setsockopt(sock, level, option, value.ptr, cast(uint)value.length),
			"Unable to set socket option");
	}

	/// Common case for setting integer and boolean options.
	void setOption(SocketOptionLevel level, SocketOption option, int value) @trusted {
		setOption(level, option, (&value)[0 .. 1]);
	}

	/// Set the linger option.
	void setOption(SocketOptionLevel level, SocketOption option, Linger value) @trusted {
		//setOption(cast(SocketOptionLevel) SocketOptionLevel.SOCKET, SocketOption.LINGER, (&value)[0 .. 1]);
		setOption(level, option, (&value.clinger)[0 .. 1]);
	}

	/**
	 * Sets a timeout (duration) option, i.e. `SocketOption.SNDTIMEO` or
	 * `RCVTIMEO`. Zero indicates no timeout.
	 *
	 * In a typical application, you might also want to consider using
	 * a non-blocking socket instead of setting a timeout on a blocking one.
	 *
	 * Note: While the receive timeout setting is generally quite accurate
	 * on *nix systems even for smaller durations, there are two issues to
	 * be aware of on Windows: First, although undocumented, the effective
	 * timeout duration seems to be the one set on the socket plus half
	 * a second. `setOption()` tries to compensate for that, but still,
	 * timeouts under 500ms are not possible on Windows. Second, be aware
	 * that the actual amount of time spent until a blocking call returns
	 * randomly varies on the order of 10ms.
	 *
	 * Params:
	 *   level  = The level at which a socket option is defined.
	 *   option = Either `SocketOption.SNDTIMEO` or `SocketOption.RCVTIMEO`.
	 *   value  = The timeout duration to set. Must not be negative.
	 *
	 * Throws: `SocketException` if setting the options fails.
	 *
	 * Example:
	 * ---
	 * import std.datetime;
	 * import std.typecons;
	 * auto pair = socketPair();
	 * scope(exit) foreach (s; pair) s.close();
	 *
	 * // Set a receive timeout, and then wait at one end of
	 * // the socket pair, knowing that no data will arrive.
	 * pair[0].setOption(SocketOptionLevel.SOCKET,
	 *     SocketOption.RCVTIMEO, dur!"seconds"(1));
	 *
	 * auto sw = StopWatch(Yes.autoStart);
	 * ubyte[1] buffer;
	 * pair[0].receive(buffer);
	 * writefln("Waited %s ms until the socket timed out.",
	 *     sw.peek.msecs);
	 * ---
	 */
	void setOption(SocketOptionLevel level, SocketOption option, Duration value) @trusted {
		enforce(option == SocketOption.SNDTIMEO || option == SocketOption.RCVTIMEO,
			new SocketParameterException("Not a valid timeout option: " ~ to!string(option)));

		enforce(value >= dur!"hnsecs"(0), new SocketParameterException(
				"Timeout duration must not be negative."));

		version (Windows) {
			import std.algorithm.comparison : max;

			int msecs = cast(int)value.total!"msecs";
			if (msecs != 0 && option == SocketOption.RCVTIMEO)
				msecs = max(1, msecs - WINSOCK_TIMEOUT_SKEW);
			setOption(level, option, msecs);
		} else version (Posix) {
			timeval tv;
			value.split!("seconds", "usecs")(tv.tv_sec, tv.tv_usec);
			setOption(level, option, (&tv)[0 .. 1]);
		} else
			static assert(0);
	}

	/**
	 * Get a text description of this socket's error status, and clear the
	 * socket's error status.
	 */
	string getErrorText() @trusted {
		int error = void;
		getOption(SocketOptionLevel.SOCKET, SocketOption.ERROR, error);
		return formatSocketError(error);
	}

	/**
	 * Enables TCP keep-alive with the specified parameters.
	 *
	 * Params:
	 *   time     = Number of seconds with no activity until the first
	 *              keep-alive packet is sent.
	 *   interval = Number of seconds between when successive keep-alive
	 *              packets are sent if no acknowledgement is received.
	 *
	 * Throws: `SocketOSException` if setting the options fails, or
	 * `SocketFeatureException` if setting keep-alive parameters is
	 * unsupported on the current platform.
	 */
	void setKeepAlive(int time, int interval) @trusted {
		version (Windows) {
			tcp_keepalive options;
			options.onoff = 1;
			options.keepalivetime = time * 1000;
			options.keepaliveinterval = interval * 1000;
			uint cbBytesReturned = void;
			checkError(WSAIoctl(sock, SIO_KEEPALIVE_VALS,
					&options, options.sizeof, null, 0,
					&cbBytesReturned, null, null), "Error setting keep-alive");
		} else static if (is(typeof(TCP_KEEPIDLE)) && is(typeof(TCP_KEEPINTVL))) {
			setOption(SocketOptionLevel.TCP, TCP_KEEPIDLE, time);
			setOption(SocketOptionLevel.TCP, TCP_KEEPINTVL, interval);
			setOption(SocketOptionLevel.SOCKET, SocketOption.KEEPALIVE, true);
		} else
			throw new SocketFeatureException(
				"Setting keep-alive options is not supported on this platform");
	}

	/**
	* Returns: A new `Address` object for the current address family.
	*/
	private Address createAddress() nothrow @nogc @trusted {
		free(ptr);
		switch (addressFamily) {
			static if (is(UnixAddress)) {
		case AddressFamily.UNIX:
				ptr = calloc(1, UnixAddress.sizeof);
				return *cast(UnixAddress*)ptr;
			}
		case AddressFamily.INET:
			ptr = calloc(1, InetAddress.sizeof);
			return *cast(InetAddress*)ptr;
		case AddressFamily.INET6:
			ptr = calloc(1, Inet6Address.sizeof);
			return *cast(Inet6Address*)ptr;
		default:
		}
		ptr = calloc(1, UnknownAddress.sizeof);
		return *cast(UnknownAddress*)ptr;
	}
}

/// Constructs a blocking TCP Socket.
auto tcpSocket(AddressFamily af = AddressFamily.INET)
	=> Socket(af, SocketType.STREAM, ProtocolType.TCP);

/// Constructs a blocking TCP Socket and connects to the given `Address`.
auto tcpSocket(in Address connectTo) {
	auto s = tcpSocket(connectTo.addressFamily);
	s.connect(connectTo);
	return s;
}

/// Constructs a blocking UDP Socket.
auto udpSocket(AddressFamily af = AddressFamily.INET)
	=> Socket(af, SocketType.DGRAM, ProtocolType.UDP);

@safe unittest {
	byte[] buf;
	buf.length = 1;
	auto s = udpSocket();
	assert(s.blocking);
	s.blocking = false;
	s.bind(InetAddress(InetAddress.PORT_ANY));
	Address addr;
	s.receiveFrom(buf, addr);
}

/**
 * Creates a pair of connected sockets.
 *
 * The two sockets are indistinguishable.
 *
 * Throws: `SocketException` if creation of the sockets fails.
 */
Socket[2] socketPair() {
	version (Posix) {
		int[2] socks;
		if (socketpair(AF_UNIX, SOCK_STREAM, 0, socks) == SOCKET_ERROR)
			throw new SocketOSException("Unable to create socket pair");

		return [
			Socket(socks[0], AddressFamily.UNIX),
			Socket(socks[1], AddressFamily.UNIX)
		];
	} else version (Windows) {
		// We do not have socketpair() on Windows, just manually create a
		// pair of sockets connected over some localhost port.

		auto listener = tcpSocket();
		listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
		listener.bind(InetAddress(INADDR_LOOPBACK, InetAddress.PORT_ANY));
		const addr = listener.localAddress;
		listener.listen(1);

		Socket[2] result = [
			tcpSocket(addr),
			listener.accept()
		];

		listener.close();
		return result;
	} else
		static assert(0);
}

///
@safe unittest {
	immutable ubyte[4] data = [1, 2, 3, 4];
	auto pair = socketPair();
	scope (exit)
		foreach (s; pair)
			s.close();

	pair[0].send(data[]);

	ubyte[data.length] buf;
	pair[1].receive(buf);
	assert(buf == data);
}

/**
 * Returns:
 * `true` if the last socket operation failed because the socket
 * was in non-blocking mode and the operation would have blocked,
 * or if the socket is in blocking mode and set a `SNDTIMEO` or `RCVTIMEO`,
 * and the operation timed out.
 */
bool wouldHaveBlocked() nothrow @nogc {
	version (Windows)
		return errno() == WSAEWOULDBLOCK || errno() == WSAETIMEDOUT;
	else version (Posix)
		return errno() == EAGAIN;
}

@safe unittest {
	auto sockets = socketPair();
	auto s = sockets[0];
	s.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"msecs"(10));
	ubyte[16] buffer;
	auto rec = s.receive(buffer);
	assert(rec == -1 && wouldHaveBlocked());
}
