module dast.async.net.error;

public import std.exception;
import std.conv : to;

/// Base exception thrown by `std.socket`.
class SocketException : Exception {
	mixin basicExceptionCtors;
}

version (CRuntime_Glibc) version = GNU_STRERROR;
version (CRuntime_UClibc) version = GNU_STRERROR;

version (Windows) {
	import core.sys.windows.winsock2;
	import std.windows.syserror;

	package alias errno = WSAGetLastError;
} else version (Posix)
	package import core.stdc.errno : errno;

@safe:

/*
 * Needs to be public so that SocketOSException can be thrown outside of
 * std.socket (since it uses it as a default argument), but it probably doesn't
 * need to actually show up in the docs, since there's not really any public
 * need for it outside of being a default argument.
 */
string formatSocketError(int err) @trusted nothrow {
	version (Posix) {
		char[80] buf;
		version (GNU_STRERROR) {
			const(char)* cs = strerror_r(err, buf.ptr, buf.length);
		} else {
			if (auto errs = strerror_r(err, buf.ptr, buf.length))
				return "Socket error " ~ to!string(err);
			const(char)* cs = buf.ptr;
		}

		auto len = strlen(cs);

		if (cs[len - 1] == '\n')
			len--;
		if (cs[len - 1] == '\r')
			len--;
		return cs[0 .. len].idup;
	} else //version (Windows)
		//{
		//	return generateSysErrorMsg(err);
		//}
		//else
		return "Socket error " ~ to!string(err);
}

/// Returns the error message of the most recently encountered network error.
@property string lastSocketError() nothrow
	=> formatSocketError(errno());

pragma(inline, true) void checkError(int err, string msg) {
	if (err == SOCKET_ERROR)
		throw new SocketOSException(msg);
}

/// Socket exception representing network errors reported by the operating system.
class SocketOSException : SocketException {
	int errorCode; /// Platform-specific error code.

	alias Formatter = string function(int) nothrow @trusted;

nothrow:
	///
	this(string msg,
		string file = __FILE__,
		size_t line = __LINE__,
		Throwable next = null,
		int err = errno(),
		Formatter errorFormatter = &formatSocketError) {
		errorCode = err;

		if (msg.length)
			super(msg ~ ": " ~ errorFormatter(err), file, line, next);
		else
			super(errorFormatter(err), file, line, next);
	}

	///
	this(string msg,
		Throwable next,
		string file = __FILE__,
		size_t line = __LINE__,
		int err = errno(),
		Formatter errorFormatter = &formatSocketError) {
		this(msg, file, line, next, err, errorFormatter);
	}

	///
	this(string msg,
		int err,
		Formatter errorFormatter = &formatSocketError,
		string file = __FILE__,
		size_t line = __LINE__,
		Throwable next = null) {
		this(msg, file, line, next, err, errorFormatter);
	}
}

package template socketOSExceptionCtors() {
nothrow:
	///
	this(string msg, string file = __FILE__, size_t line = __LINE__,
		Throwable next = null, int err = errno()) {
		super(msg, file, line, next, err);
	}

	///
	this(string msg, Throwable next, string file = __FILE__,
		size_t line = __LINE__, int err = errno()) {
		super(msg, next, file, line, err);
	}

	///
	this(string msg, int err, string file = __FILE__, size_t line = __LINE__,
		Throwable next = null) {
		super(msg, next, file, line, err);
	}
}

/// Socket exception representing invalid parameters specified by user code.
class SocketParameterException : SocketException {
	mixin basicExceptionCtors;
}

/**
 * Socket exception representing attempts to use network capabilities not
 * available on the current system.
 */
class SocketFeatureException : SocketException {
	mixin basicExceptionCtors;
}

version (unittest) package {
	// Print a message on exception instead of failing the unittest.
	void softUnittest(void function() @safe test, int line = __LINE__) @trusted {
		debug (std_socket)
			test();
		else {
			import std.stdio : writefln;

			try
				test();
			catch (Throwable e)
				writefln("Ignoring std.socket(%d) test failure (likely caused by flaky environment): %s", line, e);
		}
	}

	// Without debug=std_socket, still compile the slow tests, just don't run them.
	debug (std_socket)
		enum runSlowTests = true;
	else
		enum runSlowTests = false;
}
