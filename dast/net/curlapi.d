module dast.net.curlapi;

import etc.c.curl : CurlGlobal;

/++
	Exception thrown on errors in std.net.curl functions.
+/
class CurlException : Exception {
	/++
		Params:
			msg  = The message for the exception.
			file = The file where the exception occurred.
			line = The line number where the exception occurred.
			next = The previous exception in the chain of exceptions, if any.
	  +/
	@safe pure nothrow
	this(string msg,
		string file = __FILE__,
		size_t line = __LINE__,
		Throwable next = null) {
		super(msg, file, line, next);
	}
}

/++
	Exception thrown on timeout errors in std.net.curl functions.
+/
class CurlTimeoutException : CurlException {
	/++
		Params:
			msg  = The message for the exception.
			file = The file where the exception occurred.
			line = The line number where the exception occurred.
			next = The previous exception in the chain of exceptions, if any.
	  +/
	@safe pure nothrow
	this(string msg,
		string file = __FILE__,
		size_t line = __LINE__,
		Throwable next = null) {
		super(msg, file, line, next);
	}
}

enum CurlInf : CurlInfo {
	contentlengthdownload = cast(CurlInfo)6_291_471,
	contentlengthupload = cast(CurlInfo)6_291_472,
}

struct CurlAPI {
	import etc.c.curl : curl_version_info, curl_version_info_data,
		CURL, CURLcode, CURLINFO, CURLoption, CURLversion, curl_slist;

extern (C) nothrow @nogc:
	import core.stdc.config : c_long;

	CURLcode function(c_long flags) global_init;
	void function() global_cleanup;
	curl_version_info_data* function(CURLversion) version_info;
	CURL* function() easy_init;
	CURLcode function(CURL* curl, CURLoption option, ...) easy_setopt;
	CURLcode function(CURL* curl) easy_perform;
	CURLcode function(CURL* curl, CURLINFO info, ...) easy_getinfo;
	CURL* function(CURL* curl) easy_duphandle;
	char* function(CURLcode) easy_strerror;
	CURLcode function(CURL* handle, int bitmask) easy_pause;
	void function(CURL* curl) easy_cleanup;
	curl_slist* function(curl_slist*, char*) slist_append;
	void function(curl_slist*) slist_free_all;
	void function(void*) free;
	char* function(CURL* curl, scope const(char) *s, int length) easy_escape;
	char* function(CURL* curl, scope const(char) *s, int length, int *outlength) easy_unescape;

	CURL* function() multi_init;
	CURLMcode function(void* multi_handle, void* extra_fds, uint extra_nfds, int timeout_ms, int* ret) multi_wait;
	CURLMcode function(void* multi_handle, CURLMoption option, ...) multi_setopt;
	CURLMcode function(void* multi_handle, CURLMcode* running_handles) multi_perform;
	CURLMsg* function(void* multi_handle, int* msg_left) multi_info_read;
	CURLMcode function(void* multi_handle, CURL* easy_handle) multi_add_handle;
	CURLMcode function(void* multi_handle, CURL* easy_handle) multi_remove_handle;
	void function(void* multi_handle) multi_cleanup;
}

private __gshared {
	CurlAPI _api;
	void* _handle;
}

@property ref curlAPI() {
	import std.concurrency : initOnce;

	initOnce!_handle(loadAPI());
	return _api;
}

// TODO: use AliasSeq
version (LibcurlPath) {
	import std.string : strip;

	static immutable names = [strip(import("LibcurlPathFile"))];
} else version (OSX)
	static immutable names = ["libcurl.4.dylib"];
else version (Posix) {
	static immutable names = [
		"libcurl.so", "libcurl.so.4",
		"libcurl-gnutls.so.4", "libcurl-nss.so.4", "libcurl.so.3"
	];
} else version (Windows)
	static immutable names = ["libcurl.dll", "curl.dll"];

void* loadAPI() {
	import std.exception : enforce;

	void* handle = void;
	version (Posix) {
		import core.sys.posix.dlfcn : dlsym, dlopen, dlclose, RTLD_LAZY;

		alias loadSym = dlsym;
		handle = dlopen(null, RTLD_LAZY);
	} else version (Windows) {
		import core.sys.windows.winbase : GetProcAddress, GetModuleHandleA,
			LoadLibraryA;

		alias loadSym = GetProcAddress;
		handle = GetModuleHandleA(null);
	} else
		static assert(0, "unimplemented");

	assert(handle);

	// try to load curl from the executable to allow static linking
	if (loadSym(handle, "curl_global_init") is null) {
		import std.format : format;

		version (Posix)
			dlclose(handle);

		foreach (name; names) {
			version (Posix)
				handle = dlopen(name.ptr, RTLD_LAZY);
			else version (Windows)
				handle = LoadLibraryA(name.ptr);
			if (handle !is null)
				break;
		}

		enforce!CurlException(handle !is null, "Failed to load curl, tried %(%s, %).".format(names));
	}

	foreach (i, ref f; _api.tupleof) {
		enum name = __traits(identifier, _api.tupleof[i]);
		auto p = enforce!CurlException(loadSym(handle, "curl_" ~ name),
			"Couldn't load curl_" ~ name ~ " from libcurl.");
		f = cast(typeof(f))p;
	}

	enforce!CurlException(!_api.global_init(CurlGlobal.all),
		"Failed to initialize libcurl");

	import core.stdc.stdlib : atexit;

	atexit(&cleanup);

	return handle;
}

extern (C) void cleanup() {
	if (_handle is null)
		return;
	_api.global_cleanup();
	version (Posix) {
		import core.sys.posix.dlfcn : dlclose;

		dlclose(_handle);
	} else version (Windows) {
		import core.sys.windows.winbase : FreeLibrary;

		FreeLibrary(_handle);
	} else
		static assert(0, "unimplemented");
	_api = CurlAPI.init;
	_handle = null;
}

/**
  Wrapper to provide a better interface to libcurl than using the plain C API.

  Warning: This struct uses interior pointers for callbacks. Only allocate it
  on the stack if you never move or copy it. This also means passing by reference
  when passing Curl to other functions. Otherwise always allocate on
  the heap.
*/
struct Curl {
	import etc.c.curl;
	import std.exception : enforce;

	alias OutData = void[];
	alias InData = ubyte[];

	private {
		alias curl = curlAPI;

		// A handle should not be used by two threads simultaneously
		CURL* ch;
		uint _rc;

		// May also return `CURL_READFUNC_ABORT` or `CURL_READFUNC_PAUSE`
		size_t delegate(OutData) _onSend;
		size_t delegate(InData) _onReceive;
		void delegate(in char[]) _onReceiveHeader;
		CurlSeek delegate(long, CurlSeekPos) _onSeek;
		int delegate(curl_socket_t, CurlSockType) _onSocketOption;
		int delegate(size_t dltotal, size_t dlnow,
			size_t ultotal, size_t ulnow) _onProgress;
	}

	//alias requestPause = CurlReadFunc.pause;
	//alias requestAbort = CurlReadFunc.abort;

	this(CURL* h) {
		if (h)
			ch = h;
		else {
			ch = curl.easy_init();
			enforce!CurlException(ch, "Curl instance couldn't be initialized");
			set(CurlOption.nosignal, 1);
		}
		_rc = 1;
	}

	@disable this();

	this(this) {
		++_rc;
	}

	~this() {
		if (ch)
			close();
	}

	@property handle() => ch;

	///
	@property bool stopped() const => ch is null;

	/**
	   Duplicate this handle.

	   The new handle will have all options set as the one it was duplicated
	   from. An exception to this is that all options that cannot be shared
	   across threads are reset thereby making it safe to use the duplicate
	   in a new thread.
	*/
	Curl dup() {
		import std.meta : AliasSeq;

		Curl copy = Curl(curl.easy_duphandle(ch));

		with (CurlOption) {
			foreach (option; AliasSeq!(file, writefunction, writeheader,
					headerfunction, infile, readfunction, ioctldata, ioctlfunction,
					seekdata, seekfunction, sockoptdata, sockoptfunction,
					opensocketdata, opensocketfunction, progressdata,
					progressfunction, debugdata, debugfunction, interleavedata,
					interleavefunction, chunk_data, chunk_bgn_function,
					chunk_end_function, fnmatch_data, fnmatch_function, cookiejar, postfields))
				copy.clear(option);
		}

		// The options are only supported by libcurl when it has been built
		// against certain versions of OpenSSL - if your libcurl uses an old
		// OpenSSL, or uses an entirely different SSL engine, attempting to
		// clear these normally will raise an exception
		copy.clearIfSupported(CurlOption.ssl_ctx_function);
		copy.clearIfSupported(CurlOption.ssh_keydata);

		// Enable for curl version > 7.21.7
		static if (LIBCURL_VERSION_MAJOR >= 7 &&
			LIBCURL_VERSION_MINOR >= 21 &&
			LIBCURL_VERSION_PATCH >= 7) {
			copy.clear(CurlOption.closesocketdata);
			copy.clear(CurlOption.closesocketfunction);
		}

		copy.set(CurlOption.nosignal, 1);

		// copy.clear(CurlOption.ssl_ctx_data); Let ssl function be shared
		// copy.clear(CurlOption.ssh_keyfunction); Let key function be shared

		/*
		  Allow sharing of conv functions
		  copy.clear(CurlOption.conv_to_network_function);
		  copy.clear(CurlOption.conv_from_network_function);
		  copy.clear(CurlOption.conv_from_utf8_function);
		*/

		return copy;
	}

	/**
		Stop and invalidate this curl instance.
		Warning: Do not call this from inside a callback handler e.g. `onReceive`.
	*/
	void close() {
		throwOnStopped();
		if (--_rc == 0)
			curl.easy_cleanup(ch);
		ch = null;
	}

	/**
	   Pausing and continuing transfers.
	*/
	void pause(bool sendingPaused, bool receivingPaused) {
		throwOnStopped();
		_check(curl.easy_pause(ch,
				(sendingPaused ? CurlPause.send_cont
				: CurlPause.send) |
				(receivingPaused ? CurlPause.recv_cont : CurlPause.recv)));
	}

	/**
	   Set a string curl option.
	   Params:
	   option = A $(REF CurlOption, etc,c,curl) as found in the curl documentation
	   value = The string
	*/
	void set(CurlOption option, const(char)[] value) {
		import std.internal.cstring : tempCString;

		throwOnStopped();
		_check(curl.easy_setopt(ch, option, value.tempCString().buffPtr));
	}

	/**
	   Set a long curl option.
	   Params:
	   option = A $(REF CurlOption, etc,c,curl) as found in the curl documentation
	   value = The long
	*/
	void set(CurlOption option, long value) {
		throwOnStopped();
		_check(curl.easy_setopt(ch, option, value));
	}

	/**
	   Set a void* curl option.
	   Params:
	   option = A $(REF CurlOption, etc,c,curl) as found in the curl documentation
	   value = The pointer
	*/
	void set(CurlOption option, void* value) {
		throwOnStopped();
		_check(curl.easy_setopt(ch, option, value));
	}

	/**
	   Clear a pointer option.
	   Params:
	   option = A $(REF CurlOption, etc,c,curl) as found in the curl documentation
	*/
	void clear(CurlOption option) {
		throwOnStopped();
		_check(curl.easy_setopt(ch, option, null));
	}

	/**
	   Clear a pointer option. Does not raise an exception if the underlying
	   libcurl does not support the option. Use sparingly.
	   Params:
	   option = A $(REF CurlOption, etc,c,curl) as found in the curl documentation
	*/
	void clearIfSupported(CurlOption option) {
		throwOnStopped();
		auto rval = curl.easy_setopt(ch, option, null);
		if (rval != CurlError.unknown_option && rval != CurlError.not_built_in)
			_check(rval);
	}

	/**
	   perform the curl request by doing the HTTP,FTP etc. as it has
	   been setup beforehand.

	   Params:
	   throwOnError = whether to throw an exception or return a CURLcode on error
	*/
	CURLcode perform(bool throwOnError = true) {
		throwOnStopped();
		CURLcode code = curl.easy_perform(ch);
		if (throwOnError)
			_check(code);
		return code;
	}

	CURLcode tryGet(CurlInfo info, ref long val)
		=> curl.easy_getinfo(ch, info, &val);

	long get(CurlInfo info) {
		long val;
		return curl.easy_getinfo(ch, info, &val) ? -1 : val;
	}

	/**
	  * The event handler that receives incoming data.
	  *
	  * Params:
	  * callback = the callback that receives the `ubyte[]` data.
	  * Be sure to copy the incoming data and not store
	  * a slice.
	  *
	  * Returns:
	  * The callback returns the incoming bytes read. If not the entire array is
	  * the request will abort.
	  * The special value HTTP.pauseRequest can be returned in order to pause the
	  * current request.
	  *
	  * Example:
	  * ----
	  * import std.net.curl, std.stdio, std.conv;
	  * Curl curl;
	  * curl.initialize();
	  * curl.set(CurlOption.url, "http://dlang.org");
	  * curl.onReceive = (ubyte[] data) { writeln("Got data", to!(const(char)[])(data)); return data.length;};
	  * curl.perform();
	  * ----
	  */
	@property void onReceive(size_t delegate(InData) callback) {
		_onReceive = (InData id) {
			throwOnStopped("Receive callback called on cleaned up Curl instance");
			return callback(id);
		};
		set(CurlOption.file, &this);
		set(CurlOption.writefunction, &_receiveCallback);
	}

	/**
	  * The event handler that receives incoming headers for protocols
	  * that uses headers.
	  *
	  * Params:
	  * callback = the callback that receives the header string.
	  * Make sure the callback copies the incoming params if
	  * it needs to store it because they are references into
	  * the backend and may very likely change.
	  *
	  * Example:
	  * ----
	  * import std.net.curl, std.stdio;
	  * Curl curl;
	  * curl.initialize();
	  * curl.set(CurlOption.url, "http://dlang.org");
	  * curl.onReceiveHeader = (in char[] header) { writeln(header); };
	  * curl.perform();
	  * ----
	  */
	@property void onReceiveHeader(void delegate(in char[]) callback) {
		_onReceiveHeader = (in char[] od) {
			throwOnStopped("Receive header callback called on " ~
					"cleaned up Curl instance");
			callback(od);
		};
		set(CurlOption.writeheader, &this);
		set(CurlOption.headerfunction,
			&_receiveHeaderCallback);
	}

	/**
	  * The event handler that gets called when data is needed for sending.
	  *
	  * Params:
	  * callback = the callback that has a `void[]` buffer to be filled
	  *
	  * Returns:
	  * The callback returns the number of elements in the buffer that have been
	  * filled and are ready to send.
	  * The special value `Curl.abortRequest` can be returned in
	  * order to abort the current request.
	  * The special value `Curl.pauseRequest` can be returned in order to
	  * pause the current request.
	  *
	  * Example:
	  * ----
	  * import std.net.curl;
	  * Curl curl;
	  * curl.initialize();
	  * curl.set(CurlOption.url, "http://dlang.org");
	  *
	  * string msg = "Hello world";
	  * curl.onSend = (void[] data)
	  * {
	  *     auto m = cast(void[]) msg;
	  *     size_t length = m.length > data.length ? data.length : m.length;
	  *     if (length == 0) return 0;
	  *     data[0 .. length] = m[0 .. length];
	  *     msg = msg[length..$];
	  *     return length;
	  * };
	  * curl.perform();
	  * ----
	  */
	@property void onSend(size_t delegate(OutData) callback) {
		_onSend = (OutData od) {
			throwOnStopped("Send callback called on cleaned up Curl instance");
			return callback(od);
		};
		set(CurlOption.infile, &this);
		set(CurlOption.readfunction, &_sendCallback);
	}

	/**
	  * The event handler that gets called when the curl backend needs to seek
	  * the data to be sent.
	  *
	  * Params:
	  * callback = the callback that receives a seek offset and a seek position
	  *            $(REF CurlSeekPos, etc,c,curl)
	  *
	  * Returns:
	  * The callback returns the success state of the seeking
	  * $(REF CurlSeek, etc,c,curl)
	  *
	  * Example:
	  * ----
	  * import std.net.curl;
	  * Curl curl;
	  * curl.initialize();
	  * curl.set(CurlOption.url, "http://dlang.org");
	  * curl.onSeek = (long p, CurlSeekPos sp)
	  * {
	  *     return CurlSeek.cantseek;
	  * };
	  * curl.perform();
	  * ----
	  */
	@property void onSeek(CurlSeek delegate(long, CurlSeekPos) callback) {
		_onSeek = (long ofs, CurlSeekPos sp) {
			throwOnStopped("Seek callback called on cleaned up Curl instance");
			return callback(ofs, sp);
		};
		set(CurlOption.seekdata, &this);
		set(CurlOption.seekfunction, &_seekCallback);
	}

	/**
	  * The event handler that gets called when the net socket has been created
	  * but a `connect()` call has not yet been done. This makes it possible to set
	  * misc. socket options.
	  *
	  * Params:
	  * callback = the callback that receives the socket and socket type
	  * $(REF CurlSockType, etc,c,curl)
	  *
	  * Returns:
	  * Return 0 from the callback to signal success, return 1 to signal error
	  * and make curl close the socket
	  *
	  * Example:
	  * ----
	  * import std.net.curl;
	  * Curl curl;
	  * curl.initialize();
	  * curl.set(CurlOption.url, "http://dlang.org");
	  * curl.onSocketOption = delegate int(curl_socket_t s, CurlSockType t) { /+ do stuff +/ };
	  * curl.perform();
	  * ----
	  */
	@property void onSocketOption(int delegate(curl_socket_t,
			CurlSockType) callback) {
		_onSocketOption = (curl_socket_t sock, CurlSockType st) {
			throwOnStopped("Socket option callback called on " ~
					"cleaned up Curl instance");
			return callback(sock, st);
		};
		set(CurlOption.sockoptdata, &this);
		set(CurlOption.sockoptfunction, &_socketOptionCallback);
	}

	/**
	  * The event handler that gets called to inform of upload/download progress.
	  *
	  * Params:
	  * callback = the callback that receives the (total bytes to download,
	  * currently downloaded bytes, total bytes to upload, currently uploaded
	  * bytes).
	  *
	  * Returns:
	  * Return 0 from the callback to signal success, return non-zero to abort
	  * transfer
	  *
	  * Example:
	  * ----
	  * import std.net.curl, std.stdio;
	  * Curl curl;
	  * curl.initialize();
	  * curl.set(CurlOption.url, "http://dlang.org");
	  * curl.onProgress = delegate int(size_t dltotal, size_t dlnow, size_t ultotal, size_t ulnow)
	  * {
	  *     writeln("Progress: downloaded bytes ", dlnow, " of ", dltotal);
	  *     writeln("Progress: uploaded bytes ", ulnow, " of ", ultotal);
	  *     return 0;
	  * };
	  * curl.perform();
	  * ----
	  */
	@property void onProgress(int delegate(size_t dlTotal,
			size_t dlNow,
			size_t ulTotal,
			size_t ulNow) callback) {
		_onProgress = (size_t dlt, size_t dln, size_t ult, size_t uln) {
			throwOnStopped("Progress callback called on cleaned " ~
					"up Curl instance");
			return callback(dlt, dln, ult, uln);
		};
		set(CurlOption.noprogress, 0);
		set(CurlOption.progressdata, &this);
		set(CurlOption.progressfunction, &_progressCallback);
	}

private:

	void _check(CURLcode code) {
		enforce!CurlTimeoutException(code != CurlError.operation_timedout,
			errorString(code));

		enforce!CurlException(code == CurlError.ok,
			errorString(code));
	}

	string errorString(CURLcode code) {
		import std.string : fromStringz;
		import std.format : format;

		auto msgZ = curl.easy_strerror(code);
		// doing the following (instead of just using std.conv.to!string) avoids 1 allocation
		return "%s on handle %s".format(fromStringz(msgZ), ch);
	}

	void throwOnStopped(string message = null) {
		auto def = "Curl instance called after being cleaned up";
		enforce!CurlException(!stopped,
			message == null ? def : message);
	}
}

import etc.c.curl;

private extern (C):
// Internal C callbacks to register with libcurl
size_t _receiveCallback(const char* str,
	size_t size, size_t nmemb, void* ptr) {
	auto b = cast(Curl*)ptr;
	if (b._onReceive != null)
		return b._onReceive(cast(Curl.InData)str[0 .. size * nmemb]);
	return size * nmemb;
}

size_t _receiveHeaderCallback(const char* str,
	size_t size, size_t nmemb, void* ptr) {
	import std.string : chomp;

	auto b = cast(Curl*)ptr;
	auto s = str[0 .. size * nmemb].chomp();
	if (b._onReceiveHeader != null)
		b._onReceiveHeader(s);

	return size * nmemb;
}

size_t _sendCallback(char* str, size_t size, size_t nmemb, void* ptr) {
	Curl* b = cast(Curl*)ptr;
	auto a = cast(void[])str[0 .. size * nmemb];
	if (b._onSend == null)
		return 0;
	return b._onSend(a);
}

int _seekCallback(void* ptr, curl_off_t offset, int origin) {
	auto b = cast(Curl*)ptr;
	if (b._onSeek == null)
		return CurlSeek.cantseek;

	// origin: CurlSeekPos.set/current/end
	// return: CurlSeek.ok/fail/cantseek
	return b._onSeek(cast(long)offset, cast(CurlSeekPos)origin);
}

int _socketOptionCallback(void* ptr,
	curl_socket_t curlfd, curlsocktype purpose) {
	auto b = cast(Curl*)ptr;
	if (b._onSocketOption == null)
		return 0;

	// return: 0 ok, 1 fail
	return b._onSocketOption(curlfd, cast(CurlSockType)purpose);
}

int _progressCallback(void* ptr,
	double dltotal, double dlnow,
	double ultotal, double ulnow) {
	auto b = cast(Curl*)ptr;
	if (b._onProgress == null)
		return 0;

	// return: 0 ok, 1 fail
	return b._onProgress(cast(size_t)dltotal, cast(size_t)dlnow,
		cast(size_t)ultotal, cast(size_t)ulnow);
}
