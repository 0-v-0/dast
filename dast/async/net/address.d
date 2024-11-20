module dast.async.net.address;

import std.string : indexOf, fromStringz;
import std.conv : to;
import std.internal.cstring;
import dast.async.net.error;

version (Windows) {
	import core.sys.windows.winbase;
	import core.sys.windows.winsock2;
} else version (Posix) {
	import core.sys.posix.netinet.in_;
	import core.sys.posix.arpa.inet;
	import core.sys.posix.netdb;
	import core.sys.posix.sys.un : sockaddr_un;
}

@safe:

// dfmt off
/**
 * The communication domain used to resolve an address.
 */
enum AddressFamily: ushort {
	UNSPEC =     AF_UNSPEC,     /// Unspecified address family
	UNIX =       AF_UNIX,       /// Local communication (Unix socket)
	INET =       AF_INET,       /// Internet Protocol version 4
	IPX =        AF_IPX,        /// Novell IPX
	APPLETALK =  AF_APPLETALK,  /// AppleTalk
	INET6 =      AF_INET6,      /// Internet Protocol version 6
}

/**
 * Communication semantics
 */
enum SocketType: int
{
	STREAM =     SOCK_STREAM,           /// Sequenced, reliable, two-way communication-based byte streams
	DGRAM =      SOCK_DGRAM,            /// Connectionless, unreliable datagrams with a fixed maximum length; data may be lost or arrive out of order
	RAW =        SOCK_RAW,              /// Raw protocol access
	RDM =        SOCK_RDM,              /// Reliably-delivered message datagrams
	SEQPACKET =  SOCK_SEQPACKET,        /// Sequenced, reliable, two-way connection-based datagrams with a fixed maximum length
}

/**
 * Protocol
 */
enum ProtocolType: int
{
	IP =    IPPROTO_IP,         /// Internet Protocol version 4
	ICMP =  IPPROTO_ICMP,       /// Internet Control Message Protocol
	IGMP =  IPPROTO_IGMP,       /// Internet Group Management Protocol
	GGP =   IPPROTO_GGP,        /// Gateway to Gateway Protocol
	TCP =   IPPROTO_TCP,        /// Transmission Control Protocol
	PUP =   IPPROTO_PUP,        /// PARC Universal Packet Protocol
	UDP =   IPPROTO_UDP,        /// User Datagram Protocol
	IDP =   IPPROTO_IDP,        /// Xerox NS protocol
	RAW =   IPPROTO_RAW,        /// Raw IP packets
	IPV6 =  IPPROTO_IPV6,       /// Internet Protocol version 6
}

// dfmt on

/// Holds information about a socket _address retrieved by `getAddressInfo`.
struct AddressInfo {
	AddressFamily family; /// Address _family
	SocketType type; /// Socket _type
	ProtocolType protocol; /// Protocol
	Address address; /// Socket _address
	string canonicalName; /// Canonical name, when `AddressInfoFlags.CANONNAME` is used.
}

/**
 * A subset of flags supported on all platforms with getaddrinfo.
 * Specifies option flags for `getAddressInfo`.
 */
enum AddressInfoFlags : int {
	/// The resulting addresses will be used in a call to `Socket.bind`.
	PASSIVE = AI_PASSIVE,

	/// The canonical name is returned in `canonicalName` member in the first `AddressInfo`.
	CANONNAME = AI_CANONNAME,

	/**
	 * The `node` parameter passed to `getAddressInfo` must be a numeric string.
	 * This will suppress any potentially lengthy network host address lookups.
	 */
	NUMERICHOST = AI_NUMERICHOST,
}

/**
 * On POSIX, getaddrinfo uses its own error codes, and thus has its own
 * formatting function.
 */
private string formatGaiError(int err) @trusted nothrow {
	version (Windows) {
		// TODO: generateSysErrorMsg
		return "Socket error " ~ to!string(err);
	} else {
		synchronized
		return cast(string)fromStringz(gai_strerror(err));
	}
}

/**
 * Provides _protocol-independent translation from host names to socket
 * addresses. If advanced functionality is not required, consider using
 * `getAddress` for compatibility with older systems.
 *
 * Returns: Array with one `AddressInfo` per socket address.
 *
 * Throws: `SocketOSException` on failure
 *
 * Params:
 *  node     = string containing host name or numeric address
 *  options  = optional additional parameters, identified by type:
 *             `string` - service name or port number
 *             `AddressInfoFlags` - option flags
 *             `AddressFamily` - address family to filter by
 *             `SocketType` - socket type to filter by
 *             `ProtocolType` - protocol to filter by
 *
 * Example:
 * ---
 * // Roundtrip DNS resolution
 * auto results = getAddressInfo("www.digitalmars.com");
 * assert(results.front.address.toHostNameString() ==
 *     "digitalmars.com");
 *
 * // Canonical name
 * results = getAddressInfo("www.digitalmars.com",
 *     AddressInfoFlags.CANONNAME);
 * assert(results.front.canonicalName == "digitalmars.com");
 *
 * // IPv6 resolution
 * results = getAddressInfo("ipv6.google.com");
 * assert(results.front.family == AddressFamily.INET6);
 *
 * // Multihomed resolution
 * results = getAddressInfo("google.com");
 * assert(!results.empty);
 *
 * // Parsing IPv4
 * results = getAddressInfo("127.0.0.1",
 *     AddressInfoFlags.NUMERICHOST);
 * assert(!results.empty && results.front.family ==
 *     AddressFamily.INET);
 *
 * // Parsing IPv6
 * results = getAddressInfo("::1",
 *     AddressInfoFlags.NUMERICHOST);
 * assert(!results.empty && results[0].family ==
 *     AddressFamily.INET6);
 * ---
 */
auto getAddressInfo(T...)(scope const(char)[] node, scope T options) {
	const(char)[] service = null;
	addrinfo hints;
	hints.ai_family = AF_UNSPEC;

	foreach (i, option; options) {
		static if (is(typeof(option) : const(char)[]))
			service = options[i];
		else static if (is(typeof(option) == AddressInfoFlags))
			hints.ai_flags |= option;
		else static if (is(typeof(option) == AddressFamily))
			hints.ai_family = option;
		else static if (is(typeof(option) == SocketType))
			hints.ai_socktype = option;
		else static if (is(typeof(option) == ProtocolType))
			hints.ai_protocol = option;
		else
			static assert(0, "Unknown getAddressInfo option type: " ~ typeof(option).stringof);
	}

	return (() @trusted => getAddressInfoImpl(node, service, &hints))();
}

@system unittest {
	struct Oops {
		const(char[]) breakSafety() {
			*cast(int*)0xcafebabe = 0xdeadbeef;
			return null;
		}

		alias breakSafety this;
	}

	assert(!__traits(compiles, () { getAddressInfo("", Oops.init); }), "getAddressInfo breaks @safe");
}

struct AddressInfoList {
	private addrinfo* head;
	private const(addrinfo)* ai;

nothrow @safe @nogc:
	this(addrinfo* info) pure {
		head = info;
		ai = info;
	}

	@disable this(this);

	~this() @trusted {
		freeaddrinfo(head);
	}

pure:
	@property bool empty() const => !ai;

	@property AddressInfo front() const @trusted =>
		AddressInfo(
			cast(AddressFamily)ai.ai_family,
			cast(SocketType)ai.ai_socktype,
			cast(ProtocolType)ai.ai_protocol,
			Address(cast(sockaddr*)ai.ai_addr, cast(socklen_t)ai.ai_addrlen),
			cast(string)fromStringz(ai.ai_canonname));

	void popFront() {
		ai = ai.ai_next;
	}
}

private auto getAddressInfoImpl(scope const(char)[] node, scope const(char)[] service, addrinfo* hints) @system {
	addrinfo* ai_res = void;

	const ret = getaddrinfo(
		node.tempCString(),
		service.tempCString(),
		hints, &ai_res);
	enforce(ret == 0, new SocketOSException("getaddrinfo error", ret, &formatGaiError));
	return AddressInfoList(ai_res);
}

@safe unittest {
	softUnittest({
		// Roundtrip DNS resolution
		auto results = getAddressInfo("www.digitalmars.com");
		assert(!results.empty);

		// Canonical name
		results = getAddressInfo("www.digitalmars.com", AddressInfoFlags.CANONNAME);
		assert(!results.empty && results.front.canonicalName == "digitalmars.com");

		// IPv6 resolution
		//results = getAddressInfo("ipv6.google.com");
		//assert(results.front.family == AddressFamily.INET6);

		// Multihomed resolution
		//results = getAddressInfo("google.com");
		//assert(results.length > 1);

		// Parsing IPv4
		results = getAddressInfo("127.0.0.1", AddressInfoFlags.NUMERICHOST);
		assert(!results.empty && results.front.family == AddressFamily.INET);

		// Parsing IPv6
		results = getAddressInfo("::1", AddressInfoFlags.NUMERICHOST);
		assert(!results.empty && results.front.family == AddressFamily.INET6);
	});

	auto results = getAddressInfo(null, "1234", AddressInfoFlags.PASSIVE,
		SocketType.STREAM, ProtocolType.TCP, AddressFamily.INET);
	assert(!results.empty && results.front.address.toString() == "0.0.0.0:1234");
}

struct AddressList {
	AddressInfoList infos;

pure nothrow @nogc:
	@property bool empty() const => infos.empty;
	@property Address front() const => infos.front.address;
	void popFront() {
		infos.popFront();
	}
}

/**
 * Provides _protocol-independent translation from host names to socket
 * addresses. Uses `getAddressInfo` if the current system supports it,
 * and `InternetHost` otherwise.
 *
 * Returns: Array with one `Address` instance per socket address.
 *
 * Throws: `SocketOSException` on failure.
 *
 * Example:
 * ---
 * writeln("Resolving www.digitalmars.com:");
 * try
 * {
 *     auto addresses = getAddress("www.digitalmars.com");
 *     foreach (address; addresses)
 *         writefln("  IP: %s", address.toAddrString());
 * }
 * catch (SocketException e)
 *     writefln("  Lookup failed: %s", e.msg);
 * ---
 */
auto getAddress(scope const(char)[] hostname, scope const(char)[] service = null) {
	return AddressList(getAddressInfo(hostname, service));
}

@safe unittest {
	softUnittest({
		auto addresses = getAddress("63.105.9.61");
		assert(!addresses.empty && addresses.front.toAddrString() == "63.105.9.61");
	});
}

/**
 * Provides _protocol-independent parsing of network addresses. Does not
 * attempt name resolution. Uses `getAddressInfo` with
 * `AddressInfoFlags.NUMERICHOST` if the current system supports it, and
 * `InetAddress` otherwise.
 *
 * Returns: An `Address` instance representing specified address.
 *
 * Throws: `SocketException` on failure.
 *
 * Example:
 * ---
 * writeln("Enter IP address:");
 * string ip = readln().chomp();
 * try
 * {
 *     Address address = parseAddress(ip);
 *     writefln("Looking up reverse of %s:",
 *         address.toAddrString());
 *     try
 *     {
 *         string reverse = address.toHostNameString();
 *         if (reverse)
 *             writefln("  Reverse name: %s", reverse);
 *         else
 *             writeln("  Reverse hostname not found.");
 *     }
 *     catch (SocketException e)
 *         writefln("  Lookup error: %s", e.msg);
 * }
 * catch (SocketException e)
 * {
 *     writefln("  %s is not a valid IP address: %s",
 *         ip, e.msg);
 * }
 * ---
 */
auto parseAddress(scope const(char)[] hostaddr, scope const(char)[] service = null) {
	return getAddressInfo(hostaddr, service, AddressInfoFlags.NUMERICHOST).front.address;
}

@safe unittest {
	softUnittest({
		const address = parseAddress("63.105.9.61");
		assert(address.toAddrString() == "63.105.9.61");

		assert(collectException!SocketException(parseAddress("Invalid IP address")));
	});
}

/**
 * Class for exceptions thrown from an `Address`.
 */
class AddressException : SocketOSException {
	mixin socketOSExceptionCtors;
}

struct Address {
	sockaddr* name;
	socklen_t nameLen;

	/**
	 * Attempts to retrieve the host address as a human-readable string.
	 *
	 * Throws: `AddressException` on failure
	 */
	string toAddrString() const => toHostString(true);

	/**
	 * Attempts to retrieve the host name as a fully qualified domain name.
	 *
	 * Returns: The FQDN corresponding to this `Address`, or `null` if
	 * the host name did not resolve.
	 *
	 * Throws: `AddressException` on error
	 */
	string toHostNameString() const => toHostString(false);

	/**
	 * Attempts to retrieve the numeric port number as a string.
	 *
	 * Throws: `AddressException` on failure
	 */
	string toPortString() const => toServiceString(true);

	// Common code for toAddrString and toHostNameString
	private string toHostString(bool numeric) @trusted const {
		char[NI_MAXHOST] buf = void;
		const ret = getnameinfo(
			name, nameLen,
			buf.ptr, cast(uint)buf.length,
			null, 0,
			numeric ? NI_NUMERICHOST : NI_NAMEREQD);

		if (!numeric) {
			if (ret == EAI_NONAME)
				return null;
			version (Windows)
				if (ret == WSANO_DATA)
					return null;
		}

		enforce(ret == 0, new AddressException("Could not get " ~
				(numeric ? "host address" : "host name")));
		return fromStringz(buf.ptr).idup;
	}

	// Common code for toPortString and toServiceNameString
	private string toServiceString(bool numeric) @trusted const {
		char[NI_MAXSERV] buf = void;
		enforce(getnameinfo(
				name, nameLen,
				null, 0,
				buf.ptr, cast(uint)buf.length,
				numeric ? NI_NUMERICSERV : NI_NAMEREQD
		) == 0, new AddressException("Could not get " ~
				(numeric ? "port number" : "service name")));
		return fromStringz(buf.ptr).idup;
	}

	string toString() const nothrow {
		try {
			string host = toAddrString();
			string port = toPortString();
			if (host.indexOf(':') >= 0)
				return "[" ~ host ~ "]:" ~ port;
			return host ~ ":" ~ port;
		} catch (Exception)
			return "Unknown";
	}

pure nothrow @nogc:
	this(sockaddr* sa, socklen_t len)
	in (sa) {
		name = sa;
		nameLen = len;
	}

	/// Family of this address.
	@property AddressFamily addressFamily() const
		=> name ? cast(AddressFamily)name.sa_family : AddressFamily.UNSPEC;

	@property private void addressFamily(AddressFamily af) {
		name.sa_family = af;
	}
}

struct InetAddress {
	alias address this;

	private sockaddr_in sin;

	enum ANY = INADDR_ANY; /// Any IPv4 host address.
	enum LOOPBACK = INADDR_LOOPBACK; /// The IPv4 loopback address.
	enum NONE = INADDR_NONE; /// An invalid IPv4 host address.
	enum ushort PORT_ANY = 0; /// Any IPv4 port number.

	/**
	 * Construct a new `InetAddress`.
	 * Params:
	 *   addr = an IPv4 address string in the dotted-decimal form a.b.c.d.
	 *   port = port number, may be `PORT_ANY`.
	 */
	this(scope const(char)[] addr, ushort port) {
		sin.sin_family = AddressFamily.INET;
		sin.sin_addr.s_addr = htonl(parse(addr));
		sin.sin_port = htons(port);
	}

nothrow @nogc:

	/// Returns the IPv4 _port number (in host byte order).
	@property pure {
		ushort port() const => ntohs(sin.sin_port);

		/// Returns the IPv4 address number (in host byte order).
		uint addr() const => ntohl(sin.sin_addr.s_addr);

		Address address() const @trusted =>
			Address(cast(sockaddr*)&sin, cast(socklen_t)sin.sizeof);
	}

	/**
	 * Construct a new `InetAddress`.
	 * Params:
	 *   addr = (optional) an IPv4 address in host byte order, may be `ADDR_ANY`.
	 *   port = port number, may be `PORT_ANY`.
	 */
	this(uint addr, ushort port) pure {
		sin.sin_family = AddressFamily.INET;
		sin.sin_addr.s_addr = htonl(addr);
		sin.sin_port = htons(port);
	}

	/// ditto
	this(ushort port) pure {
		sin.sin_family = AddressFamily.INET;
		sin.sin_addr.s_addr = ANY;
		sin.sin_port = htons(port);
	}

	/**
	 * Construct a new `InetAddress`.
	 * Params:
	 *   addr = A sockaddr_in as obtained from lower-level API calls such as getifaddrs.
	 */
	this(sockaddr_in addr) pure
	in (addr.sin_family == AddressFamily.INET, "Socket address is not of INET family.") {
		sin = addr;
	}

	/**
	 * Parse an IPv4 address string in the dotted-decimal form $(I a.b.c.d)
	 * and return the number.
	 * Returns: If the string is not a legitimate IPv4 address,
	 * `ADDR_NONE` is returned.
	 */
	static uint parse(scope const(char)[] addr) @trusted
		=> ntohl(inet_addr(addr.tempCString()));

	/**
	 * Convert an IPv4 address number in host byte order to a human readable
	 * string representing the IPv4 address in dotted-decimal form.
	 */
	static string addrToString(uint addr) @trusted {
		in_addr sin_addr;
		sin_addr.s_addr = htonl(addr);
		return cast(string)fromStringz(inet_ntoa(sin_addr));
	}
}

@safe unittest {
	softUnittest({
		const ia = InetAddress("63.105.9.61", 80);
		assert(ia.toString() == "63.105.9.61:80");
	});

	softUnittest({
		// test construction from a sockaddr_in
		sockaddr_in sin;

		sin.sin_addr.s_addr = htonl(0x7F_00_00_01); // 127.0.0.1
		sin.sin_family = AddressFamily.INET;
		sin.sin_port = htons(80);

		const ia = InetAddress(sin);
		assert(ia.toString() == "127.0.0.1:80");
	});

	if (runSlowTests)
		softUnittest({
			// test failing reverse lookup
			const ia = InetAddress("255.255.255.255", 80);
			assert(ia.toHostNameString() is null);
		});
}

struct Inet6Address {
	alias address this;

	private sockaddr_in6 sin6;

	enum ushort PORT_ANY = 0; /// Any IPv6 port number.

	/**
	 * Construct a new `Inet6Address`.
	 * Params:
	 *   addr = an IPv6 address string in the colon-separated form a:b:c:d:e:f:g:h.
	 *   port = port number, may be `PORT_ANY`.
	 */
	this(scope const(char)[] addr, ushort port = PORT_ANY) {
		sin6.sin6_family = AddressFamily.INET6;
		sin6.sin6_port = htons(port);
		sin6.sin6_addr = in6_addr(s6_addr8 : parse(addr));
	}

	/**
	 * Parse an IPv6 host address string as described in RFC 2373, and return the
	 * address.
	 * Throws: `SocketException` on error.
	 */
	static ubyte[16] parse(scope const(char)[] addr) @trusted {
		// Although we could use inet_pton here, it's only available on Windows
		// versions starting with Vista, so use getAddressInfo with NUMERICHOST
		// instead.
		auto results = getAddressInfo(addr, AddressInfoFlags.NUMERICHOST);
		if (!results.empty && results.front.family == AddressFamily.INET6)
			return (cast(sockaddr_in6*)results.front.address.name).sin6_addr.s6_addr;
		return ANY;
	}

pure nothrow @nogc:

	/**
	 * Construct a new `Inet6Address`.
	 * Params:
	 *   addr = A sockaddr_in6 as obtained from lower-level API calls such as getifaddrs.
	 */
	this(sockaddr_in6 addr)
	in (addr.sin6_family == AddressFamily.INET6, "Socket address is not of INET6 family.") {
		sin6 = addr;
	}

	/**
	 * Construct a new `Inet6Address`.
	 * Params:
	 *   addr = (optional) an IPv6 host address in host byte order, or
	 *          `ADDR_ANY`.
	 *   port = port number, may be `PORT_ANY`.
	 */
	this(in ubyte[16] addr, ushort port) {
		sin6.sin6_family = AddressFamily.INET6;
		sin6.sin6_addr.s6_addr = addr;
		sin6.sin6_port = htons(port);
	}

	/// ditto
	this(ushort port) {
		sin6.sin6_family = AddressFamily.INET6;
		sin6.sin6_addr.s6_addr = ADDR_ANY;
		sin6.sin6_port = htons(port);
	}

@property:

	/// Any IPv6 host address.
	static ref const(ubyte)[16] ANY() {
		static if (is(typeof(IN6ADDR_ANY))) {
			version (Windows) {
				static immutable addr = IN6ADDR_ANY.s6_addr;
				return addr;
			} else
				return IN6ADDR_ANY.s6_addr;
		} else static if (is(typeof(in6addr_any)))
			return in6addr_any.s6_addr;
		else
			static assert(0);
	}

	/// The IPv6 loopback address.
	static ref const(ubyte)[16] LOOPBACK() {
		static if (is(typeof(IN6ADDR_LOOPBACK))) {
			version (Windows) {
				static immutable addr = IN6ADDR_LOOPBACK.s6_addr;
				return addr;
			} else
				return IN6ADDR_LOOPBACK.s6_addr;
		} else static if (is(typeof(in6addr_loopback)))
			return in6addr_loopback.s6_addr;
		else
			static assert(0);
	}

	/// Returns the IPv6 port number.
	ushort port() const => ntohs(sin6.sin6_port);

	/// Returns the IPv6 address.
	ubyte[16] addr() const => sin6.sin6_addr.s6_addr;

	Address address() const @trusted
		=> Address(cast(sockaddr*)&sin6, cast(socklen_t)sin6.sizeof);
}

@safe unittest {
	softUnittest({
		const ia = Inet6Address("::1", 80);
		assert(ia.toString() == "[::1]:80");
	});

	softUnittest({
		// test construction from a sockaddr_in6
		sockaddr_in6 sin;

		sin.sin6_addr.s6_addr = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]; // [::1]
		sin.sin6_family = AddressFamily.INET6;
		sin.sin6_port = htons(80);

		const ia = Inet6Address(sin);
		assert(ia.toString() == "[::1]:80");
	});
}

static if (is(sockaddr_un)) {
	struct UnixAddress {
		alias address this;

		private sockaddr_un sun;
		socklen_t nameLen;

		/**
		 * Construct a new `UnixAddress`.
		 * Params:
		 *   path = a string containing the path to the Unix domain socket.
		 */
		this(scope const(char)[] path) @trusted pure {
			enforce(path.length <= sun.sun_path.sizeof, new SocketParameterException(
					"Path too long"));
			sun.sun_family = AddressFamily.UNIX;
			strncpy(sun.sun_path.ptr, path, sun.sun_path.length);
			auto len = sockaddr_un.init.sun_path.offsetof + path.length;
			// Pathname socket address must be terminated with '\0'
			// which must be included in the address length.
			if (sun.sun_path[0]) {
				sun.sun_path[path.length] = 0;
				++len;
			}
			nameLen = len;
		}

	pure nothrow @nogc:

		/**
		 * Construct a new `UnixAddress`.
		 * Params:
		 *   addr = a sockaddr_un as obtained from lower-level API calls such as getifaddrs.
		 */
		this(sockaddr_un addr)
		in (addr.sun_family == AddressFamily.UNIX, "Socket address is not of UNIX family.") {
			sun = addr;
		}

	@property:

		/// Returns the path to the Unix domain socket.
		string path() const @trusted
			=> cast(string)fromStringz(cast(const char*)sun.sun_path.ptr);

		Address address() const @trusted
			=> Address(cast(sockaddr*)&sun, nameLen);
	}
}

struct UnknownAddress {
	alias address this;

	private sockaddr sa;

pure nothrow @nogc:
	/**
	 * Construct a new `UnknownAddress`.
	 * Params:
	 *   addr = a sockaddr as obtained from lower-level API calls such as getifaddrs.
	 */
	this(sockaddr addr) {
		sa = addr;
	}

@property:
	/// Returns the address.
	Address address() const @trusted
		=> Address(cast(sockaddr*)&sa, cast(socklen_t)sa.sizeof);
}
